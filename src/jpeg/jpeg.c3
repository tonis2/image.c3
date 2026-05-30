module image::jpeg;
import image;
import image::jpeg::markers;
import image::jpeg::huffman;
import image::jpeg::idct;
import image::jpeg::ycbcr;
import std::io::file;
import std::math;

faultdef
	INVALID_SIGNATURE, UNSUPPORTED_MARKER, UNSUPPORTED_SOF, INVALID_QUANT_TABLE, INVALID_HUFFMAN_TABLE, INVALID_SOS, UNEXPECTED_EOF, INVALID_COMPONENT_COUNT, UNSUPPORTED_SAMPLING, INVALID_BITSTREAM, INVALID_DRI, INVALID_SOF
;

const sz MAX_COMPONENTS = 3;

struct Component
{
	char id;
	char h_samp;
	char v_samp;
	char quant_id;
	int dc_pred;
	uint width; // effective pixel width at component resolution
	uint height; // effective pixel height at component resolution
	uint stride; // padded stride (bytes per row in plane buffer)
	uint plane_h; // padded plane height
	uint cols_blocks; // = stride / 8
	uint rows_blocks; // = plane_h / 8
	char[] plane;
	int[] coeffs; // progressive only: cols_blocks * rows_blocks * 64 ints (natural order)
}

struct QuantTable
{
	bool defined;
	int[64] table; // natural row-major order
}

struct ScanComp
{
	uint comp_idx;
	char huff_dc_id;
	char huff_ac_id;
}

struct ScanInfo
{
	uint num_comps;
	ScanComp[MAX_COMPONENTS] comps;
	uint ss;
	uint se;
	uint ah;
	uint al;
}

struct JpegState
{
	uint width;
	uint height;
	int num_components;
	bool progressive;
	Component[MAX_COMPONENTS] comp;
	QuantTable[4] qt;
	huffman::HuffmanTable[4] huff_dc;
	huffman::HuffmanTable[4] huff_ac;
	int restart_interval;
	int max_h;
	int max_v;
	uint mcu_cols;
	uint mcu_rows;
	int eob_run;
	Allocator allocator;
}

fn Image? load_file(String path, Allocator allocator = mem)
{
	char[] file_data = file::load(allocator, path)!;
	defer alloc::free(allocator, file_data);
	return load_bytes(file_data, allocator);
}

fn Image? tload_file(String path) => load_file(path, tmem);

fn Image? tload_bytes(char[] data) => load_bytes(data, tmem);

fn Image? load_bytes(char[] data, Allocator allocator = mem)
{
	if (data.len < 4 || data[0] != 0xFF || data[1] != markers::SOI)
	{
		return INVALID_SIGNATURE~;
	}

	JpegState state;
	state.allocator = allocator;
	defer state.free_buffers();

	sz offset     = 2;
	bool sof_seen = false;
	bool eoi_seen = false;

	while (offset < data.len && !eoi_seen)
	{
		markers::Segment seg = markers::next_segment(data, offset)!;
		offset = seg.next_offset;

		if (seg.marker == markers::EOI)
		{
			eoi_seen = true;
			break;
		}
		if (seg.marker == markers::SOI) continue;
		if (markers::is_app_or_com(seg.marker)) continue;
		if (markers::is_rst(seg.marker)) continue;

		switch (seg.marker)
		{
			case markers::DQT:
				state.parse_dqt(seg.payload)!;
			case markers::DHT:
				state.parse_dht(seg.payload)!;
			case markers::DRI:
				if (seg.payload.len != 2) return INVALID_DRI~;
				state.restart_interval = (int)markers::read_u16_be(seg.payload);
			case markers::SOF0:
				if (sof_seen) return INVALID_SOF~;
				state.start_frame(seg.payload, false)!;
				sof_seen = true;
			case markers::SOF2:
				if (sof_seen) return INVALID_SOF~;
				state.start_frame(seg.payload, true)!;
				sof_seen = true;
			case markers::SOS:
				if (!sof_seen) return INVALID_SOS~;
				ScanInfo scan = state.parse_sos(seg.payload)!;
				if (state.progressive)
				{
					offset = state.decode_progressive_scan(&scan, data, offset)!;
				}
				else
				{
					offset = state.decode_baseline_scan(&scan, data, offset)!;
				}
			default:
				if (markers::is_sof(seg.marker)) return UNSUPPORTED_SOF~;
				return UNSUPPORTED_MARKER~;
		}
	}

	if (!sof_seen) return INVALID_SOS~;
	if (state.progressive) state.finalize_progressive()!;
	return state.compose_image();
}

// --- Header parsing ---

fn void? JpegState.parse_dqt(&self, char[] payload)
{
	sz i = 0;
	while (i < payload.len)
	{
		if (i + 1 > payload.len) return INVALID_QUANT_TABLE~;
		char pq_tq = payload[i++];
		uint pq    = (uint)(pq_tq >> 4);
		uint tq    = (uint)(pq_tq & 0x0F);
		if (pq != 0 || tq >= 4) return INVALID_QUANT_TABLE~;
		if (i + 64 > payload.len) return INVALID_QUANT_TABLE~;
		for (uint k = 0; k < 64; k++)
		{
			self.qt[tq].table[huffman::ZIGZAG[k]] = (int)payload[i + k];
		}
		self.qt[tq].defined = true;
		i += 64;
	}
}

fn void? JpegState.parse_dht(&self, char[] payload)
{
	sz i = 0;
	while (i < payload.len)
	{
		if (i + 17 > payload.len) return INVALID_HUFFMAN_TABLE~;
		char tc_th = payload[i++];
		uint tc    = (uint)(tc_th >> 4); // 0 = DC, 1 = AC
		uint th    = (uint)(tc_th & 0x0F);
		if (tc > 1 || th > 3) return INVALID_HUFFMAN_TABLE~;

		char[] bits = payload[i:16];
		i += 16;

		uint total = 0;
		for (uint k = 0; k < 16; k++) total += (uint)bits[k];
		if (i + (sz)total > payload.len) return INVALID_HUFFMAN_TABLE~;
		char[] values = payload[i:(sz)total];
		i += (sz)total;

		if (tc == 0)
		{
			self.huff_dc[th].build(bits, values)!;
		}
		else
		{
			self.huff_ac[th].build(bits, values)!;
		}
	}
}

fn void? JpegState.start_frame(&self, char[] payload, bool progressive)
{
	self.parse_sof(payload, progressive)!;
	self.allocate_planes();
	if (progressive) self.allocate_coeffs();
}

fn void? JpegState.parse_sof(&self, char[] payload, bool progressive)
{
	if (payload.len < 6) return INVALID_SOF~;
	if (payload[0] != 8) return UNSUPPORTED_SOF~;
	uint h  = markers::read_u16_be(payload[1:2]);
	uint w  = markers::read_u16_be(payload[3:2]);
	uint nf = (uint)payload[5];
	if (w == 0 || h == 0) return INVALID_SOF~;
	if (nf != 1 && nf != 3) return INVALID_COMPONENT_COUNT~;
	if (payload.len < (sz)(6 + 3 * nf)) return INVALID_SOF~;

	self.width = w;
	self.height = h;
	self.num_components = (int)nf;
	self.progressive = progressive;

	int max_h = 1;
	int max_v = 1;
	for (uint c = 0; c < nf; c++)
	{
		sz off  = 6 + (sz)c * 3;
		char hv = payload[off + 1];
		char hs = (char)(hv >> 4);
		char vs = (char)(hv & 0x0F);
		char tq = payload[off + 2];
		if (hs != 1 && hs != 2) return UNSUPPORTED_SAMPLING~;
		if (vs != 1 && vs != 2) return UNSUPPORTED_SAMPLING~;
		if (tq >= 4) return INVALID_SOF~;
		self.comp[c].id = payload[off];
		self.comp[c].h_samp = hs;
		self.comp[c].v_samp = vs;
		self.comp[c].quant_id = tq;
		max_h = math::max(max_h, (int)hs);
		max_v = math::max(max_v, (int)vs);
	}
	self.max_h = max_h;
	self.max_v = max_v;
	uint mcu_w_px = (uint)(8 * max_h);
	uint mcu_h_px = (uint)(8 * max_v);
	self.mcu_cols = (w + mcu_w_px - 1) / mcu_w_px;
	self.mcu_rows = (h + mcu_h_px - 1) / mcu_h_px;
}

fn ScanInfo? JpegState.parse_sos(&self, char[] payload)
{
	if (payload.len < 1) return INVALID_SOS~;
	uint ns = (uint)payload[0];
	if (ns == 0 || ns > MAX_COMPONENTS) return INVALID_SOS~;
	if (payload.len < (sz)(1 + 2 * ns + 3)) return INVALID_SOS~;

	ScanInfo info;
	info.num_comps = ns;

	for (uint k = 0; k < ns; k++)
	{
		sz off     = 1 + (sz)k * 2;
		char cs    = payload[off];
		char td_ta = payload[off + 1];
		char td    = (char)(td_ta >> 4);
		char ta    = (char)(td_ta & 0x0F);
		if ((uint)td > 3 || (uint)ta > 3) return INVALID_SOS~;
		if (!self.progressive && ((uint)td > 1 || (uint)ta > 1)) return INVALID_SOS~;

		int ci = -1;
		for (uint i = 0; i < (uint)self.num_components; i++)
		{
			if (self.comp[i].id == cs)
			{
				ci = (int)i;
				break;
			}
		}
		if (ci < 0) return INVALID_SOS~;
		info.comps[k].comp_idx = (uint)ci;
		info.comps[k].huff_dc_id = td;
		info.comps[k].huff_ac_id = ta;
		self.comp[ci].dc_pred = 0;
	}

	sz tail    = 1 + (sz)ns * 2;
	uint ss    = (uint)payload[tail];
	uint se    = (uint)payload[tail + 1];
	char ah_al = payload[tail + 2];
	uint ah    = (uint)(ah_al >> 4);
	uint al    = (uint)(ah_al & 0x0F);

	if (self.progressive)
	{
		if (ss > 63 || se > 63 || ss > se) return INVALID_SOS~;
		if (ss == 0 && se != 0) return INVALID_SOS~;
		if (ss > 0 && ns != 1) return INVALID_SOS~; // AC scans must be non-interleaved
		if (al > 13 || ah > 13) return INVALID_SOS~;
	}
	else
	{
		if (ss != 0 || se != 63 || ah_al != 0) return INVALID_SOS~;
	}

	info.ss = ss;
	info.se = se;
	info.ah = ah;
	info.al = al;
	return info;
}

// --- Buffer management ---

fn void JpegState.allocate_planes(&self)
{
	for (uint c = 0; c < (uint)self.num_components; c++)
	{
		Component* cm = &self.comp[c];
		uint stride   = self.mcu_cols * (uint)cm.h_samp * 8;
		uint plane_h  = self.mcu_rows * (uint)cm.v_samp * 8;
		cm.stride = stride;
		cm.plane_h = plane_h;
		cm.cols_blocks = stride / 8;
		cm.rows_blocks = plane_h / 8;
		cm.width = (self.width * (uint)cm.h_samp + (uint)self.max_h - 1) / (uint)self.max_h;
		cm.height = (self.height * (uint)cm.v_samp + (uint)self.max_v - 1) / (uint)self.max_v;
		cm.plane = alloc::new_array(self.allocator, char, (sz)stride * (sz)plane_h);
	}
}

fn void JpegState.allocate_coeffs(&self)
{
	for (uint c = 0; c < (uint)self.num_components; c++)
	{
		Component* cm = &self.comp[c];
		sz total      = (sz)cm.cols_blocks * (sz)cm.rows_blocks * 64;
		cm.coeffs = alloc::new_array(self.allocator, int, total);
	}
}

fn void JpegState.free_buffers(&self)
{
	for (uint c = 0; c < MAX_COMPONENTS; c++)
	{
		if (self.comp[c].plane.len > 0)
		{
			alloc::free(self.allocator, self.comp[c].plane);
			self.comp[c].plane = { };
		}
		if (self.comp[c].coeffs.len > 0)
		{
			alloc::free(self.allocator, self.comp[c].coeffs);
			self.comp[c].coeffs = { };
		}
	}
}

// Dequantize a block (natural row-major order) and inverse-DCT it into the plane.
fn void dequant_idct(QuantTable* qt, int* coeffs, char[] plane, sz offset, sz stride)
{
	int[64] block;
	for (uint i = 0; i < 64; i++) block[i] = coeffs[i] * qt.table[i];
	idct::idct_block(&block[0], plane, offset, stride);
}

// --- Baseline scan (single SOS, full 0..63 with no successive approximation) ---

fn sz? JpegState.decode_baseline_scan(&self, ScanInfo* scan, char[] data, sz start_offset)
{
	huffman::BitReader br;
	br.init(data, start_offset);

	int rst_count = 0;
	int next_rst  = 0;

	for (uint my = 0; my < self.mcu_rows; my++)
	{
		for (uint mx = 0; mx < self.mcu_cols; mx++)
		{
			for (uint k = 0; k < scan.num_comps; k++)
			{
				ScanComp* sc              = &scan.comps[k];
				Component* cm             = &self.comp[sc.comp_idx];
				huffman::HuffmanTable* dc = &self.huff_dc[sc.huff_dc_id];
				huffman::HuffmanTable* ac = &self.huff_ac[sc.huff_ac_id];
				if (!dc.defined || !ac.defined) return INVALID_HUFFMAN_TABLE~;
				QuantTable* qt = &self.qt[cm.quant_id];
				if (!qt.defined) return INVALID_QUANT_TABLE~;

				for (uint vy = 0; vy < (uint)cm.v_samp; vy++)
				{
					for (uint vx = 0; vx < (uint)cm.h_samp; vx++)
					{
						int[64] coeffs;
						huffman::decode_block(&br, dc, ac, &coeffs[0], &cm.dc_pred)!;

						sz row_y = (sz)((my * (uint)cm.v_samp + vy) * 8);
						sz col_x = (sz)((mx * (uint)cm.h_samp + vx) * 8);
						dequant_idct(qt, &coeffs[0], cm.plane, row_y * (sz)cm.stride + col_x, (sz)cm.stride);
					}
				}
			}

			if (self.restart_interval > 0 && ++rst_count == self.restart_interval)
			{
				rst_count = 0;
				self.handle_restart(&br, scan, &next_rst, my, mx)!;
			}
		}
	}

	return finish_scan(&br);
}

// --- Progressive scan dispatch ---

fn sz? JpegState.decode_progressive_scan(&self, ScanInfo* scan, char[] data, sz start_offset)
{
	self.eob_run = 0;
	huffman::BitReader br;
	br.init(data, start_offset);

	if (scan.num_comps > 1)
	{
		self.decode_progressive_interleaved(&br, scan)!;
	}
	else
	{
		self.decode_progressive_single(&br, scan)!;
	}

	return finish_scan(&br);
}

// Multi-component scan: must be DC-only (validated in parse_sos: ss>0 → ns==1).
fn void? JpegState.decode_progressive_interleaved(&self, huffman::BitReader* br, ScanInfo* scan)
{
	bool first    = scan.ah == 0;
	int rst_count = 0;
	int next_rst  = 0;

	for (uint my = 0; my < self.mcu_rows; my++)
	{
		for (uint mx = 0; mx < self.mcu_cols; mx++)
		{
			for (uint k = 0; k < scan.num_comps; k++)
			{
				ScanComp* sc              = &scan.comps[k];
				Component* cm             = &self.comp[sc.comp_idx];
				huffman::HuffmanTable* dc = &self.huff_dc[sc.huff_dc_id];
				if (first && !dc.defined) return INVALID_HUFFMAN_TABLE~;

				for (uint vy = 0; vy < (uint)cm.v_samp; vy++)
				{
					for (uint vx = 0; vx < (uint)cm.h_samp; vx++)
					{
						uint by   = my * (uint)cm.v_samp + vy;
						uint bx   = mx * (uint)cm.h_samp + vx;
						int* coef = &cm.coeffs[((sz)by * cm.cols_blocks + bx) * 64];
						if (first)
						{
							decode_dc_first(br, dc, coef, &cm.dc_pred, scan.al)!;
						}
						else
						{
							decode_dc_refine(br, coef, scan.al)!;
						}
					}
				}
			}

			if (self.restart_interval > 0 && ++rst_count == self.restart_interval)
			{
				rst_count = 0;
				self.handle_restart(br, scan, &next_rst, my, mx)!;
			}
		}
	}
}

// Non-interleaved scan: a single component, walked in block-row order.
fn void? JpegState.decode_progressive_single(&self, huffman::BitReader* br, ScanInfo* scan)
{
	bool dc_only = scan.ss == 0;
	bool first   = scan.ah == 0;

	ScanComp* sc              = &scan.comps[0];
	Component* cm             = &self.comp[sc.comp_idx];
	huffman::HuffmanTable* dc = &self.huff_dc[sc.huff_dc_id];
	huffman::HuffmanTable* ac = &self.huff_ac[sc.huff_ac_id];

	// Block dimensions for non-interleaved scan (T.81 A.2.4):
	//   ceil(X * H_i / (8 * H_max)) x ceil(Y * V_i / (8 * V_max))
	uint nb_x = (self.width * (uint)cm.h_samp + 8u * (uint)self.max_h - 1) / (8u * (uint)self.max_h);
	uint nb_y = (self.height * (uint)cm.v_samp + 8u * (uint)self.max_v - 1) / (8u * (uint)self.max_v);

	int rst_count = 0;
	int next_rst  = 0;

	for (uint by = 0; by < nb_y; by++)
	{
		for (uint bx = 0; bx < nb_x; bx++)
		{
			int* coef = &cm.coeffs[((sz)by * cm.cols_blocks + bx) * 64];

			if (dc_only)
			{
				if (!dc.defined) return INVALID_HUFFMAN_TABLE~;
				if (first)
				{
					decode_dc_first(br, dc, coef, &cm.dc_pred, scan.al)!;
				}
				else
				{
					decode_dc_refine(br, coef, scan.al)!;
				}
			}
			else
			{
				if (!ac.defined) return INVALID_HUFFMAN_TABLE~;
				if (first)
				{
					decode_ac_first(br, ac, coef, scan.ss, scan.se, scan.al, &self.eob_run)!;
				}
				else
				{
					decode_ac_refine(br, ac, coef, scan.ss, scan.se, scan.al, &self.eob_run)!;
				}
			}

			if (self.restart_interval > 0 && ++rst_count == self.restart_interval)
			{
				rst_count = 0;
				self.handle_restart(br, scan, &next_rst, by, bx)!;
				self.eob_run = 0;
			}
		}
	}
}

// --- Progressive coefficient decoders ---

fn void? decode_dc_first(huffman::BitReader* br, huffman::HuffmanTable* dc, int* coef, int* dc_pred, uint al)
{
	int t = br.decode_symbol(dc)!;
	if (t < 0 || t > 15) return INVALID_BITSTREAM~;
	int diff = br.receive_extend((uint)t)!;
	*dc_pred += diff;
	coef[0] = *dc_pred << al;
}

fn void? decode_dc_refine(huffman::BitReader* br, int* coef, uint al)
{
	int bit = br.receive(1)!;
	if (bit) coef[0] |= 1 << al;
}

fn void? decode_ac_first(
	huffman::BitReader* br,
	huffman::HuffmanTable* ac,
	int* coef,
	uint ss,
	uint se,
	uint al,
	int* eob_run
)
{
	if (*eob_run > 0)
	{
		(*eob_run)--;
		return;
	}

	uint k = ss;
	while (k <= se)
	{
		int rs     = br.decode_symbol(ac)!;
		uint r     = (uint)(rs >> 4);
		uint sbits = (uint)(rs & 0x0F);
		if (sbits == 0)
		{
			if (r < 15)
			{
				int run = 1 << r;
				if (r > 0) run += br.receive(r)!;
				*eob_run = run - 1;
				return;
			}
			// ZRL: skip 16 zero coefficients
			k += 16;
			continue;
		}
		k += r;
		if (k > se) return INVALID_BITSTREAM~;
		int v = br.receive_extend(sbits)!;
		coef[huffman::ZIGZAG[k]] = v << al;
		k++;
	}
}

// Apply one refinement bit to an existing nonzero coefficient. Returns
// true if `slot` was nonzero (i.e. the bit was consumed).
fn bool? refine_slot(huffman::BitReader* br, int* slot, int p1)
{
	if (*slot == 0) return false;
	int b = br.receive(1)!;
	if (b != 0 && (*slot & p1) == 0)
	{
		*slot += *slot > 0 ? p1 : -p1;
	}
	return true;
}

fn void? decode_ac_refine(
	huffman::BitReader* br,
	huffman::HuffmanTable* ac,
	int* coef,
	uint ss,
	uint se,
	uint al,
	int* eob_run
)
{
	int p1 = 1 << al;
	uint k = ss;

	if (*eob_run == 0)
	{
		while (k <= se)
		{
			int rs       = br.decode_symbol(ac)!;
			uint r       = (uint)(rs >> 4);
			uint sbits   = (uint)(rs & 0x0F);
			int newval   = 0;
			bool placing = false;

			if (sbits == 0)
			{
				if (r != 15)
				{
					// EOBn: this block plus (eob_run - 1) more get refinement-only
					int run = 1 << r;
					if (r > 0) run += br.receive(r)!;
					*eob_run = run;
					break;
				}
				// ZRL: skip 16 zero positions. With r=15 in the inner loop and
				// `r == 0 -> break` semantics, the loop counts down 15 zeros via
				// r-- and breaks on the 16th. The unconditional k++ after the
				// loop accounts for that 16th zero, advancing k past it.
			}
			else if (sbits == 1)
			{
				int sign = br.receive(1)!;
				newval = sign != 0 ? p1 : -p1;
				placing = true;
			}
			else
			{
				return INVALID_BITSTREAM~;
			}

			// Walk forward refining nonzero coefficients; decrement r per zero.
			while (k <= se)
			{
				if (!refine_slot(br, &coef[huffman::ZIGZAG[k]], p1)!)
				{
					if (r == 0) break;
					r--;
				}
				k++;
			}

			if (k > se)
			{
				if (placing) return INVALID_BITSTREAM~;
				break;
			}

			if (placing) coef[huffman::ZIGZAG[k]] = newval;
			k++;
		}
	}

	if (*eob_run > 0)
	{
		while (k <= se)
		{
			refine_slot(br, &coef[huffman::ZIGZAG[k]], p1)!;
			k++;
		}
		(*eob_run)--;
	}
}

// --- Restart and end-of-scan helpers ---

fn void? JpegState.handle_restart(&self, huffman::BitReader* br, ScanInfo* scan, int* next_rst, uint my, uint mx)
{
	br.flush_to_byte();
	if (!br.marker_seen) br.refill();
	if (!br.marker_seen) return;

	char m    = br.marker;
	// Allow EOI on the very last block

	bool last = (my == self.mcu_rows - 1) && (mx == self.mcu_cols - 1);
	if (last && m == markers::EOI) return;
	char expected = (char)(markers::RST0 + (char)*next_rst);
	if (m != expected && !markers::is_rst(m)) return INVALID_BITSTREAM~;
	*next_rst = (*next_rst + 1) & 7;
	br.marker_seen = false;
	br.marker = 0;
	br.buf = 0;
	br.bits = 0;
	for (uint k = 0; k < scan.num_comps; k++)
	{
		self.comp[scan.comps[k].comp_idx].dc_pred = 0;
	}
}

fn sz? finish_scan(huffman::BitReader* br)
{
	if (!br.marker_seen) br.refill();
	if (!br.marker_seen) return UNEXPECTED_EOF~;
	// br.pos points just past the marker bytes (FF + xx). Back up so the
	// outer marker-loop sees the FF prefix.
	return br.pos - 2;
}

// --- Progressive finalize: dequantize and IDCT all blocks into plane buffers ---

fn void? JpegState.finalize_progressive(&self)
{
	for (uint c = 0; c < (uint)self.num_components; c++)
	{
		Component* cm  = &self.comp[c];
		QuantTable* qt = &self.qt[cm.quant_id];
		if (!qt.defined) return INVALID_QUANT_TABLE~;

		for (uint by = 0; by < cm.rows_blocks; by++)
		{
			for (uint bx = 0; bx < cm.cols_blocks; bx++)
			{
				int* src = &cm.coeffs[((sz)by * cm.cols_blocks + bx) * 64];
				sz row_y = (sz)by * 8;
				sz col_x = (sz)bx * 8;
				dequant_idct(qt, src, cm.plane, row_y * (sz)cm.stride + col_x, (sz)cm.stride);
			}
		}
	}
}

// --- Output composition ---

fn Image? JpegState.compose_image(&self)
{
	bool is_color  = self.num_components == 3;
	sz pixel_count = (sz)self.width * (sz)self.height;
	sz out_size    = pixel_count * (is_color ? 3 : 1);
	char[] output  = alloc::new_array(self.allocator, char, out_size);

	if (is_color)
	{
		char[] y_full  = alloc::new_array(self.allocator, char, pixel_count);
		char[] cb_full = alloc::new_array(self.allocator, char, pixel_count);
		char[] cr_full = alloc::new_array(self.allocator, char, pixel_count);
		defer alloc::free(self.allocator, y_full);
		defer alloc::free(self.allocator, cb_full);
		defer alloc::free(self.allocator, cr_full);

		self.upsample_to_full(0, y_full);
		self.upsample_to_full(1, cb_full);
		self.upsample_to_full(2, cr_full);

		ycbcr::ycbcr_to_rgb(y_full, cb_full, cr_full, output, self.width, self.height);
	}
	else
	{
		Component* c = &self.comp[0];
		for (uint y = 0; y < self.height; y++)
		{
			sz src = (sz)y * (sz)c.stride;
			sz dst = (sz)y * (sz)self.width;
			mem::copy(&output[dst], &c.plane[src], (sz)self.width);
		}
	}

	return {
		.width = self.width,
		.height = self.height,
		.bit_depth = 8,
		.format = is_color ? PixelFormat.RGB : PixelFormat.GRAYSCALE,
		.pixels = output,
		.allocator = self.allocator,
	};
}

fn void JpegState.upsample_to_full(&self, uint c_idx, char[] dst)
{
	Component* c = &self.comp[c_idx];
	uint w       = self.width;
	uint h       = self.height;
	uint hs      = (uint)c.h_samp;
	uint vs      = (uint)c.v_samp;
	uint mh      = (uint)self.max_h;
	uint mv      = (uint)self.max_v;

	for (uint y = 0; y < h; y++)
	{
		uint sy = y * vs / mv;
		if (sy >= c.height) sy = c.height - 1;
		sz src_row = (sz)sy * (sz)c.stride;
		sz dst_row = (sz)y * (sz)w;
		for (uint x = 0; x < w; x++)
		{
			uint sx = x * hs / mh;
			if (sx >= c.width) sx = c.width - 1;
			dst[dst_row + x] = c.plane[src_row + sx];
		}
	}
}
