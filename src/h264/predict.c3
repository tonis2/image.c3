module image::h264;

// LevelScale for flat matrices (8.5.9): by qP % 6 and position class.
const int[3][6] LEVEL_SCALE @private = { { 10, 16, 13 }, { 11, 18, 14 }, { 13, 20, 16 }, { 14, 23, 18 }, { 16, 25, 20 }, { 18, 29, 23 } };
const char[16] SCALE_CLASS @private = { 0, 2, 0, 2, 2, 1, 2, 1, 0, 2, 0, 2, 2, 1, 2, 1 };
// QPc from qPi (Table 8-15).
const char[52] CHROMA_QP @private = {
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
	29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39 };

fn int clip1(int v) @inline @private => v < 0 ? 0 : v > 255 ? 255 : v;
fn int clip3(int lo, int hi, int v) @inline @private => v < lo ? lo : v > hi ? hi : v;

fn int clip_qp(int qp) @inline @private => clip3(0, 51, qp);
fn int chroma_qp(int qp, int offset) @private => CHROMA_QP[clip_qp(qp + offset)];

// The flat-matrix scale for a DC level at `qp`.
fn int dc_scale(int qp) @inline @private => LEVEL_SCALE[qp % 6][0] * 16;

// Scale levels c[first..15] into d (8.5.12.1); true when any is nonzero.
fn bool dequant(int[16]* c, int[16]* d, int qp, uint first) @private
{
	bool nonzero;
	int shift = qp / 6;
	int[3] scale = LEVEL_SCALE[qp % 6];
	for (uint k = first; k < 16; k++)
	{
		if ((*c)[k] == 0) continue;
		(*d)[k] = ((*c)[k] * scale[SCALE_CLASS[k]]) << shift;
		nonzero = true;
	}
	return nonzero;
}

// The 4x4 inverse transform of `d` (raster) added to the samples at `at`.
fn void idct_add(int* d, char[] plane, usz at, usz stride) @private
{
	int[16] f;
	for (int i = 0; i < 4; i++)
	{
		int* r = d + i * 4;
		int e0 = r[0] + r[2];
		int e1 = r[0] - r[2];
		int e2 = (r[1] >> 1) - r[3];
		int e3 = r[1] + (r[3] >> 1);
		f[i * 4] = e0 + e3;
		f[i * 4 + 1] = e1 + e2;
		f[i * 4 + 2] = e1 - e2;
		f[i * 4 + 3] = e0 - e3;
	}
	for (int j = 0; j < 4; j++)
	{
		int g0 = f[j] + f[8 + j];
		int g1 = f[j] - f[8 + j];
		int g2 = (f[4 + j] >> 1) - f[12 + j];
		int g3 = f[4 + j] + (f[12 + j] >> 1);
		int[4] h = { g0 + g3, g1 + g2, g1 - g2, g0 - g3 };
		for (int i = 0; i < 4; i++)
		{
			usz p = at + (usz)i * stride + (usz)j;
			plane[p] = (char)clip1((int)plane[p] + ((h[i] + 32) >> 6));
		}
	}
}

// Intra 16x16's DC levels, transformed and scaled, in place (8.5.10).
fn void Decoder.luma_dc(&self, int qp)
{
	int* c = &self.dc;
	int[16] f;
	for (int i = 0; i < 4; i++)
	{
		int* r = c + i * 4;
		f[i * 4] = r[0] + r[1] + r[2] + r[3];
		f[i * 4 + 1] = r[0] + r[1] - r[2] - r[3];
		f[i * 4 + 2] = r[0] - r[1] - r[2] + r[3];
		f[i * 4 + 3] = r[0] - r[1] + r[2] - r[3];
	}
	int scale = dc_scale(qp);
	for (int j = 0; j < 4; j++)
	{
		int[4] g = {
			f[j] + f[4 + j] + f[8 + j] + f[12 + j],
			f[j] + f[4 + j] - f[8 + j] - f[12 + j],
			f[j] - f[4 + j] - f[8 + j] + f[12 + j],
			f[j] - f[4 + j] + f[8 + j] - f[12 + j] };
		for (int i = 0; i < 4; i++)
		{
			int v = g[i] * scale;
			c[i * 4 + j] = qp >= 36 ? v << (qp / 6 - 6) : (v + (1 << (5 - qp / 6))) >> (6 - qp / 6);
		}
	}
}

// Luma block `r`'s residual scaled and added; with `i16` its DC is the transformed one.
fn void Decoder.add_luma(&self, uint addr, uint r, int qp, bool i16)
{
	int[16] d;
	bool nonzero = dequant(&self.coef[r], &d, qp, i16 ? 1 : 0);
	if (i16)
	{
		d[0] = self.dc[r];
		if (d[0] != 0) nonzero = true;
	}
	if (!nonzero) return;
	Picture* p = self.cur;
	uint w = self.cur_sps.width_mbs;
	usz x = (usz)(addr % w) * 16 + (usz)(r & 3) * 4;
	usz y = (usz)(addr / w) * 16 + (usz)(r >> 2) * 4;
	idct_add(&d, p.y, y * p.width + x, p.width);
}

// Both chroma components' residual: DC transformed and scaled, then each block.
fn void Decoder.add_chroma(&self, uint addr, int qp_y, Slice* s)
{
	Picture* p = self.cur;
	uint w = self.cur_sps.width_mbs;
	usz cw = p.width / 2;
	usz x = (usz)(addr % w) * 8;
	usz y = (usz)(addr / w) * 8;
	foreach (c, plane : (char[][]){ p.u, p.v })
	{
		int qp = chroma_qp(qp_y, c == 0 ? s.pps.cb_qp_offset : s.pps.cr_qp_offset);
		int c0 = self.ccoef[c][0][0];
		int c1 = self.ccoef[c][1][0];
		int c2 = self.ccoef[c][2][0];
		int c3 = self.ccoef[c][3][0];
		int[4] f = { c0 + c1 + c2 + c3, c0 - c1 + c2 - c3, c0 + c1 - c2 - c3, c0 - c1 - c2 + c3 };
		int scale = dc_scale(qp);
		for (uint k = 0; k < 4; k++)
		{
			int[16] d;
			d[0] = ((f[k] * scale) << (qp / 6)) >> 5;
			bool nonzero = dequant(&self.ccoef[c][k], &d, qp, 1);
			if (!nonzero && d[0] == 0) continue;
			idct_add(&d, plane, (y + (usz)(k >> 1) * 4) * cw + x + (usz)(k & 1) * 4, cw);
		}
	}
}

fn void? Decoder.intra4x4(&self, Slice* s, uint addr, uint r)
{
	MbInfo* mb = &self.mbs[addr];
	uint bx = r & 3;
	uint by = r >> 2;
	bool left_mb = self.intra_mb(s, addr, -1, 0) != null;
	bool above_mb = self.intra_mb(s, addr, 0, -1) != null;
	bool has_left = bx > 0 || left_mb;
	bool has_top = by > 0 || above_mb;
	bool has_corner;
	if (bx > 0 && by > 0)
	{
		has_corner = true;
	}
	else if (bx > 0)
	{
		has_corner = above_mb;
	}
	else if (by > 0)
	{
		has_corner = left_mb;
	}
	else
	{
		has_corner = self.intra_mb(s, addr, -1, -1) != null;
	}
	bool has_right;
	if (by == 0)
	{
		has_right = bx < 3 ? above_mb : self.intra_mb(s, addr, 1, -1) != null;
	}
	else
	{
		has_right = bx < 3 && r != 5 && r != 13;
	}

	Picture* p = self.cur;
	usz stride = p.width;
	uint w = self.cur_sps.width_mbs;
	usz x0 = (usz)(addr % w) * 16 + (usz)bx * 4;
	usz y0 = (usz)(addr / w) * 16 + (usz)by * 4;
	usz at = y0 * stride + x0;
	int[8] t;
	int[4] l;
	int q;
	if (has_top)
	{
		for (usz i = 0; i < 4; i++) t[i] = p.y[at - stride + i];
		for (usz i = 4; i < 8; i++) t[i] = has_right ? p.y[at - stride + i] : t[3];
	}
	if (has_left) for (usz i = 0; i < 4; i++) l[i] = p.y[at + i * stride - 1];
	if (has_corner) q = p.y[at - stride - 1];

	uint mode = mb.mode[r];
	switch (mode)
	{
		case 0: if (!has_top) return CORRUPT~;
		case 1:
		case 8: if (!has_left) return CORRUPT~;
		case 3:
		case 7: if (!has_top) return CORRUPT~;
		case 4:
		case 5:
		case 6: if (!has_top || !has_left || !has_corner) return CORRUPT~;
		default: break;
	}
	int dc;
	if (mode == 2)
	{
		if (has_top && has_left)
		{
			dc = (t[0] + t[1] + t[2] + t[3] + l[0] + l[1] + l[2] + l[3] + 4) >> 3;
		}
		else if (has_left)
		{
			dc = (l[0] + l[1] + l[2] + l[3] + 2) >> 2;
		}
		else if (has_top)
		{
			dc = (t[0] + t[1] + t[2] + t[3] + 2) >> 2;
		}
		else
		{
			dc = 128;
		}
	}
	for (int y = 0; y < 4; y++)
	{
		for (int x = 0; x < 4; x++)
		{
			int v;
			switch (mode)
			{
				case 0: v = t[x];
				case 1: v = l[y];
				case 2: v = dc;
				case 3:
					v = x == 3 && y == 3 ? (t[6] + 3 * t[7] + 2) >> 2 : (t[x + y] + 2 * t[x + y + 1] + t[x + y + 2] + 2) >> 2;
				case 4:
					if (x > y)
					{
						v = (top_at(&t, q, x - y - 2) + 2 * top_at(&t, q, x - y - 1) + t[x - y] + 2) >> 2;
					}
					else if (x < y)
					{
						v = (left_at(&l, q, y - x - 2) + 2 * left_at(&l, q, y - x - 1) + l[y - x] + 2) >> 2;
					}
					else
					{
						v = (t[0] + 2 * q + l[0] + 2) >> 2;
					}
				case 5:
					int z = 2 * x - y;
					if (z >= 0 && (z & 1) == 0)
					{
						v = (top_at(&t, q, x - (y >> 1) - 1) + t[x - (y >> 1)] + 1) >> 1;
					}
					else if (z >= 0)
					{
						v = (top_at(&t, q, x - (y >> 1) - 2) + 2 * top_at(&t, q, x - (y >> 1) - 1) + t[x - (y >> 1)] + 2) >> 2;
					}
					else if (z == -1)
					{
						v = (l[0] + 2 * q + t[0] + 2) >> 2;
					}
					else
					{
						v = (l[y - 1] + 2 * l[y - 2] + left_at(&l, q, y - 3) + 2) >> 2;
					}
				case 6:
					int z = 2 * y - x;
					if (z >= 0 && (z & 1) == 0)
					{
						v = (left_at(&l, q, y - (x >> 1) - 1) + l[y - (x >> 1)] + 1) >> 1;
					}
					else if (z >= 0)
					{
						v = (left_at(&l, q, y - (x >> 1) - 2) + 2 * left_at(&l, q, y - (x >> 1) - 1) + l[y - (x >> 1)] + 2) >> 2;
					}
					else if (z == -1)
					{
						v = (l[0] + 2 * q + t[0] + 2) >> 2;
					}
					else
					{
						v = (t[x - 1] + 2 * t[x - 2] + top_at(&t, q, x - 3) + 2) >> 2;
					}
				case 7:
					int k = x + (y >> 1);
					v = (y & 1) == 0 ? (t[k] + t[k + 1] + 1) >> 1 : (t[k] + 2 * t[k + 1] + t[k + 2] + 2) >> 2;
				default:
					int z = x + 2 * y;
					int k = y + (x >> 1);
					if (z > 5)
					{
						v = l[3];
					}
					else if (z == 5)
					{
						v = (l[2] + 3 * l[3] + 2) >> 2;
					}
					else if ((z & 1) == 0)
					{
						v = (l[k] + l[k + 1] + 1) >> 1;
					}
					else
					{
						v = (l[k] + 2 * l[k + 1] + l[k + 2] + 2) >> 2;
					}
			}
			p.y[at + (usz)y * stride + (usz)x] = (char)v;
		}
	}
}

// p[i, -1] for i >= -1 (the corner at -1).
fn int top_at(int[8]* t, int q, int i) @inline @private => i < 0 ? q : (*t)[i];
// p[-1, i] for i >= -1.
fn int left_at(int[4]* l, int q, int i) @inline @private => i < 0 ? q : (*l)[i];

<*
 Plane prediction's a, b and c (8.3.3.4, 8.3.4.4) from the top row, left column and corner.

 @require t.len == l.len && (t.len == 16 || t.len == 8) : "16 luma or 8 chroma neighbours"
*>
fn int[<3>] plane_params(int[] t, int[] l, int q, int scale) @private
{
	int half = (int)t.len / 2;
	int h;
	int v;
	for (int i = 0; i < half; i++)
	{
		int k = half - 2 - i;
		h += (i + 1) * (t[half + i] - (k >= 0 ? t[k] : q));
		v += (i + 1) * (l[half + i] - (k >= 0 ? l[k] : q));
	}
	return { 16 * (l[^1] + t[^1]), (scale * h + 32) >> 6, (scale * v + 32) >> 6 };
}

fn void? Decoder.intra16x16(&self, Slice* s, uint addr, uint mode)
{
	bool has_left = self.intra_mb(s, addr, -1, 0) != null;
	bool has_top = self.intra_mb(s, addr, 0, -1) != null;
	bool has_corner = self.intra_mb(s, addr, -1, -1) != null;
	Picture* p = self.cur;
	usz stride = p.width;
	uint w = self.cur_sps.width_mbs;
	usz at = (usz)(addr / w) * 16 * stride + (usz)(addr % w) * 16;
	int[16] t;
	int[16] l;
	if (has_top) for (usz i = 0; i < 16; i++) t[i] = p.y[at - stride + i];
	if (has_left) for (usz i = 0; i < 16; i++) l[i] = p.y[at + i * stride - 1];
	int q = has_corner ? p.y[at - stride - 1] : 0;
	switch (mode)
	{
		case 0: if (!has_top) return CORRUPT~;
		case 1: if (!has_left) return CORRUPT~;
		case 3: if (!has_top || !has_left || !has_corner) return CORRUPT~;
		default: break;
	}
	int dc = 128;
	int sum_t;
	int sum_l;
	for (int i = 0; i < 16; i++)
	{
		sum_t += t[i];
		sum_l += l[i];
	}
	if (has_top && has_left)
	{
		dc = (sum_t + sum_l + 16) >> 5;
	}
	else if (has_left)
	{
		dc = (sum_l + 8) >> 4;
	}
	else if (has_top)
	{
		dc = (sum_t + 8) >> 4;
	}
	int[<3>] abc;
	if (mode == 3) abc = plane_params(&t, &l, q, 5);
	for (int y = 0; y < 16; y++)
	{
		for (int x = 0; x < 16; x++)
		{
			int val;
			switch (mode)
			{
				case 0: val = t[x];
				case 1: val = l[y];
				case 2: val = dc;
				default: val = clip1((abc[0] + abc[1] * (x - 7) + abc[2] * (y - 7) + 16) >> 5);
			}
			p.y[at + (usz)y * stride + (usz)x] = (char)val;
		}
	}
}

fn void? Decoder.intra_chroma(&self, Slice* s, uint addr, uint mode)
{
	bool has_left = self.intra_mb(s, addr, -1, 0) != null;
	bool has_top = self.intra_mb(s, addr, 0, -1) != null;
	bool has_corner = self.intra_mb(s, addr, -1, -1) != null;
	switch (mode)
	{
		case 1: if (!has_left) return CORRUPT~;
		case 2: if (!has_top) return CORRUPT~;
		case 3: if (!has_top || !has_left || !has_corner) return CORRUPT~;
		default: break;
	}
	Picture* p = self.cur;
	usz stride = p.width / 2;
	uint w = self.cur_sps.width_mbs;
	usz at = (usz)(addr / w) * 8 * stride + (usz)(addr % w) * 8;
	foreach (plane : (char[][]){ p.u, p.v })
	{
		int[8] t;
		int[8] l;
		if (has_top) for (usz i = 0; i < 8; i++) t[i] = plane[at - stride + i];
		if (has_left) for (usz i = 0; i < 8; i++) l[i] = plane[at + i * stride - 1];
		int q = has_corner ? plane[at - stride - 1] : 0;
		int[<3>] abc;
		if (mode == 3) abc = plane_params(&t, &l, q, 34);
		for (int k = 0; k < 4; k++)
		{
			int ox = (k & 1) * 4;
			int oy = (k >> 1) * 4;
			int dc = 128;
			if (mode == 0)
			{
				int st = t[ox] + t[ox + 1] + t[ox + 2] + t[ox + 3];
				int sl = l[oy] + l[oy + 1] + l[oy + 2] + l[oy + 3];
				// Blocks 0 and 3 average both edges; 1 prefers the top, 2 the left (8.3.4.1-3).
				if (k == 0 || k == 3)
				{
					if (has_top && has_left)
					{
						dc = (st + sl + 4) >> 3;
					}
					else if (has_left)
					{
						dc = (sl + 2) >> 2;
					}
					else if (has_top)
					{
						dc = (st + 2) >> 2;
					}
				}
				else if (ox > 0)
				{
					if (has_top)
					{
						dc = (st + 2) >> 2;
					}
					else if (has_left)
					{
						dc = (sl + 2) >> 2;
					}
				}
				else
				{
					if (has_left)
					{
						dc = (sl + 2) >> 2;
					}
					else if (has_top)
					{
						dc = (st + 2) >> 2;
					}
				}
			}
			for (int y = oy; y < oy + 4; y++)
			{
				for (int x = ox; x < ox + 4; x++)
				{
					int val;
					switch (mode)
					{
						case 0: val = dc;
						case 1: val = l[y];
						case 2: val = t[x];
						default: val = clip1((abc[0] + abc[1] * (x - 3) + abc[2] * (y - 3) + 16) >> 5);
					}
					plane[at + (usz)y * stride + (usz)x] = (char)val;
				}
			}
		}
	}
}

// Inter prediction (8.4.2.2): luma at quarter samples, chroma at eighths.
fn int tap6(int a, int b, int c, int d, int e, int f) @inline @private => a - 5 * b + 20 * c + 20 * d - 5 * e + f;

// Unrounded half sample between (x, y) and (x + 1, y).
fn int half_h(int* p, int ps, int x, int y) @inline @private
{
	int* r = p + y * ps + x;
	return tap6(r[-2], r[-1], r[0], r[1], r[2], r[3]);
}

// Between (x, y) and (x, y + 1).
fn int half_v(int* p, int ps, int x, int y) @inline @private
{
	int* r = p + y * ps + x;
	return tap6(r[-2 * ps], r[-ps], r[0], r[ps], r[2 * ps], r[3 * ps]);
}

fn int round5(int v) @inline @private => clip1((v + 16) >> 5);

fn int luma_sample(int* p, int ps, int x, int y, int fx, int fy) @private
{
	int g = p[y * ps + x];
	if (fx == 0 && fy == 0) return g;
	int b = round5(half_h(p, ps, x, y));
	int h = round5(half_v(p, ps, x, y));
	switch (fx + 4 * fy)
	{
		case 1: return (g + b + 1) >> 1;
		case 2: return b;
		case 3: return (p[y * ps + x + 1] + b + 1) >> 1;
		case 4: return (g + h + 1) >> 1;
		case 5: return (b + h + 1) >> 1;
		case 7: return (b + round5(half_v(p, ps, x + 1, y)) + 1) >> 1;
		case 8: return h;
		case 12: return (p[(y + 1) * ps + x] + h + 1) >> 1;
		case 13: return (h + round5(half_h(p, ps, x, y + 1)) + 1) >> 1;
		case 15: return (round5(half_v(p, ps, x + 1, y)) + round5(half_h(p, ps, x, y + 1)) + 1) >> 1;
		default: break;
	}
	int j1 = tap6(half_h(p, ps, x, y - 2), half_h(p, ps, x, y - 1), half_h(p, ps, x, y),
		half_h(p, ps, x, y + 1), half_h(p, ps, x, y + 2), half_h(p, ps, x, y + 3));
	int j = clip1((j1 + 512) >> 10);
	switch (fx + 4 * fy)
	{
		case 6: return (b + j + 1) >> 1;
		case 9: return (h + j + 1) >> 1;
		case 10: return j;
		case 11: return (j + round5(half_v(p, ps, x + 1, y)) + 1) >> 1;
		default: return (j + round5(half_h(p, ps, x, y + 1)) + 1) >> 1;  // 14
	}
}

<*
 The w x h partition at (x, y) in macroblock `addr` predicted from `ref`
 moved by (mx, my) quarter samples, into the current picture.

 @require w <= 16 && h <= 16 : "Partitions are at most 16x16"
*>
fn void Decoder.predict_inter(&self, uint addr, Picture* ref, int x, int y, int w, int h, int mx, int my)
{
	Picture* cur = self.cur;
	uint mbs = self.cur_sps.width_mbs;
	int px = (int)(addr % mbs) * 16 + x;
	int py = (int)(addr / mbs) * 16 + y;
	int width = (int)cur.width;
	int height = (int)cur.height;

	// The reference around the block, edges repeated: 2 samples before, 3 after.
	int[21 * 21] patch;
	int ps = w + 5;
	int ix = px + (mx >> 2) - 2;
	int iy = py + (my >> 2) - 2;
	for (int j = 0; j < h + 5; j++)
	{
		usz row = (usz)clip3(0, height - 1, iy + j) * (usz)width;
		for (int i = 0; i < ps; i++) patch[j * ps + i] = ref.y[row + (usz)clip3(0, width - 1, ix + i)];
	}
	int fx = mx & 3;
	int fy = my & 3;
	for (int j = 0; j < h; j++)
	{
		usz row = (usz)(py + j) * (usz)width + (usz)px;
		for (int i = 0; i < w; i++) cur.y[row + (usz)i] = (char)luma_sample(&patch, ps, i + 2, j + 2, fx, fy);
	}

	int cw = width / 2;
	int ch = height / 2;
	int cx = px / 2 + (mx >> 3);
	int cy = py / 2 + (my >> 3);
	int ax = mx & 7;
	int ay = my & 7;
	for (int c = 0; c < 2; c++)
	{
		char[] src = c == 0 ? ref.u : ref.v;
		char[] dst = c == 0 ? cur.u : cur.v;
		for (int j = 0; j < h / 2; j++)
		{
			usz r0 = (usz)clip3(0, ch - 1, cy + j) * (usz)cw;
			usz r1 = (usz)clip3(0, ch - 1, cy + j + 1) * (usz)cw;
			for (int i = 0; i < w / 2; i++)
			{
				usz c0 = (usz)clip3(0, cw - 1, cx + i);
				usz c1 = (usz)clip3(0, cw - 1, cx + i + 1);
				int v = (8 - ax) * (8 - ay) * src[r0 + c0] + ax * (8 - ay) * src[r0 + c1] + (8 - ax) * ay * src[r1 + c0] + ax * ay * src[r1 + c1];
				dst[(usz)(py / 2 + j) * (usz)cw + (usz)(px / 2 + i)] = (char)((v + 32) >> 6);
			}
		}
	}
}
