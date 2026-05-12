module image::jpeg::idct;

// Integer IDCT, AAN-style "islow" reference. Constants pre-scaled by 4096.
// Adapted from the public-domain stb_image idct_block.

const int F_054 = 2217;     //  0.541196100
const int F_184 = -7567;    // -1.847759065
const int F_076 = 3135;     //  0.765366865
const int F_117 = 4816;     //  1.175875602
const int F_029 = 1223;     //  0.298631336
const int F_205 = 8410;     //  2.053119869
const int F_307 = 12586;    //  3.072711026
const int F_150 = 6149;     //  1.501321110
const int F_089 = -3685;    // -0.899976223
const int F_256 = -10497;   // -2.562915447
const int F_196 = -8034;    // -1.961570560
const int F_039 = -1597;    // -0.390180644

struct Idct1D { int x0, x1, x2, x3, t0, t1, t2, t3; }

fn Idct1D idct_1d(int s0, int s1, int s2, int s3, int s4, int s5, int s6, int s7) @inline {
	int p1 = (s2 + s6) * F_054;
	int t2 = p1 + s6 * F_184;
	int t3 = p1 + s2 * F_076;

	int u0 = (s0 + s4) << 12;
	int u1 = (s0 - s4) << 12;

	int x0 = u0 + t3;
	int x3 = u0 - t3;
	int x1 = u1 + t2;
	int x2 = u1 - t2;

	int q0 = s7;
	int q1 = s5;
	int q2 = s3;
	int q3 = s1;

	int p3 = q0 + q2;
	int p4 = q1 + q3;
	int p1b = q0 + q3;
	int p2 = q1 + q2;
	int p5 = (p3 + p4) * F_117;

	int n0 = q0 * F_029;
	int n1 = q1 * F_205;
	int n2 = q2 * F_307;
	int n3 = q3 * F_150;

	int m1 = p5 + p1b * F_089;
	int m2 = p5 + p2 * F_256;
	int m3 = p3 * F_196;
	int m4 = p4 * F_039;

	int t0 = n0 + m1 + m3;
	int t1 = n1 + m2 + m4;
	int tt2 = n2 + m2 + m3;
	int tt3 = n3 + m1 + m4;

	return { x0, x1, x2, x3, t0, t1, tt2, tt3 };
}

fn char clamp(int x) @inline {
	if (x < 0) return 0;
	if (x > 255) return 255;
	return (char)x;
}

<*
 Inverse 8x8 DCT with level shift (+128) and clamp [0,255].
 `coeffs` is in natural row-major order. Writes 8 rows of 8 bytes
 to `dst` starting at `dst_offset`, with `dst_stride` bytes per row.
*>
fn void idct_block(int* coeffs, char[] dst, sz dst_offset, sz dst_stride) {
	int[64] val;

	// Column pass: input columns of `coeffs`, output to `val`.
	for (uint i = 0; i < 8; i++) {
		int c0 = coeffs[i +  0];
		int c1 = coeffs[i +  8];
		int c2 = coeffs[i + 16];
		int c3 = coeffs[i + 24];
		int c4 = coeffs[i + 32];
		int c5 = coeffs[i + 40];
		int c6 = coeffs[i + 48];
		int c7 = coeffs[i + 56];

		// Fast path: all AC coefficients zero -> broadcast DC.
		if ((c1 | c2 | c3 | c4 | c5 | c6 | c7) == 0) {
			int dc = c0 << 2;
			val[i +  0] = dc;
			val[i +  8] = dc;
			val[i + 16] = dc;
			val[i + 24] = dc;
			val[i + 32] = dc;
			val[i + 40] = dc;
			val[i + 48] = dc;
			val[i + 56] = dc;
			continue;
		}

		Idct1D r = idct_1d(c0, c1, c2, c3, c4, c5, c6, c7);
		// Bring constants down from 1<<12, keep 2 extra bits of precision.
		int x0 = r.x0 + 512;
		int x1 = r.x1 + 512;
		int x2 = r.x2 + 512;
		int x3 = r.x3 + 512;
		val[i +  0] = (x0 + r.t3) >> 10;
		val[i + 56] = (x0 - r.t3) >> 10;
		val[i +  8] = (x1 + r.t2) >> 10;
		val[i + 48] = (x1 - r.t2) >> 10;
		val[i + 16] = (x2 + r.t1) >> 10;
		val[i + 40] = (x2 - r.t1) >> 10;
		val[i + 24] = (x3 + r.t0) >> 10;
		val[i + 32] = (x3 - r.t0) >> 10;
	}

	// Row pass: input rows of `val`, output clamped bytes to `dst`.
	for (uint i = 0; i < 8; i++) {
		sz row = (sz)i * 8;
		Idct1D r = idct_1d(val[row+0], val[row+1], val[row+2], val[row+3],
		                   val[row+4], val[row+5], val[row+6], val[row+7]);
		// Total scale: 1<<12 (constants) + 1<<2 (column pass) + sqrt(8)*sqrt(8)=8 = 1<<3 -> 1<<17.
		// Round-to-nearest (+1<<16) and add level shift 128<<17.
		int bias = 65536 + (128 << 17);
		int x0 = r.x0 + bias;
		int x1 = r.x1 + bias;
		int x2 = r.x2 + bias;
		int x3 = r.x3 + bias;

		sz o = dst_offset + i * dst_stride;
		dst[o + 0] = clamp((x0 + r.t3) >> 17);
		dst[o + 7] = clamp((x0 - r.t3) >> 17);
		dst[o + 1] = clamp((x1 + r.t2) >> 17);
		dst[o + 6] = clamp((x1 - r.t2) >> 17);
		dst[o + 2] = clamp((x2 + r.t1) >> 17);
		dst[o + 5] = clamp((x2 - r.t1) >> 17);
		dst[o + 3] = clamp((x3 + r.t0) >> 17);
		dst[o + 4] = clamp((x3 - r.t0) >> 17);
	}
}
