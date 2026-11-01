module image::jpeg;
import image;
import image::jpeg::markers;
import image::jpeg::huffman;
import image::jpeg::idct;
import image::jpeg::ycbcr;
import std::io::file;
import std::math;

excuse INVALID_SIGNATURE,
       UNSUPPORTED_MARKER,
       UNSUPPORTED_SOF,
       INVALID_QUANT_TABLE,
       INVALID_HUFFMAN_TABLE,
       INVALID_SOS,
       INVALID_SOF,
       INVALID_DRI,
       INVALID_SEGMENT,
       INVALID_COMPONENT_COUNT,
       UNSUPPORTED_SAMPLING,
       INVALID_BITSTREAM,
       UNEXPECTED_EOF;

const sz MAX_COMPONENTS @private = 3;

struct Component @private
{
	char id;
	char h_samp;
	char v_samp;
	char quant_id;
	int dc_pred;
	uint width;        // pixels at component resolution
	uint height;
	uint stride;       // plane row length, padded to whole MCUs
	uint rows_blocks;  // padded plane height in blocks
	char[] plane;
	int[] coeffs;      // progressive only: 64 ints per block, natural order
}

// The 64 coefficients of block (bx, by); progressive images only.
fn int[64]* Component.block(&self, uint bx, uint by) @inline
{
	return (int[64]*)&self.coeffs[((sz)by * (self.stride / 8) + bx) * 64];
}

struct QuantTable @private
{
	bool defined;
	int[64] table; // natural row-major order
}

struct ScanComp @private
{
	uint comp_idx;
	char huff_dc_id;
	char huff_ac_id;
}

struct ScanInfo @private
{
	uint num_comps;
	ScanComp[MAX_COMPONENTS] comps;
	uint ss;
	uint se;
	uint ah;
	uint al;
}

struct JpegState @private
{
	uint width;
	uint height;
	uint num_components;
	bool progressive;
	Component[MAX_COMPONENTS] comp;
	QuantTable[4] qt;
	huffman::HuffmanTable[4] huff_dc;
	huffman::HuffmanTable[4] huff_ac;
	uint restart_interval;
	uint max_h;
	uint max_v;
	uint mcu_cols;
	uint mcu_rows;
	int eob_run;
	Allocator allocator;
}

<*
 Load and decode a baseline or progressive JPEG file.

 @return? file::load!, load_bytes!
*>
fn Image? load_file(String path, Allocator allocator = mem)
{
	char[] file_data = file::load(allocator, path)!;
	defer alloc::free(allocator, file_data);
	return load_bytes(file_data, allocator);
}

fn Image? tload_file(String path) => load_file(path, tmem);

fn Image? tload_bytes(char[] data) => load_bytes(data, tmem);

<*
 Decode a JPEG held in memory: 8-bit baseline or progressive, grayscale or YCbCr.

 @return "RGB for colour images, GRAYSCALE for single-component ones; free it with Image.free"
 @return? INVALID_SIGNATURE, UNSUPPORTED_MARKER, UNSUPPORTED_SOF, INVALID_QUANT_TABLE, INVALID_HUFFMAN_TABLE, INVALID_SOS, INVALID_SOF, INVALID_DRI, INVALID_SEGMENT, INVALID_COMPONENT_COUNT, UNSUPPORTED_SAMPLING, INVALID_BITSTREAM, UNEXPECTED_EOF
*>
fn Image? load_bytes(char[] data, Allocator allocator = mem)
{
	if (data.len < 4 || data[0] != 0xFF || data[1] != markers::SOI) return INVALID_SIGNATURE~;

	JpegState state = { .allocator = allocator };
	defer state.free_buffers();

	sz offset = 2;
	bool sof_seen;
	while (offset < data.len)
	{
		markers::Segment seg = markers::next_segment(data, offset)!;
		offset = seg.next_offset;

		if (seg.marker == markers::EOI) break;
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
				state.restart_interval = markers::read_u16_be(seg.payload);
			case markers::SOF0:
			case markers::SOF2:
				if (sof_seen) return INVALID_SOF~;
				state.start_frame(seg.payload, seg.marker == markers::SOF2)!;
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

	if (!sof_seen) return INVALID_SOF~;
	if (state.progressive) state.finalize_progressive()!;
	return state.compose_image();
}

fn void? JpegState.parse_dqt(&self, char[] payload)
{
	sz i = 0;
	while (i < payload.len)
	{
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
	self.num_components = nf;
	self.progressive = progressive;

	uint max_h = 1;
	uint max_v = 1;
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
		max_h = math::max(max_h, (uint)hs);
		max_v = math::max(max_v, (uint)vs);
	}
	self.max_h = max_h;
	self.max_v = max_v;
	self.mcu_cols = (w + 8 * max_h - 1) / (8 * max_h);
	self.mcu_rows = (h + 8 * max_v - 1) / (8 * max_v);
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
		for (uint i = 0; i < self.num_components; i++)
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

fn void JpegState.allocate_planes(&self)
{
	foreach (&cm : self.comp[:self.num_components])
	{
		cm.stride = self.mcu_cols * cm.h_samp * 8;
		cm.rows_blocks = self.mcu_rows * cm.v_samp;
		cm.width = (self.width * cm.h_samp + self.max_h - 1) / self.max_h;
		cm.height = (self.height * cm.v_samp + self.max_v - 1) / self.max_v;
		cm.plane = alloc::new_array(self.allocator, char, (sz)cm.stride * cm.rows_blocks * 8);
	}
}

fn void JpegState.allocate_coeffs(&self)
{
	foreach (&cm : self.comp[:self.num_components])
	{
		cm.coeffs = alloc::new_array(self.allocator, int, (sz)cm.stride / 8 * cm.rows_blocks * 64);
	}
}

fn void JpegState.free_buffers(&self)
{
	foreach (&cm : self.comp)
	{
		if (cm.plane.len > 0) alloc::free(self.allocator, cm.plane);
		if (cm.coeffs.len > 0) alloc::free(self.allocator, cm.coeffs);
		cm.plane = {};
		cm.coeffs = {};
	}
}

// Dequantize a block (natural order) and inverse-DCT it into block (bx, by) of the plane.
fn void dequant_idct(QuantTable* qt, int[64]* coeffs, Component* cm, uint bx, uint by) @private
{
	int[64] block;
	foreach (i, c : *coeffs) block[i] = c * qt.table[i];
	idct::idct_block(&block[0], cm.plane, (sz)by * 8 * cm.stride + (sz)bx * 8, cm.stride);
}

// Count one restart unit; at each interval boundary except the scan's last unit, expect RSTn.
// Returns true when a restart happened.
fn bool? JpegState.count_restart(&self, huffman::BitReader* br, ScanInfo* scan, uint* count, bool last)
{
	if (self.restart_interval == 0 || ++*count != self.restart_interval) return false;
	*count = 0;
	// After the last unit comes whatever ends the scan (EOI, DHT, SOS...), not RSTn.
	if (last) return false;
	self.handle_restart(br, scan)!;
	return true;
}

// Baseline: one interleaved or single-component scan of full 0..63 blocks.
fn sz? JpegState.decode_baseline_scan(&self, ScanInfo* scan, char[] data, sz start_offset)
{
	foreach (sc : scan.comps[:scan.num_comps])
	{
		if (!self.huff_dc[sc.huff_dc_id].defined || !self.huff_ac[sc.huff_ac_id].defined) return INVALID_HUFFMAN_TABLE~;
		if (!self.qt[self.comp[sc.comp_idx].quant_id].defined) return INVALID_QUANT_TABLE~;
	}

	huffman::BitReader br;
	br.init(data, start_offset);
	uint rst_count;
	for (uint my = 0; my < self.mcu_rows; my++)
	{
		for (uint mx = 0; mx < self.mcu_cols; mx++)
		{
			foreach (sc : scan.comps[:scan.num_comps])
			{
				Component* cm = &self.comp[sc.comp_idx];
				for (uint vy = 0; vy < cm.v_samp; vy++)
				{
					for (uint vx = 0; vx < cm.h_samp; vx++)
					{
						int[64] coeffs;
						huffman::decode_block(&br, &self.huff_dc[sc.huff_dc_id], &self.huff_ac[sc.huff_ac_id], &coeffs, &cm.dc_pred)!;
						dequant_idct(&self.qt[cm.quant_id], &coeffs, cm, mx * cm.h_samp + vx, my * cm.v_samp + vy);
					}
				}
			}
			bool last = my == self.mcu_rows - 1 && mx == self.mcu_cols - 1;
			self.count_restart(&br, scan, &rst_count, last)!;
		}
	}
	return finish_scan(&br);
}

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

// DC for one block: the first pass reads the shifted value, later passes add one bit.
fn void? decode_dc(huffman::BitReader* br, huffman::HuffmanTable* dc, int* coef, int* dc_pred, ScanInfo* scan) @private
{
	if (scan.ah == 0)
	{
		coef[0] = huffman::decode_dc(br, dc, dc_pred)! << scan.al;
	}
	else if (br.receive(1)!)
	{
		coef[0] |= 1 << scan.al;
	}
}

// Multi-component scan: DC only (parse_sos rejects interleaved AC scans).
fn void? JpegState.decode_progressive_interleaved(&self, huffman::BitReader* br, ScanInfo* scan)
{
	if (scan.ah == 0)
	{
		foreach (sc : scan.comps[:scan.num_comps])
		{
			if (!self.huff_dc[sc.huff_dc_id].defined) return INVALID_HUFFMAN_TABLE~;
		}
	}

	uint rst_count;
	for (uint my = 0; my < self.mcu_rows; my++)
	{
		for (uint mx = 0; mx < self.mcu_cols; mx++)
		{
			foreach (sc : scan.comps[:scan.num_comps])
			{
				Component* cm = &self.comp[sc.comp_idx];
				for (uint vy = 0; vy < cm.v_samp; vy++)
				{
					for (uint vx = 0; vx < cm.h_samp; vx++)
					{
						int[64]* coef = cm.block(mx * cm.h_samp + vx, my * cm.v_samp + vy);
						decode_dc(br, &self.huff_dc[sc.huff_dc_id], &(*coef)[0], &cm.dc_pred, scan)!;
					}
				}
			}
			bool last = my == self.mcu_rows - 1 && mx == self.mcu_cols - 1;
			self.count_restart(br, scan, &rst_count, last)!;
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
	if (dc_only ? first && !dc.defined : !ac.defined) return INVALID_HUFFMAN_TABLE~;

	// Block counts for a non-interleaved scan (T.81 A.2.4):
	//   ceil(X * H_i / (8 * H_max)) x ceil(Y * V_i / (8 * V_max))
	uint nb_x = (self.width * cm.h_samp + 8 * self.max_h - 1) / (8 * self.max_h);
	uint nb_y = (self.height * cm.v_samp + 8 * self.max_v - 1) / (8 * self.max_v);

	uint rst_count;
	for (uint by = 0; by < nb_y; by++)
	{
		for (uint bx = 0; bx < nb_x; bx++)
		{
			int* coef = &(*cm.block(bx, by))[0];
			switch
			{
				case dc_only:
					decode_dc(br, dc, coef, &cm.dc_pred, scan)!;
				case first:
					decode_ac_first(br, ac, coef, scan.ss, scan.se, scan.al, &self.eob_run)!;
				default:
					decode_ac_refine(br, ac, coef, scan.ss, scan.se, scan.al, &self.eob_run)!;
			}
			bool last = by == nb_y - 1 && bx == nb_x - 1;
			if (self.count_restart(br, scan, &rst_count, last)!) self.eob_run = 0;
		}
	}
}

// Length of an end-of-band run: 2^r plus r extra bits.
fn int? read_eob_run(huffman::BitReader* br, uint r) @private => (1 << r) + br.receive(r)!;

fn void? decode_ac_first(
	huffman::BitReader* br,
	huffman::HuffmanTable* ac,
	int* coef,
	uint ss,
	uint se,
	uint al,
	int* eob_run
) @private
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
				*eob_run = read_eob_run(br, r)! - 1;
				return;
			}
			// ZRL: skip 16 zero coefficients
			k += 16;
			continue;
		}
		k += r;
		if (k > se) return INVALID_BITSTREAM~;
		coef[huffman::ZIGZAG[k]] = br.receive_extend(sbits)! << al;
		k++;
	}
}

// Apply one refinement bit to an existing nonzero coefficient. Returns
// true if `slot` was nonzero (i.e. the bit was consumed).
fn bool? refine_slot(huffman::BitReader* br, int* slot, int p1) @private
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
) @private
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
					*eob_run = read_eob_run(br, r)!;
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

// Consume an RSTn marker and reset the entropy decoder state.
fn void? JpegState.handle_restart(&self, huffman::BitReader* br, ScanInfo* scan)
{
	br.flush_to_byte();
	if (!br.marker_seen) br.refill();
	if (!br.marker_seen) return;
	if (!markers::is_rst(br.marker)) return INVALID_BITSTREAM~;
	br.marker_seen = false;
	br.marker = 0;
	br.buf = 0;
	br.bits = 0;
	foreach (sc : scan.comps[:scan.num_comps]) self.comp[sc.comp_idx].dc_pred = 0;
}

fn sz? finish_scan(huffman::BitReader* br) @private
{
	if (!br.marker_seen) br.refill();
	if (!br.marker_seen) return UNEXPECTED_EOF~;
	// br.pos points just past the marker bytes (FF + xx). Back up so the
	// outer marker-loop sees the FF prefix.
	return br.pos - 2;
}

// Dequantize and IDCT every progressive block into the planes.
fn void? JpegState.finalize_progressive(&self)
{
	foreach (&cm : self.comp[:self.num_components])
	{
		QuantTable* qt = &self.qt[cm.quant_id];
		if (!qt.defined) return INVALID_QUANT_TABLE~;
		for (uint by = 0; by < cm.rows_blocks; by++)
		{
			for (uint bx = 0; bx < cm.stride / 8; bx++) dequant_idct(qt, cm.block(bx, by), cm, bx, by);
		}
	}
}

fn Image JpegState.compose_image(&self)
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

		ycbcr::ycbcr_to_rgb(y_full, cb_full, cr_full, output);
	}
	else
	{
		self.upsample_to_full(0, output);
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
	for (uint y = 0; y < self.height; y++)
	{
		uint sy = math::min(y * c.v_samp / self.max_v, c.height - 1);
		char[] src = c.plane[(sz)sy * c.stride:c.stride];
		char[] out = dst[(sz)y * self.width:self.width];
		foreach (x, &px : out) *px = src[math::min((uint)x * c.h_samp / self.max_h, c.width - 1)];
	}
}
