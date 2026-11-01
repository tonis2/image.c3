module image::h264;

// 4x4 frame scan: scan position to raster (x + 4y).
const char[16] ZIGZAG = { 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
// Luma 4x4 block index (8x8 quadrants, then 4x4 inside) to raster.
const char[16] BLK_RASTER = { 0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15 };
// coded_block_pattern from me(v) (Table 9-4, 4:2:0).
const char[48] CBP_INTRA = {
	47, 31, 15, 0, 23, 27, 29, 30, 7, 11, 13, 14, 39, 43, 45, 46, 16, 3, 5, 10, 12, 19, 21, 26, 28, 35,
	37, 42, 44, 1, 2, 4, 8, 17, 18, 20, 24, 6, 9, 22, 25, 32, 33, 34, 36, 40, 38, 41 };
const char[48] CBP_INTER = {
	0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15, 47, 7, 11, 13, 14, 6, 9, 31, 35, 37, 42, 44, 33, 34, 36, 40,
	39, 43, 45, 46, 17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41 };

// A neighbouring 4x4 block's motion for prediction (8.4.1.3).
struct Near
{
	bool avail;
	int ref;  // -1 when not there or intra
	int x;
	int y;
}

const Near NONE = { .ref = -1 };

fn void? Decoder.slice_data(&self, Slice* s)
{
	Bits* b = &s.bits;
	uint total = (uint)self.mbs.len;
	uint addr = s.first_mb;
	if (addr >= total) return CORRUPT~;
	bool more = true;
	while (more)
	{
		if (!s.intra)
		{
			uint run = b.ue();
			if (run > total - addr) return CORRUPT~;
			for (uint i = 0; i < run; i++) self.skip_mb(s, addr++);
			if (run > 0) more = b.more_data();
		}
		if (more)
		{
			if (addr >= total) return CORRUPT~;
			self.macroblock(s, addr++)!;
		}
		more = b.more_data();
		if (b.overrun()) return CORRUPT~;
		if (more && addr >= total) return CORRUPT~;
	}
}

// The neighbour macroblock at (dx, dy) from `addr` when it is in the slice; null otherwise.
fn MbInfo* Decoder.near_mb(&self, Slice* s, uint addr, int dx, int dy)
{
	int w = (int)self.cur_sps.width_mbs;
	int x = (int)addr % w + dx;
	int y = (int)addr / w + dy;
	if (x < 0 || x >= w || y < 0) return null;
	MbInfo* m = &self.mbs[y * w + x];
	return m.slice == (int)s.num ? m : null;
}

// The same, for intra prediction: an inter neighbour is out under constrained_intra_pred.
fn MbInfo* Decoder.intra_mb(&self, Slice* s, uint addr, int dx, int dy)
{
	MbInfo* m = self.near_mb(s, addr, dx, dy);
	if (m && s.pps.constrained_intra && !is_intra(m.kind)) return null;
	return m;
}

fn void? Decoder.macroblock(&self, Slice* s, uint addr)
{
	Bits* b = &s.bits;
	MbInfo* mb = &self.mbs[addr];
	*mb = { .slice = (int)s.num };
	uint t = b.ue();
	if (!s.intra)
	{
		if (t < 5) return self.inter_mb(s, addr, t);
		t -= 5;
	}
	if (t > 25) return CORRUPT~;
	mb.ref = { -1, -1, -1, -1 };
	mb.pic = { -1, -1, -1, -1 };
	if (t == 25) return self.pcm_mb(s, addr);
	if (t == 0)
	{
		mb.kind = MB_I4;
		for (uint blk = 0; blk < 16; blk++)
		{
			uint r = BLK_RASTER[blk];
			uint pred = self.predicted_mode(s, addr, r);
			uint mode = pred;
			if (!b.flag())
			{
				uint rem = b.u(3);
				mode = rem < pred ? rem : rem + 1;
			}
			mb.mode[r] = (char)mode;
		}
		uint chroma = b.ue();
		if (chroma > 3) return CORRUPT~;
		uint code = b.ue();
		if (code > 47) return CORRUPT~;
		uint cbp = CBP_INTRA[code];
		self.residual(s, addr, cbp, false)!;
		for (uint blk = 0; blk < 16; blk++)
		{
			uint r = BLK_RASTER[blk];
			self.intra4x4(s, addr, r)!;
			self.add_luma(addr, r, mb.qp, false);
		}
		self.intra_chroma(s, addr, chroma)!;
		self.add_chroma(addr, mb.qp, s);
		return;
	}
	mb.kind = MB_I16;
	foreach (&m : mb.mode) *m = 2;
	uint mode = (t - 1) % 4;
	uint cbp = ((t - 1) / 4) % 3 << 4 | (t >= 13 ? 15 : 0);
	uint chroma = b.ue();
	if (chroma > 3) return CORRUPT~;
	self.residual(s, addr, cbp, true)!;
	self.intra16x16(s, addr, mode)!;
	self.luma_dc(mb.qp);
	for (uint r = 0; r < 16; r++) self.add_luma(addr, r, mb.qp, true);
	self.intra_chroma(s, addr, chroma)!;
	self.add_chroma(addr, mb.qp, s);
}

fn void? Decoder.pcm_mb(&self, Slice* s, uint addr)
{
	Bits* b = &s.bits;
	MbInfo* mb = &self.mbs[addr];
	mb.kind = MB_PCM;
	mb.qp = 0;
	foreach (&n : mb.nz) *n = 16;
	foreach (&n : mb.nzc) *n = 16;
	foreach (&m : mb.mode) *m = 2;
	b.pos = (b.pos + 7) & ~(usz)7;
	if (b.pos / 8 + 384 > b.data.len) return CORRUPT~;
	usz at = b.pos / 8;
	Picture* p = self.cur;
	uint w = self.cur_sps.width_mbs;
	uint x = (addr % w) * 16;
	uint y = (addr / w) * 16;
	for (uint j = 0; j < 16; j++)
	{
		for (uint i = 0; i < 16; i++) p.y[(usz)(y + j) * p.width + x + i] = b.data[at++];
	}
	uint cw = p.width / 2;
	foreach (plane : (char[][]){ p.u, p.v })
	{
		for (uint j = 0; j < 8; j++)
		{
			for (uint i = 0; i < 8; i++) plane[(usz)(y / 2 + j) * cw + x / 2 + i] = b.data[at++];
		}
	}
	b.pos = at * 8;
}

// The Intra 4x4 mode block `r` is predicted to have (8.3.1.1).
fn uint Decoder.predicted_mode(&self, Slice* s, uint addr, uint r)
{
	MbInfo* mb = &self.mbs[addr];
	uint bx = r & 3;
	uint by = r >> 2;
	uint a;
	uint b;
	if (bx > 0)
	{
		a = mb.mode[r - 1];
	}
	else
	{
		MbInfo* left = self.intra_mb(s, addr, -1, 0);
		if (!left) return 2;
		a = left.kind == MB_I4 ? left.mode[r + 3] : 2;
	}
	if (by > 0)
	{
		b = mb.mode[r - 4];
	}
	else
	{
		MbInfo* above = self.intra_mb(s, addr, 0, -1);
		if (!above) return 2;
		b = above.kind == MB_I4 ? above.mode[r + 12] : 2;
	}
	return a < b ? a : b;
}

fn int Decoder.luma_nc(&self, Slice* s, uint addr, uint r)
{
	MbInfo* mb = &self.mbs[addr];
	int na = -1;
	int nb = -1;
	if (r & 3)
	{
		na = mb.nz[r - 1];
	}
	else if (MbInfo* left = self.near_mb(s, addr, -1, 0))
	{
		na = left.nz[r + 3];
	}
	if (r >= 4)
	{
		nb = mb.nz[r - 4];
	}
	else if (MbInfo* above = self.near_mb(s, addr, 0, -1))
	{
		nb = above.nz[r + 12];
	}
	if (na >= 0 && nb >= 0) return (na + nb + 1) >> 1;
	if (na >= 0) return na;
	if (nb >= 0) return nb;
	return 0;
}

fn int Decoder.chroma_nc(&self, Slice* s, uint addr, uint c, uint k)
{
	MbInfo* mb = &self.mbs[addr];
	uint base = c * 4;
	int na = -1;
	int nb = -1;
	if (k & 1)
	{
		na = mb.nzc[base + k - 1];
	}
	else if (MbInfo* left = self.near_mb(s, addr, -1, 0))
	{
		na = left.nzc[base + k + 1];
	}
	if (k >= 2)
	{
		nb = mb.nzc[base + k - 2];
	}
	else if (MbInfo* above = self.near_mb(s, addr, 0, -1))
	{
		nb = above.nzc[base + k + 2];
	}
	if (na >= 0 && nb >= 0) return (na + nb + 1) >> 1;
	if (na >= 0) return na;
	if (nb >= 0) return nb;
	return 0;
}

<*
 mb_qp_delta and the residual levels, into the scratch arrays (raster
 positions, not yet scaled); the totals into the macroblock.
*>
fn void? Decoder.residual(&self, Slice* s, uint addr, uint cbp, bool i16)
{
	Bits* b = &s.bits;
	MbInfo* mb = &self.mbs[addr];
	if (cbp > 0 || i16)
	{
		int delta = b.se();
		if (delta < -26 || delta > 25) return CORRUPT~;
		s.qp = (s.qp + delta + 52) % 52;
	}
	mb.qp = (char)s.qp;
	self.coef = {};
	self.ccoef = {};
	self.dc = {};
	int[16] scan;
	if (i16)
	{
		b.residual(self.luma_nc(s, addr, 0), 16, &scan)!;
		for (uint k = 0; k < 16; k++) self.dc[ZIGZAG[k]] = scan[k];
	}
	for (uint blk = 0; blk < 16; blk++)
	{
		uint r = BLK_RASTER[blk];
		if (!(cbp & (1 << (blk >> 2))))
		{
			mb.nz[r] = 0;
			continue;
		}
		int nc = self.luma_nc(s, addr, r);
		if (i16)
		{
			uint total = b.residual(nc, 15, &scan)!;
			for (uint k = 0; k < 15; k++) self.coef[r][ZIGZAG[k + 1]] = scan[k];
			mb.nz[r] = (char)total;
		}
		else
		{
			uint total = b.residual(nc, 16, &scan)!;
			for (uint k = 0; k < 16; k++) self.coef[r][ZIGZAG[k]] = scan[k];
			mb.nz[r] = (char)total;
		}
	}
	uint chroma = cbp >> 4;
	if (chroma > 2) return CORRUPT~;
	if (chroma & 3)
	{
		for (uint c = 0; c < 2; c++)
		{
			b.residual(-1, 4, &scan)!;
			for (uint k = 0; k < 4; k++) self.ccoef[c][k][0] = scan[k];
		}
	}
	for (uint c = 0; c < 2; c++)
	{
		for (uint k = 0; k < 4; k++)
		{
			if (chroma != 2)
			{
				mb.nzc[c * 4 + k] = 0;
				continue;
			}
			uint total = b.residual(self.chroma_nc(s, addr, c, k), 15, &scan)!;
			for (uint j = 0; j < 15; j++) self.ccoef[c][k][ZIGZAG[j + 1]] = scan[j];
			mb.nzc[c * 4 + k] = (char)total;
		}
	}
	if (b.overrun()) return CORRUPT~;
}

// ---------------------------------------------------------------------------
// Inter macroblocks.

fn void Decoder.skip_mb(&self, Slice* s, uint addr)
{
	MbInfo* mb = &self.mbs[addr];
	*mb = { .slice = (int)s.num, .kind = MB_SKIP, .qp = (char)s.qp };
	int id = (int)self.list0[0].id;
	mb.pic = { id, id, id, id };
	Near a = self.near(s, addr, 0, -1, 0);
	Near b = self.near(s, addr, 0, 0, -1);
	int mx;
	int my;
	if (a.avail && b.avail && !(a.ref == 0 && a.x == 0 && a.y == 0) && !(b.ref == 0 && b.x == 0 && b.y == 0))
	{
		self.mv_pred(s, addr, 0, 0, 0, 16, 16, 0, 0, &mx, &my);
	}
	for (uint i = 0; i < 16; i++)
	{
		mb.mv[2 * i] = (short)mx;
		mb.mv[2 * i + 1] = (short)my;
	}
	self.predict_inter(addr, self.list0[0], 0, 0, 16, 16, mx, my);
}

<*
 The motion of the 4x4 block holding luma sample (x, y) relative to the
 macroblock; inside it, only blocks in `done` are there yet.
*>
fn Near Decoder.near(&self, Slice* s, uint addr, uint done, int x, int y)
{
	MbInfo* m;
	if (x >= 0 && x < 16 && y >= 0)
	{
		if (y >= 16) return NONE;
		uint r = (uint)(x >> 2) + (uint)(y >> 2) * 4;
		if (!(done & (1u << r))) return NONE;
		m = &self.mbs[addr];
	}
	else
	{
		if (x >= 16 && y >= 0) return NONE;
		m = self.near_mb(s, addr, x < 0 ? -1 : x >= 16 ? 1 : 0, y < 0 ? -1 : 0);
		if (!m) return NONE;
		x &= 15;
		y &= 15;
	}
	if (is_intra(m.kind)) return { .avail = true, .ref = -1 };
	uint r = (uint)(x >> 2) + (uint)(y >> 2) * 4;
	return { .avail = true, .ref = m.ref[(x >> 3) + (y >> 3) * 2], .x = m.mv[2 * r], .y = m.mv[2 * r + 1] };
}

fn int median(int a, int b, int c) @private
{
	int lo = a < b ? a : b;
	int hi = a < b ? b : a;
	return c < lo ? lo : c > hi ? hi : c;
}

<*
 The predicted motion of the partition at (x, y), w x h, with `ref`; shape
 1 is 16x8, 2 is 8x16 (8.4.1.3).
*>
fn void Decoder.mv_pred(&self, Slice* s, uint addr, uint done, int x, int y, int w, int h, int ref, int shape, int* mx, int* my)
{
	Near a = self.near(s, addr, done, x - 1, y);
	Near b = self.near(s, addr, done, x, y - 1);
	Near c = self.near(s, addr, done, x + w, y - 1);
	if (!c.avail) c = self.near(s, addr, done, x - 1, y - 1);
	if (shape == 1)
	{
		Near* n = y == 0 ? &b : &a;
		if (n.ref == ref)
		{
			*mx = n.x;
			*my = n.y;
			return;
		}
	}
	else if (shape == 2)
	{
		Near* n = x == 0 ? &a : &c;
		if (n.ref == ref)
		{
			*mx = n.x;
			*my = n.y;
			return;
		}
	}
	if (!b.avail && !c.avail && a.avail)
	{
		b = a;
		c = a;
	}
	int same = (a.ref == ref ? 1 : 0) + (b.ref == ref ? 1 : 0) + (c.ref == ref ? 1 : 0);
	if (same == 1)
	{
		Near* n = a.ref == ref ? &a : b.ref == ref ? &b : &c;
		*mx = n.x;
		*my = n.y;
		return;
	}
	*mx = median(a.x, b.x, c.x);
	*my = median(a.y, b.y, c.y);
}

// A partition's motion into the macroblock, and its prediction drawn.
fn void Decoder.partition(&self, Slice* s, uint addr, uint* done, int x, int y, int w, int h, int ref, int shape, int dx, int dy)
{
	MbInfo* mb = &self.mbs[addr];
	int mx;
	int my;
	self.mv_pred(s, addr, *done, x, y, w, h, ref, shape, &mx, &my);
	mx += dx;
	my += dy;
	for (int j = y >> 2; j < (y + h) >> 2; j++)
	{
		for (int i = x >> 2; i < (x + w) >> 2; i++)
		{
			uint r = (uint)(i + j * 4);
			mb.mv[2 * r] = (short)mx;
			mb.mv[2 * r + 1] = (short)my;
			*done |= 1u << r;
		}
	}
	self.predict_inter(addr, self.list0[ref], x, y, w, h, mx, my);
}

fn void? Decoder.inter_mb(&self, Slice* s, uint addr, uint t)
{
	Bits* b = &s.bits;
	MbInfo* mb = &self.mbs[addr];
	mb.kind = MB_INTER;
	uint top = s.num_ref - 1;
	uint done;
	if (t < 3)
	{
		uint parts = t == 0 ? 1 : 2;
		int[2] ref;
		int[2][2] mvd;
		for (uint p = 0; p < parts; p++)
		{
			uint r = top > 0 ? b.te(top) : 0;
			if (r > top) return CORRUPT~;
			ref[p] = (int)r;
		}
		for (uint p = 0; p < parts; p++)
		{
			mvd[p][0] = b.se();
			mvd[p][1] = b.se();
		}
		for (uint p = 0; p < parts; p++)
		{
			int x = t == 2 ? (int)p * 8 : 0;
			int y = t == 1 ? (int)p * 8 : 0;
			int w = t == 2 ? 8 : 16;
			int h = t == 1 ? 8 : 16;
			for (int q = 0; q < 4; q++)
			{
				int qx = (q & 1) * 8;
				int qy = (q >> 1) * 8;
				if (qx >= x && qx < x + w && qy >= y && qy < y + h)
				{
					mb.ref[q] = (ichar)ref[p];
					mb.pic[q] = (int)self.list0[ref[p]].id;
				}
			}
			self.partition(s, addr, &done, x, y, w, h, ref[p], (int)t, mvd[p][0], mvd[p][1]);
		}
	}
	else
	{
		uint[4] sub;
		for (uint q = 0; q < 4; q++)
		{
			sub[q] = b.ue();
			if (sub[q] > 3) return CORRUPT~;
		}
		int[4] ref;
		for (uint q = 0; q < 4; q++)
		{
			uint r = t == 3 && top > 0 ? b.te(top) : 0;
			if (r > top) return CORRUPT~;
			ref[q] = (int)r;
		}
		int[2][4][4] mvd;
		for (uint q = 0; q < 4; q++)
		{
			uint n = sub[q] == 0 ? 1 : sub[q] == 3 ? 4 : 2;
			for (uint k = 0; k < n; k++)
			{
				mvd[q][k][0] = b.se();
				mvd[q][k][1] = b.se();
			}
		}
		for (uint q = 0; q < 4; q++)
		{
			mb.ref[q] = (ichar)ref[q];
			mb.pic[q] = (int)self.list0[ref[q]].id;
		}
		for (uint q = 0; q < 4; q++)
		{
			int ox = (int)(q & 1) * 8;
			int oy = (int)(q >> 1) * 8;
			switch (sub[q])
			{
				case 0:
					self.partition(s, addr, &done, ox, oy, 8, 8, ref[q], 0, mvd[q][0][0], mvd[q][0][1]);
				case 1:
					for (int k = 0; k < 2; k++) self.partition(s, addr, &done, ox, oy + k * 4, 8, 4, ref[q], 0, mvd[q][k][0], mvd[q][k][1]);
				case 2:
					for (int k = 0; k < 2; k++) self.partition(s, addr, &done, ox + k * 4, oy, 4, 8, ref[q], 0, mvd[q][k][0], mvd[q][k][1]);
				default:
					for (int k = 0; k < 4; k++)
					{
						self.partition(s, addr, &done, ox + (k & 1) * 4, oy + (k >> 1) * 4, 4, 4, ref[q], 0, mvd[q][k][0], mvd[q][k][1]);
					}
			}
		}
	}
	uint code = b.ue();
	if (code > 47) return CORRUPT~;
	self.residual(s, addr, CBP_INTER[code], false)!;
	for (uint r = 0; r < 16; r++) self.add_luma(addr, r, mb.qp, false);
	self.add_chroma(addr, mb.qp, s);
}
