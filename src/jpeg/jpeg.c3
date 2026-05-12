module image::jpeg;
import image;
import image::jpeg::markers;
import image::jpeg::huffman;
import image::jpeg::idct;
import image::jpeg::ycbcr;
import std::io::file;

faultdef INVALID_SIGNATURE,
         UNSUPPORTED_MARKER,
         UNSUPPORTED_SOF,
         INVALID_QUANT_TABLE,
         INVALID_HUFFMAN_TABLE,
         INVALID_SOS,
         UNEXPECTED_EOF,
         INVALID_COMPONENT_COUNT,
         UNSUPPORTED_SAMPLING,
         INVALID_BITSTREAM,
         INVALID_DRI,
         INVALID_SOF;

const sz MAX_COMPONENTS = 3;

struct Component {
	char id;
	char h_samp;
	char v_samp;
	char quant_id;
	char huff_dc_id;
	char huff_ac_id;
	int  dc_pred;
	uint width;       // effective pixel width at component resolution
	uint height;      // effective pixel height at component resolution
	uint stride;      // padded stride (bytes per row in plane buffer)
	uint plane_h;     // padded plane height
	char[] plane;
}

struct QuantTable {
	bool defined;
	int[64] table;    // natural row-major order
}

struct JpegState {
	uint width;
	uint height;
	int  num_components;
	Component[MAX_COMPONENTS] comp;
	QuantTable[4] qt;
	huffman::HuffmanTable[2] huff_dc;
	huffman::HuffmanTable[2] huff_ac;
	int  restart_interval;
	int  max_h;
	int  max_v;
	uint mcu_cols;
	uint mcu_rows;
	Allocator allocator;
}

fn Image? load_file(String path, Allocator allocator = mem) {
	char[] file_data = file::load(allocator, path)!;
	defer alloc::free(allocator, file_data);
	return load_bytes(file_data, allocator);
}

fn Image? tload_file(String path) => load_file(path, tmem);

fn Image? tload_bytes(char[] data) => load_bytes(data, tmem);

fn Image? load_bytes(char[] data, Allocator allocator = mem) {
	if (data.len < 4 || data[0] != 0xFF || data[1] != markers::SOI) {
		return INVALID_SIGNATURE~;
	}

	JpegState state;
	state.allocator = allocator;

	sz offset = 2;
	bool sos_seen = false;
	sz sos_data_offset = 0;

	while (offset < data.len && !sos_seen) {
		markers::Segment seg = markers::next_segment(data, offset)!;
		offset = seg.next_offset;

		if (seg.marker == markers::EOI) break;
		if (seg.marker == markers::SOI) continue;

		if (markers::is_app_or_com(seg.marker)) continue;
		if (markers::is_rst(seg.marker)) continue;

		switch (seg.marker) {
			case markers::DQT:
				parse_dqt(&state, seg.payload)!;
			case markers::DHT:
				parse_dht(&state, seg.payload)!;
			case markers::DRI:
				if (seg.payload.len != 2) return INVALID_DRI~;
				state.restart_interval = (int)markers::read_u16_be(seg.payload);
			case markers::SOF0:
				parse_sof0(&state, seg.payload)!;
			case markers::SOS:
				parse_sos(&state, seg.payload)!;
				sos_data_offset = offset;
				sos_seen = true;
			default:
				if (markers::is_sof(seg.marker)) return UNSUPPORTED_SOF~;
				return UNSUPPORTED_MARKER~;
		}
	}

	if (!sos_seen) return INVALID_SOS~;

	allocate_planes(&state)!;
	defer free_planes(&state);

	decode_scan(&state, data, sos_data_offset)!;

	bool is_color = state.num_components == 3;
	sz out_size = (sz)state.width * (sz)state.height * (is_color ? 3 : 1);
	char[] output = alloc::new_array(allocator, char, out_size);

	if (is_color) {
		sz plane_size = (sz)state.width * (sz)state.height;
		char[] y_full  = alloc::new_array(allocator, char, plane_size);
		char[] cb_full = alloc::new_array(allocator, char, plane_size);
		char[] cr_full = alloc::new_array(allocator, char, plane_size);
		defer alloc::free(allocator, y_full);
		defer alloc::free(allocator, cb_full);
		defer alloc::free(allocator, cr_full);

		upsample_to_full(&state, 0, y_full);
		upsample_to_full(&state, 1, cb_full);
		upsample_to_full(&state, 2, cr_full);

		ycbcr::ycbcr_to_rgb(y_full, cb_full, cr_full, output, state.width, state.height);
	} else {
		Component* c = &state.comp[0];
		for (uint y = 0; y < state.height; y++) {
			sz src = (sz)y * (sz)c.stride;
			sz dst = (sz)y * (sz)state.width;
			for (uint x = 0; x < state.width; x++) {
				output[dst + x] = c.plane[src + x];
			}
		}
	}

	return {
		.width = state.width,
		.height = state.height,
		.bit_depth = 8,
		.format = is_color ? PixelFormat.RGB : PixelFormat.GRAYSCALE,
		.pixels = output,
		.allocator = allocator,
	};
}

fn void? parse_dqt(JpegState* s, char[] payload) {
	sz i = 0;
	while (i < payload.len) {
		if (i + 1 > payload.len) return INVALID_QUANT_TABLE~;
		char pq_tq = payload[i];
		i++;
		uint pq = (uint)(pq_tq >> 4);
		uint tq = (uint)(pq_tq & 0x0F);
		if (pq != 0) return INVALID_QUANT_TABLE~;
		if (tq >= 4) return INVALID_QUANT_TABLE~;
		if (i + 64 > payload.len) return INVALID_QUANT_TABLE~;
		for (uint k = 0; k < 64; k++) {
			s.qt[tq].table[huffman::ZIGZAG[k]] = (int)payload[i + k];
		}
		s.qt[tq].defined = true;
		i += 64;
	}
	return;
}

fn void? parse_dht(JpegState* s, char[] payload) {
	sz i = 0;
	while (i < payload.len) {
		if (i + 17 > payload.len) return INVALID_HUFFMAN_TABLE~;
		char tc_th = payload[i];
		i++;
		uint tc = (uint)(tc_th >> 4);    // 0 = DC, 1 = AC
		uint th = (uint)(tc_th & 0x0F);
		if (tc > 1 || th > 1) return INVALID_HUFFMAN_TABLE~;

		char[] bits = payload[i : 16];
		i += 16;

		uint total = 0;
		for (uint k = 0; k < 16; k++) total += (uint)bits[k];
		if (i + (sz)total > payload.len) return INVALID_HUFFMAN_TABLE~;
		char[] values = payload[i : (sz)total];
		i += (sz)total;

		if (tc == 0) {
			s.huff_dc[th].build(bits, values)!;
		} else {
			s.huff_ac[th].build(bits, values)!;
		}
	}
	return;
}

fn void? parse_sof0(JpegState* s, char[] payload) {
	if (payload.len < 6) return INVALID_SOF~;
	char precision = payload[0];
	if (precision != 8) return UNSUPPORTED_SOF~;
	uint h = markers::read_u16_be(payload[1:2]);
	uint w = markers::read_u16_be(payload[3:2]);
	uint nf = (uint)payload[5];
	if (w == 0 || h == 0) return INVALID_SOF~;
	if (nf != 1 && nf != 3) return INVALID_COMPONENT_COUNT~;
	if (payload.len < (sz)(6 + 3 * nf)) return INVALID_SOF~;

	s.width = w;
	s.height = h;
	s.num_components = (int)nf;

	int max_h = 1;
	int max_v = 1;
	for (uint c = 0; c < nf; c++) {
		sz off = 6 + (sz)c * 3;
		char id = payload[off];
		char hv = payload[off + 1];
		char tq = payload[off + 2];
		char hs = (char)(hv >> 4);
		char vs = (char)(hv & 0x0F);
		if (hs != 1 && hs != 2) return UNSUPPORTED_SAMPLING~;
		if (vs != 1 && vs != 2) return UNSUPPORTED_SAMPLING~;
		if (tq >= 4) return INVALID_SOF~;
		s.comp[c].id = id;
		s.comp[c].h_samp = hs;
		s.comp[c].v_samp = vs;
		s.comp[c].quant_id = tq;
		if ((int)hs > max_h) max_h = (int)hs;
		if ((int)vs > max_v) max_v = (int)vs;
	}
	s.max_h = max_h;
	s.max_v = max_v;
	uint mcu_w_px = (uint)(8 * max_h);
	uint mcu_h_px = (uint)(8 * max_v);
	s.mcu_cols = (w + mcu_w_px - 1) / mcu_w_px;
	s.mcu_rows = (h + mcu_h_px - 1) / mcu_h_px;
	return;
}

fn void? parse_sos(JpegState* s, char[] payload) {
	if (payload.len < 1) return INVALID_SOS~;
	uint ns = (uint)payload[0];
	if ((int)ns != s.num_components) return INVALID_SOS~;
	if (payload.len < (sz)(1 + 2 * ns + 3)) return INVALID_SOS~;

	for (uint k = 0; k < ns; k++) {
		sz off = 1 + (sz)k * 2;
		char cs = payload[off];
		char td_ta = payload[off + 1];
		char td = (char)(td_ta >> 4);
		char ta = (char)(td_ta & 0x0F);
		if (td > 1 || ta > 1) return INVALID_SOS~;

		// Match component by id; for typical JFIF the order matches the SOF.
		int ci = -1;
		for (uint i = 0; i < (uint)s.num_components; i++) {
			if (s.comp[i].id == cs) { ci = (int)i; break; }
		}
		if (ci < 0) return INVALID_SOS~;
		s.comp[ci].huff_dc_id = td;
		s.comp[ci].huff_ac_id = ta;
		s.comp[ci].dc_pred = 0;
	}

	sz tail = 1 + (sz)ns * 2;
	char ss = payload[tail];
	char se = payload[tail + 1];
	char ah_al = payload[tail + 2];
	if (ss != 0 || se != 63 || ah_al != 0) return INVALID_SOS~;
	return;
}

fn void? allocate_planes(JpegState* s) {
	for (uint c = 0; c < (uint)s.num_components; c++) {
		Component* cm = &s.comp[c];
		uint stride = s.mcu_cols * (uint)cm.h_samp * 8;
		uint plane_h = s.mcu_rows * (uint)cm.v_samp * 8;
		cm.stride = stride;
		cm.plane_h = plane_h;
		cm.width  = (s.width  * (uint)cm.h_samp + (uint)s.max_h - 1) / (uint)s.max_h;
		cm.height = (s.height * (uint)cm.v_samp + (uint)s.max_v - 1) / (uint)s.max_v;
		cm.plane = alloc::new_array(s.allocator, char, (sz)stride * (sz)plane_h);
	}
	return;
}

fn void free_planes(JpegState* s) {
	for (uint c = 0; c < MAX_COMPONENTS; c++) {
		if (s.comp[c].plane.len > 0) {
			alloc::free(s.allocator, s.comp[c].plane);
			s.comp[c].plane = {};
		}
	}
}

fn void? decode_scan(JpegState* s, char[] data, sz start_offset) {
	huffman::BitReader br;
	br.init(data, start_offset);

	int rst_count = 0;
	int next_rst = 0;

	for (uint my = 0; my < s.mcu_rows; my++) {
		for (uint mx = 0; mx < s.mcu_cols; mx++) {
			for (uint c = 0; c < (uint)s.num_components; c++) {
				Component* cm = &s.comp[c];
				huffman::HuffmanTable* dc = &s.huff_dc[cm.huff_dc_id];
				huffman::HuffmanTable* ac = &s.huff_ac[cm.huff_ac_id];
				if (!dc.defined || !ac.defined) return INVALID_HUFFMAN_TABLE~;
				QuantTable* qt = &s.qt[cm.quant_id];
				if (!qt.defined) return INVALID_QUANT_TABLE~;

				for (uint vy = 0; vy < (uint)cm.v_samp; vy++) {
					for (uint vx = 0; vx < (uint)cm.h_samp; vx++) {
						int[64] coeffs;
						huffman::decode_block(&br, dc, ac, &coeffs[0], &cm.dc_pred)!;
						for (uint k = 0; k < 64; k++) coeffs[k] *= qt.table[k];

						sz row_y = (sz)((my * (uint)cm.v_samp + vy) * 8);
						sz col_x = (sz)((mx * (uint)cm.h_samp + vx) * 8);
						sz dst_offset = row_y * (sz)cm.stride + col_x;
						idct::idct_block(&coeffs[0], cm.plane, dst_offset, (sz)cm.stride);
					}
				}
			}

			if (s.restart_interval > 0) {
				rst_count++;
				if (rst_count == s.restart_interval) {
					rst_count = 0;
					// Skip to byte boundary, consume RSTn marker.
					br.flush_to_byte();
					if (!br.marker_seen) br.refill();
					if (br.marker_seen) {
						char m = br.marker;
						bool last_mcu = (my == s.mcu_rows - 1) && (mx == s.mcu_cols - 1);
						if (last_mcu && m == markers::EOI) {
							// fine
						} else {
							char expected = (char)(markers::RST0 + (char)next_rst);
							if (m != expected && !markers::is_rst(m)) {
								return INVALID_BITSTREAM~;
							}
							next_rst = (next_rst + 1) & 7;
							// Reset reader for fresh entropy after RSTn.
							br.marker_seen = false;
							br.marker = 0;
							br.buf = 0;
							br.bits = 0;
							for (uint c = 0; c < (uint)s.num_components; c++) s.comp[c].dc_pred = 0;
						}
					}
				}
			}
		}
	}
	return;
}

fn void upsample_to_full(JpegState* s, uint c_idx, char[] dst) {
	Component* c = &s.comp[c_idx];
	uint w = s.width;
	uint h = s.height;
	uint hs = (uint)c.h_samp;
	uint vs = (uint)c.v_samp;
	uint mh = (uint)s.max_h;
	uint mv = (uint)s.max_v;

	for (uint y = 0; y < h; y++) {
		uint sy = y * vs / mv;
		if (sy >= c.height) sy = c.height - 1;
		sz src_row = (sz)sy * (sz)c.stride;
		sz dst_row = (sz)y * (sz)w;
		for (uint x = 0; x < w; x++) {
			uint sx = x * hs / mh;
			if (sx >= c.width) sx = c.width - 1;
			dst[dst_row + x] = c.plane[src_row + sx];
		}
	}
}
