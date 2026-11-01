module image::h264;

<*
 What this decoder reads: progressive 4:2:0 8-bit H.264 coded with CAVLC and
 I/P slices (Constrained Baseline, and Main/High streams that keep to it).
 Anything else is refused with the fault naming what it needs.
*>
excuse CABAC, B_SLICES, INTERLACED, TRANSFORM_8X8, SAMPLING, SLICE_GROUPS, WEIGHTED, SCALING_LISTS, UNSUPPORTED, CORRUPT, NO_PARAMETERS;

struct Sps @private
{
	bool valid;
	uint log2_max_frame_num;
	uint poc_type;
	uint log2_max_poc_lsb;
	bool delta_pic_order_always_zero;
	uint max_num_ref_frames;
	uint width_mbs;
	uint height_mbs;
	uint crop_left;   // luma samples
	uint crop_right;
	uint crop_top;
	uint crop_bottom;
	bool full_range;
	uint matrix;      // matrix_coefficients; 2 = unspecified
}

struct Pps @private
{
	bool valid;
	uint sps_id;
	bool bottom_field_pic_order;
	uint num_ref_idx_default;  // active entries
	bool weighted_pred;
	int init_qp;
	int cb_qp_offset;
	int cr_qp_offset;
	bool deblocking_control;
	bool constrained_intra;
	bool redundant_pic_cnt;
}

fn bool high_profile(uint profile) @private
{
	switch (profile)
	{
		case 100: case 110: case 122: case 244: case 44: case 83: case 86: case 118: case 128: case 138: case 139: case 134: case 135:
			return true;
		default:
			return false;
	}
}

fn void? Decoder.read_sps(&self, Bits* b)
{
	uint profile = b.u(8);
	b.skip(16);
	uint id = b.ue();
	if (id > 31) return CORRUPT~;
	Sps s = { .matrix = 2 };
	if (high_profile(profile))
	{
		// Anything but 4:2:0 is refused, so 4:4:4's extra flag needn't be skipped.
		uint chroma = b.ue();
		uint depth_luma = b.ue();
		uint depth_chroma = b.ue();
		bool bypass = b.flag();
		if (chroma != 1 || depth_luma != 0 || depth_chroma != 0 || bypass) return SAMPLING~;
		if (b.flag()) return SCALING_LISTS~;
	}
	s.log2_max_frame_num = b.ue() + 4;
	if (s.log2_max_frame_num > 16) return CORRUPT~;
	s.poc_type = b.ue();
	if (s.poc_type == 0)
	{
		s.log2_max_poc_lsb = b.ue() + 4;
		if (s.log2_max_poc_lsb > 16) return CORRUPT~;
	}
	else if (s.poc_type == 1)
	{
		s.delta_pic_order_always_zero = b.flag();
		b.se();
		b.se();
		uint cycle = b.ue();
		if (cycle > 255) return CORRUPT~;
		for (uint i = 0; i < cycle; i++) b.se();
	}
	else if (s.poc_type != 2)
	{
		return CORRUPT~;
	}
	s.max_num_ref_frames = b.ue();
	if (s.max_num_ref_frames > 16) return CORRUPT~;
	b.skip(1);
	s.width_mbs = b.ue() + 1;
	s.height_mbs = b.ue() + 1;
	if (s.width_mbs > 512 || s.height_mbs > 512) return CORRUPT~;
	if (!b.flag()) return INTERLACED~;
	b.skip(1);
	if (b.flag())
	{
		s.crop_left = b.ue() * 2;
		s.crop_right = b.ue() * 2;
		s.crop_top = b.ue() * 2;
		s.crop_bottom = b.ue() * 2;
		if (s.crop_left + s.crop_right >= s.width_mbs * 16 || s.crop_top + s.crop_bottom >= s.height_mbs * 16) return CORRUPT~;
	}
	if (b.flag())
	{
		if (b.flag())
		{
			if (b.u(8) == 255) b.skip(32);
		}
		if (b.flag()) b.skip(1);
		if (b.flag())
		{
			b.skip(3);
			s.full_range = b.flag();
			if (b.flag())
			{
				b.skip(16);
				s.matrix = b.u(8);
			}
		}
	}
	s.valid = true;
	self.sps[id] = s;
}

fn void? Decoder.read_pps(&self, Bits* b)
{
	uint id = b.ue();
	if (id > 255) return CORRUPT~;
	Pps p;
	p.sps_id = b.ue();
	if (p.sps_id > 31) return CORRUPT~;
	if (b.flag()) return CABAC~;
	p.bottom_field_pic_order = b.flag();
	if (b.ue() != 0) return SLICE_GROUPS~;
	p.num_ref_idx_default = b.ue() + 1;
	b.ue();
	if (p.num_ref_idx_default > 32) return CORRUPT~;
	p.weighted_pred = b.flag();
	b.skip(2);
	p.init_qp = 26 + b.se();
	b.se();
	p.cb_qp_offset = b.se();
	p.cr_qp_offset = p.cb_qp_offset;
	p.deblocking_control = b.flag();
	p.constrained_intra = b.flag();
	p.redundant_pic_cnt = b.flag();
	if (b.more_data())
	{
		if (b.flag()) return TRANSFORM_8X8~;
		if (b.flag()) return SCALING_LISTS~;
		p.cr_qp_offset = b.se();
	}
	if (p.weighted_pred) return WEIGHTED~;
	if (p.init_qp < 0 || p.init_qp > 51 || p.cb_qp_offset < -12 || p.cb_qp_offset > 12) return CORRUPT~;
	p.valid = true;
	self.pps[id] = p;
}
