module image::h264;
import std::math;

// Deblocking filter (8.7), frames only, after the whole picture is decoded.

const char[52] ALPHA @private = {
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 5, 6, 7, 8, 9, 10, 12, 13, 15, 17, 20, 22, 25, 28,
	32, 36, 40, 45, 50, 56, 63, 71, 80, 90, 101, 113, 127, 144, 162, 182, 203, 226, 255, 255 };
const char[52] BETA @private = {
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 6, 6, 7, 7, 8, 8,
	9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18 };
const char[3][52] TC0 @private = {
	{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},
	{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},{0,0,0},
	{0,0,0},{0,0,1},{0,0,1},{0,0,1},{0,0,1},{0,1,1},{0,1,1},{1,1,1},
	{1,1,1},{1,1,1},{1,1,1},{1,1,2},{1,1,2},{1,1,2},{1,1,2},{1,2,3},
	{1,2,3},{2,2,3},{2,2,4},{2,3,4},{2,3,4},{3,3,5},{3,4,6},{3,4,6},
	{4,5,7},{4,5,8},{4,6,9},{5,7,10},{6,8,11},{6,8,13},{7,10,14},{8,11,16},
	{9,12,18},{10,13,20},{11,15,23},{13,17,25} };

// The 8x8 quadrant holding 4x4 block `r` (raster).
fn uint quadrant(uint r) @inline @private => ((r & 3) >> 1) + ((r >> 3) << 1);

// bS between 4x4 block `pr` of `p` and `qr` of `q` (rasters).
fn int strength(MbInfo* p, uint pr, MbInfo* q, uint qr, bool mb_edge) @private
{
	if (is_intra(p.kind) || is_intra(q.kind)) return mb_edge ? 4 : 3;
	if (p.nz[pr] != 0 || q.nz[qr] != 0) return 2;
	if (p.pic[quadrant(pr)] != q.pic[quadrant(qr)]) return 1;
	if (math::abs((int)p.mv[2 * pr] - q.mv[2 * qr]) >= 4 || math::abs((int)p.mv[2 * pr + 1] - q.mv[2 * qr + 1]) >= 4) return 1;
	return 0;
}

// One line of samples across an edge: `s` is q0, `step` crosses the edge.
fn void filter_line(char* s, sz step, int bs, int alpha, int beta, int index_a, bool chroma) @private
{
	int p0 = s[-step];
	int p1 = s[-2 * step];
	int q0 = s[0];
	int q1 = s[step];
	if (math::abs(p0 - q0) >= alpha || math::abs(p1 - p0) >= beta || math::abs(q1 - q0) >= beta) return;
	if (bs < 4)
	{
		// Chroma always widens tc by one and never touches p1/q1.
		int tc0 = TC0[index_a][bs - 1];
		int tc = tc0 + 1;
		int p2;
		int q2;
		bool ap;
		bool aq;
		if (!chroma)
		{
			p2 = s[-3 * step];
			q2 = s[2 * step];
			ap = math::abs(p2 - p0) < beta;
			aq = math::abs(q2 - q0) < beta;
			tc = tc0 + (ap ? 1 : 0) + (aq ? 1 : 0);
		}
		int delta = clip3(-tc, tc, (((q0 - p0) << 2) + (p1 - q1) + 4) >> 3);
		s[-step] = (char)clip1(p0 + delta);
		s[0] = (char)clip1(q0 - delta);
		if (ap) s[-2 * step] = (char)(p1 + clip3(-tc0, tc0, (p2 + ((p0 + q0 + 1) >> 1) - (p1 << 1)) >> 1));
		if (aq) s[step] = (char)(q1 + clip3(-tc0, tc0, (q2 + ((p0 + q0 + 1) >> 1) - (q1 << 1)) >> 1));
		return;
	}
	if (chroma)
	{
		s[-step] = (char)((2 * p1 + p0 + q1 + 2) >> 2);
		s[0] = (char)((2 * q1 + q0 + p1 + 2) >> 2);
		return;
	}
	int p2 = s[-3 * step];
	int q2 = s[2 * step];
	bool strong = math::abs(p0 - q0) < (alpha >> 2) + 2;
	if (strong && math::abs(p2 - p0) < beta)
	{
		int p3 = s[-4 * step];
		s[-step] = (char)((p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3);
		s[-2 * step] = (char)((p2 + p1 + p0 + q0 + 2) >> 2);
		s[-3 * step] = (char)((2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3);
	}
	else
	{
		s[-step] = (char)((2 * p1 + p0 + q1 + 2) >> 2);
	}
	if (strong && math::abs(q2 - q0) < beta)
	{
		int q3 = s[3 * step];
		s[0] = (char)((p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3);
		s[step] = (char)((p0 + q0 + q1 + q2 + 2) >> 2);
		s[2 * step] = (char)((2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) >> 3);
	}
	else
	{
		s[0] = (char)((2 * q1 + q0 + p1 + 2) >> 2);
	}
}

fn void Decoder.deblock_picture(&self)
{
	Picture* pic = self.cur;
	uint w = self.cur_sps.width_mbs;
	uint h = self.cur_sps.height_mbs;
	sz stride = (sz)pic.width;
	sz cstride = stride / 2;
	for (uint my = 0; my < h; my++)
	{
		for (uint mx = 0; mx < w; mx++)
		{
			MbInfo* q = &self.mbs[my * w + mx];
			if (q.slice < 0) continue;
			SliceInfo* info = &self.slices[(usz)q.slice];
			if (info.disable_deblock == 1) continue;
			MbInfo* left = mx > 0 ? &self.mbs[my * w + mx - 1] : null;
			MbInfo* above = my > 0 ? &self.mbs[(my - 1) * w + mx] : null;
			if (left && (left.slice < 0 || (info.disable_deblock == 2 && left.slice != q.slice))) left = null;
			if (above && (above.slice < 0 || (info.disable_deblock == 2 && above.slice != q.slice))) above = null;

			// bS per edge (0..3) and 4-sample segment; vertical edges first.
			int[4][4][2] bs;
			for (uint e = 0; e < 4; e++)
			{
				for (uint k = 0; k < 4; k++)
				{
					uint qr = e + k * 4;
					uint qh = k + e * 4;
					bs[0][e][k] = e > 0 ? strength(q, qr - 1, q, qr, false) : left ? strength(left, k * 4 + 3, q, qr, true) : 0;
					bs[1][e][k] = e > 0 ? strength(q, qh - 4, q, qh, false) : above ? strength(above, 12 + k, q, qh, true) : 0;
				}
			}
			for (uint dir = 0; dir < 2; dir++)
			{
				// Vertical edges (dir 0) are filtered across columns, horizontal ones across rows.
				sz across = dir == 0 ? 1 : stride;
				sz along = dir == 0 ? stride : 1;
				sz c_across = dir == 0 ? 1 : cstride;
				sz c_along = dir == 0 ? cstride : 1;
				for (uint e = 0; e < 4; e++)
				{
					MbInfo* p = e > 0 ? q : dir == 0 ? left : above;
					if (!p) continue;
					int qp_av = ((int)p.qp + (int)q.qp + 1) >> 1;
					int index_a = clip_qp(qp_av + info.alpha);
					int alpha = ALPHA[index_a];
					int beta = BETA[clip_qp(qp_av + info.beta)];
					char* base = pic.y.ptr + (sz)(my * 16) * stride + (sz)(mx * 16) + (sz)(e * 4) * across;
					for (uint i = 0; i < 16; i++)
					{
						int b = bs[dir][e][i >> 2];
						if (b) filter_line(base + (sz)i * along, across, b, alpha, beta, index_a, false);
					}
					// Chroma: luma edges 0 and 2 are its edges 0 and 4.
					if (e & 1) continue;
					foreach (c, plane : (char[][]){ pic.u, pic.v })
					{
						int offset = c == 0 ? info.cb_offset : info.cr_offset;
						int cav = (chroma_qp(p.qp, offset) + chroma_qp(q.qp, offset) + 1) >> 1;
						int ca = clip_qp(cav + info.alpha);
						int calpha = ALPHA[ca];
						int cbeta = BETA[clip_qp(cav + info.beta)];
						char* cbase = plane.ptr + (sz)(my * 8) * cstride + (sz)(mx * 8) + (sz)(e * 2) * c_across;
						for (uint i = 0; i < 8; i++)
						{
							int b = bs[dir][e][i >> 1];
							if (b) filter_line(cbase + (sz)i * c_along, c_across, b, calpha, cbeta, ca, true);
						}
					}
				}
			}
		}
	}
}
