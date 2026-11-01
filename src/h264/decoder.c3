module image::h264;
import std::collections::list;

const uint MAX_PICTURES @private = 18;
const uint MAX_REFS @private = 32;

// A decoded picture: 4:2:0 planes at the coded size (whole macroblocks).
struct Picture
{
	char[] y;
	char[] u;
	char[] v;
	uint width;
	uint height;
	uint crop_left;
	uint crop_right;
	uint crop_top;
	uint crop_bottom;
	bool full_range;
	uint matrix;
	uint id;
	bool short_ref;
	bool long_ref;
	uint frame_num;
	int frame_num_wrap;
	uint long_idx;
}

<*
 @return "The displayed width, after the SPS cropping window"
*>
fn uint Picture.shown_width(&self) => self.width - self.crop_left - self.crop_right;

<*
 @return "The displayed height, after the SPS cropping window"
*>
fn uint Picture.shown_height(&self) => self.height - self.crop_top - self.crop_bottom;

const char MB_SKIP @private = 0;
const char MB_INTER @private = 1;
const char MB_I4 @private = 2;
const char MB_I16 @private = 3;
const char MB_PCM @private = 4;

fn bool is_intra(char kind) @inline @private => kind >= MB_I4;

// What a decoded macroblock leaves for its neighbours and the deblocking filter.
struct MbInfo @private
{
	int slice;      // -1 until decoded in this picture
	char kind;
	char qp;        // QP_Y; 0 for I_PCM
	char[16] nz;    // total_coeff per luma 4x4, raster
	char[8] nzc;    // chroma AC totals: Cb 0..3, Cr 4..7
	char[16] mode;  // Intra 4x4 modes, raster
	short[32] mv;   // per luma 4x4, raster: x, y
	ichar[4] ref;   // per 8x8; -1 intra
	int[4] pic;     // the referenced picture's id per 8x8; -1 intra
}

struct SliceInfo @private
{
	uint disable_deblock;
	int alpha;
	int beta;
	int cb_offset;
	int cr_offset;
}

struct Mmco @private
{
	uint op;
	uint a;
	uint b;
}

struct Slice @private
{
	Bits bits;
	bool intra;
	Pps* pps;
	uint first_mb;
	int qp;
	uint num;
	uint num_ref;
}

struct Decoder
{
	Allocator allocator;
	Sps[32] sps;
	Pps[256] pps;
	uint nal_length_size;
	Picture[MAX_PICTURES] pics;
	MbInfo[] mbs;
	List {SliceInfo} slices;
	List {char} rbsp;
	List {Mmco} mmco;
	uint next_id;

	// The picture being decoded.
	Picture* cur;
	Sps* cur_sps;
	bool started;
	bool cur_ref;
	bool cur_idr;
	bool cur_long;
	bool adaptive;
	uint frame_num;
	Picture*[MAX_REFS + 1] list0;
	Picture* last;

	// Scratch for a macroblock's residual.
	int[16][16] coef;    // luma 4x4 blocks (raster index), raster coefficients
	int[16][4][2] ccoef; // chroma
	int[16] dc;
}

<*
 Prepare an empty decoder; feed it parameter sets with configure, then samples with decode.
*>
fn void Decoder.init(&self, Allocator allocator = mem)
{
	*self = { .allocator = allocator, .nal_length_size = 4 };
	self.slices.init(allocator);
	self.rbsp.init(allocator);
	self.mmco.init(allocator);
}

<*
 Free every picture and buffer the decoder owns.
*>
fn void Decoder.free(&self)
{
	foreach (&p : self.pics) free_planes(self.allocator, p);
	if (self.mbs.len > 0) alloc::free(self.allocator, self.mbs);
	self.mbs = {};
	self.slices.free();
	self.rbsp.free();
	self.mmco.free();
}

fn void free_planes(Allocator allocator, Picture* p) @private
{
	if (p.y.len > 0) alloc::free(allocator, p.y);
	if (p.u.len > 0) alloc::free(allocator, p.u);
	if (p.v.len > 0) alloc::free(allocator, p.v);
	p.y = p.u = p.v = {};
}

// Forget every reference: decoding starts again at an IDR picture.
fn void Decoder.reset(&self)
{
	foreach (&p : self.pics) p.short_ref = p.long_ref = false;
	self.last = null;
	self.started = false;
}

<*
 Read an MP4 avcC box's body: the NAL length size and the parameter sets.

 @return? CORRUPT, Decoder.decode_nal!
*>
fn void? Decoder.configure(&self, char[] avcc)
{
	if (avcc.len < 7) return CORRUPT~;
	self.nal_length_size = (uint)(avcc[4] & 3) + 1;
	usz at = 6;
	uint count = avcc[5] & 0x1F;
	for (uint pass = 0; pass < 2; pass++)
	{
		for (uint i = 0; i < count; i++)
		{
			if (at + 2 > avcc.len) return CORRUPT~;
			usz len = (usz)avcc[at] << 8 | avcc[at + 1];
			at += 2;
			if (at + len > avcc.len) return CORRUPT~;
			self.decode_nal(avcc[at:len])!;
			at += len;
		}
		if (pass == 0)
		{
			if (at >= avcc.len) return CORRUPT~;
			count = avcc[at++];
		}
	}
}

<*
 Decode one access unit (an MP4 sample: length-prefixed NAL units).

 @return "The picture it holds, valid until the next call, or null when it holds none"
 @return? CORRUPT, Decoder.decode_nal!
*>
fn Picture*? Decoder.decode(&self, char[] sample)
{
	self.started = false;
	usz at = 0;
	while (at + self.nal_length_size <= sample.len)
	{
		usz len;
		for (uint i = 0; i < self.nal_length_size; i++) len = len << 8 | sample[at + i];
		at += self.nal_length_size;
		if (len > sample.len - at) return CORRUPT~;
		self.decode_nal(sample[at:len])!;
		at += len;
	}
	if (!self.started) return null;
	self.finish_picture();
	return self.cur;
}

fn void? Decoder.decode_nal(&self, char[] nal)
{
	if (nal.len < 1) return;
	uint type = nal[0] & 0x1F;
	uint ref_idc = (nal[0] >> 5) & 3;
	switch (type)
	{
		case 1:
		case 5:
		case 7:
		case 8:
			char[] payload = unescape(nal[1..], &self.rbsp);
			Bits b = bits_of(payload);
			switch (type)
			{
				case 7: self.read_sps(&b)!;
				case 8: self.read_pps(&b)!;
				default: self.decode_slice(&b, type == 5, ref_idc != 0)!;
			}
		case 2:
		case 3:
		case 4:
			return UNSUPPORTED~;  // data partitioning
		default:
			return;
	}
}

fn void? Decoder.decode_slice(&self, Bits* b, bool idr, bool ref)
{
	Slice s;
	s.first_mb = b.ue();
	uint type = b.ue();
	if (type > 9) return CORRUPT~;
	type %= 5;
	if (type == 1) return B_SLICES~;
	if (type > 2) return UNSUPPORTED~;
	s.intra = type == 2;
	uint pps_id = b.ue();
	if (pps_id > 255 || !self.pps[pps_id].valid) return NO_PARAMETERS~;
	s.pps = &self.pps[pps_id];
	Sps* sps = &self.sps[s.pps.sps_id];
	if (!sps.valid) return NO_PARAMETERS~;
	uint frame_num = b.u(sps.log2_max_frame_num);
	if (idr) b.ue();
	if (sps.poc_type == 0)
	{
		b.skip(sps.log2_max_poc_lsb);
		if (s.pps.bottom_field_pic_order) b.se();
	}
	else if (sps.poc_type == 1 && !sps.delta_pic_order_always_zero)
	{
		b.se();
		if (s.pps.bottom_field_pic_order) b.se();
	}
	if (s.pps.redundant_pic_cnt && b.ue() > 0) return;  // a redundant copy: the primary is enough

	if (!self.started)
	{
		self.begin_picture(sps, frame_num, idr, ref)!;
	}
	else if (sps != self.cur_sps)
	{
		return CORRUPT~;
	}

	s.num_ref = s.pps.num_ref_idx_default;
	Mmco[MAX_REFS + 1] mods;
	uint mod_count;
	if (!s.intra)
	{
		if (b.flag()) s.num_ref = b.ue() + 1;
		if (s.num_ref > MAX_REFS) return CORRUPT~;
		if (b.flag())
		{
			while (true)
			{
				uint idc = b.ue();
				if (idc == 3) break;
				if (idc > 2 || mod_count > MAX_REFS) return CORRUPT~;
				mods[mod_count++] = { .op = idc, .a = b.ue() };
			}
		}
	}
	if (ref)
	{
		if (idr)
		{
			b.skip(1);
			bool long_term = b.flag();
			if (s.first_mb == 0 || self.slices.len() == 0) self.cur_long = long_term;
		}
		else if (b.flag())
		{
			bool first = self.mmco.len() == 0 && !self.adaptive;
			self.adaptive = true;
			while (true)
			{
				uint op = b.ue();
				if (op == 0) break;
				if (op > 6) return CORRUPT~;
				// Op 3 carries two operands, op 5 none, the rest one.
				Mmco m = { .op = op };
				if (op != 5) m.a = b.ue();
				if (op == 3) m.b = b.ue();
				// Every slice repeats the picture's marking; keep the first.
				if (first) self.mmco.push(m);
			}
		}
	}
	int qp = s.pps.init_qp + b.se();
	if (qp < 0 || qp > 51) return CORRUPT~;
	s.qp = qp;
	SliceInfo info = { .cb_offset = s.pps.cb_qp_offset, .cr_offset = s.pps.cr_qp_offset };
	if (s.pps.deblocking_control)
	{
		info.disable_deblock = b.ue();
		if (info.disable_deblock > 2) return CORRUPT~;
		if (info.disable_deblock != 1)
		{
			info.alpha = b.se() * 2;
			info.beta = b.se() * 2;
		}
	}
	if (b.overrun()) return CORRUPT~;
	if (!s.intra) self.build_list0(&s, mods[:mod_count])!;
	s.num = (uint)self.slices.len();
	self.slices.push(info);
	s.bits = *b;
	self.slice_data(&s)!;
}

fn void? Decoder.begin_picture(&self, Sps* sps, uint frame_num, bool idr, bool ref)
{
	if (idr) self.reset();
	self.started = true;
	self.cur_sps = sps;
	self.cur_ref = ref;
	self.cur_idr = idr;
	self.cur_long = false;
	self.adaptive = false;
	self.mmco.clear();
	self.slices.clear();
	self.frame_num = frame_num;

	uint width = sps.width_mbs * 16;
	uint height = sps.height_mbs * 16;
	usz count = (usz)sps.width_mbs * sps.height_mbs;
	if (self.mbs.len != count)
	{
		if (self.mbs.len > 0) alloc::free(self.allocator, self.mbs);
		self.mbs = alloc::new_array(self.allocator, MbInfo, (sz)count);
	}
	foreach (&m : self.mbs) m.slice = -1;

	Picture* pic;
	foreach (&p : self.pics)
	{
		if (p.short_ref || p.long_ref || p == self.last) continue;
		pic = p;
		break;
	}
	if (!pic) return CORRUPT~;
	if (pic.width != width || pic.height != height || pic.y.len == 0)
	{
		free_planes(self.allocator, pic);
		pic.y = alloc::new_array(self.allocator, char, (usz)width * height);
		pic.u = alloc::new_array(self.allocator, char, (usz)width * height / 4);
		pic.v = alloc::new_array(self.allocator, char, (usz)width * height / 4);
	}
	pic.width = width;
	pic.height = height;
	pic.crop_left = sps.crop_left;
	pic.crop_right = sps.crop_right;
	pic.crop_top = sps.crop_top;
	pic.crop_bottom = sps.crop_bottom;
	pic.full_range = sps.full_range;
	pic.matrix = sps.matrix;
	pic.id = ++self.next_id;
	pic.frame_num = frame_num;
	pic.short_ref = pic.long_ref = false;
	self.cur = pic;

	int max_frame_num = 1 << sps.log2_max_frame_num;
	foreach (&p : self.pics)
	{
		if (!p.short_ref) continue;
		p.frame_num_wrap = p.frame_num > frame_num ? (int)p.frame_num - max_frame_num : (int)p.frame_num;
	}
}

// Sort key for RefPicList0: short-term by PicNum descending, long-term by index ascending.
fn int ref_order(Picture* p, bool long_term) @inline @private => long_term ? (int)p.long_idx : -p.frame_num_wrap;

// The reference pictures other than the current one, in RefPicList0 order.
fn Picture*[] Decoder.refs(&self, Picture*[] out, bool long_term)
{
	uint n;
	foreach (&p : self.pics)
	{
		if (p == self.cur || (long_term ? !p.long_ref : !p.short_ref)) continue;
		// Insertion sort: there are at most MAX_PICTURES.
		uint k = n++;
		for (; k > 0 && ref_order(out[k - 1], long_term) > ref_order(p, long_term); k--) out[k] = out[k - 1];
		out[k] = p;
	}
	return out[:n];
}

// The short-term reference with this PicNum, if any.
fn Picture* Decoder.short_ref(&self, int pic_num)
{
	foreach (&p : self.pics)
	{
		if (p.short_ref && p != self.cur && p.frame_num_wrap == pic_num) return p;
	}
	return null;
}

// Free long-term index `idx` by unmarking whichever picture other than `keep` holds it.
fn void Decoder.drop_long(&self, uint idx, Picture* keep)
{
	foreach (&p : self.pics)
	{
		if (p.long_ref && p != keep && p.long_idx == idx) p.long_ref = false;
	}
}

// RefPicList0 for a P slice: short-term by PicNum down, long-term up, then the slice's changes.
fn void? Decoder.build_list0(&self, Slice* s, Mmco[] mods)
{
	// Both fit: there are fewer pictures than MAX_REFS.
	Picture*[MAX_PICTURES] short_buf;
	Picture*[MAX_PICTURES] long_buf;
	Picture*[] shorts = self.refs(&short_buf, false);
	Picture*[] longs = self.refs(&long_buf, true);
	Picture*[MAX_REFS + 1] list;
	list[:shorts.len] = shorts[..];
	list[shorts.len:longs.len] = longs[..];

	uint active = s.num_ref;
	int max_pic_num = 1 << self.cur_sps.log2_max_frame_num;
	int cur_num = (int)self.frame_num;
	int pred = cur_num;
	uint at = 0;
	foreach (m : mods)
	{
		Picture* target;
		if (m.op < 2)
		{
			int diff = (int)m.a + 1;
			int no_wrap = m.op == 0 ? pred - diff : pred + diff;
			if (no_wrap < 0) no_wrap += max_pic_num;
			if (no_wrap >= max_pic_num) no_wrap -= max_pic_num;
			pred = no_wrap;
			target = self.short_ref(no_wrap > cur_num ? no_wrap - max_pic_num : no_wrap);
		}
		else
		{
			foreach (p : longs) if (p.long_idx == m.a) target = p;
		}
		if (!target || at >= active) return CORRUPT~;
		for (uint c = active; c > at; c--) list[c] = list[c - 1];
		list[at++] = target;
		uint keep = at;
		for (uint c = at; c <= active; c++) if (list[c] != target) list[keep++] = list[c];
		for (uint c = keep; c <= active; c++) list[c] = null;
	}
	for (uint i = 0; i < active; i++)
	{
		// A missing entry (a damaged stream) reads the nearest picture there is.
		self.list0[i] = list[i] ?: list[0] ?: self.cur;
	}
}

// The picture's end: deblocked, then marked as a reference.
fn void Decoder.finish_picture(&self)
{
	self.deblock_picture();
	Picture* cur = self.cur;
	self.last = cur;
	if (!self.cur_ref) return;
	if (self.cur_idr)
	{
		// begin_picture already dropped every other reference.
		if (self.cur_long)
		{
			cur.long_ref = true;
			cur.long_idx = 0;
		}
		else
		{
			cur.short_ref = true;
		}
		return;
	}
	bool marked_long;
	bool reset;
	if (self.adaptive)
	{
		int cur_num = (int)self.frame_num;
		foreach (m : self.mmco)
		{
			switch (m.op)
			{
				case 1:
					Picture* target = self.short_ref(cur_num - ((int)m.a + 1));
					if (target) target.short_ref = false;
				case 2:
					self.drop_long(m.a, cur);
				case 3:
					Picture* target = self.short_ref(cur_num - ((int)m.a + 1));
					self.drop_long(m.b, target);
					if (target)
					{
						target.short_ref = false;
						target.long_ref = true;
						target.long_idx = m.b;
					}
				case 4:
					// m.a is the new MaxLongTermFrameIdx + 1; 0 means none.
					foreach (&p : self.pics) if (p.long_ref && p.long_idx >= m.a) p.long_ref = false;
				case 5:
					foreach (&p : self.pics) if (p != cur) p.short_ref = p.long_ref = false;
					reset = true;
				case 6:
					self.drop_long(m.a, cur);
					cur.long_ref = true;
					cur.long_idx = m.a;
					marked_long = true;
			}
		}
	}
	else
	{
		uint shorts;
		uint longs;
		foreach (&p : self.pics)
		{
			if (p == cur) continue;
			if (p.short_ref) shorts++;
			if (p.long_ref) longs++;
		}
		uint most = self.cur_sps.max_num_ref_frames > 0 ? self.cur_sps.max_num_ref_frames : 1;
		if (shorts + longs >= most && shorts > 0)
		{
			Picture* oldest;
			foreach (&p : self.pics)
			{
				if (!p.short_ref || p == cur) continue;
				if (!oldest || p.frame_num_wrap < oldest.frame_num_wrap) oldest = p;
			}
			oldest.short_ref = false;
		}
	}
	if (!marked_long) cur.short_ref = true;
	if (reset) cur.frame_num = 0;
}
