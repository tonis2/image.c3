module image::jpeg::idct;
import std::math;

// Integer 8x8 IDCT with constants scaled by 4096, adapted from the public-domain stb_image idct_block.

const int F_054 @private = 2217;     //  0.541196100
const int F_184 @private = -7567;    // -1.847759065
const int F_076 @private = 3135;     //  0.765366865
const int F_117 @private = 4816;     //  1.175875602
const int F_029 @private = 1223;     //  0.298631336
const int F_205 @private = 8410;     //  2.053119869
const int F_307 @private = 12586;    //  3.072711026
const int F_150 @private = 6149;     //  1.501321110
const int F_089 @private = -3685;    // -0.899976223
const int F_256 @private = -10497;   // -2.562915447
const int F_196 @private = -8034;    // -1.961570560
const int F_039 @private = -1597;    // -0.390180644

// Even part (x0..x3) and odd part (t0..t3) of one 1-D pass.
struct Idct1D @private
{
	int x0, x1, x2, x3;
	int t0, t1, t2, t3;
}

fn Idct1D idct_1d(int s0, int s1, int s2, int s3, int s4, int s5, int s6, int s7) @inline @private
{
	int p1 = (s2 + s6) * F_054;
	int t2 = p1 + s6 * F_184;
	int t3 = p1 + s2 * F_076;
	int u0 = (s0 + s4) << 12;
	int u1 = (s0 - s4) << 12;

	int p3 = s7 + s3;
	int p4 = s5 + s1;
	int p5 = (p3 + p4) * F_117;
	int m1 = p5 + (s7 + s1) * F_089;
	int m2 = p5 + (s5 + s3) * F_256;
	int m3 = p3 * F_196;
	int m4 = p4 * F_039;

	return {
		u0 + t3, u1 + t2, u1 - t2, u0 - t3,
		s7 * F_029 + m1 + m3,
		s5 * F_205 + m2 + m4,
		s3 * F_307 + m2 + m3,
		s1 * F_150 + m1 + m4,
	};
}

fn char clamp(int x) @inline => (char)math::clamp(x, 0, 255);

<*
 Inverse 8x8 DCT with level shift (+128), clamped to 0..255.
 `coeffs` is in natural row-major order; writes 8 rows of 8 bytes at `dst_offset`.

 @require dst.len >= dst_offset + 7 * dst_stride + 8 : "Destination too small"
*>
fn void idct_block(int* coeffs, char[] dst, sz dst_offset, sz dst_stride)
{
	int[64] val;

	// Columns of `coeffs` into `val`.
	for (uint i = 0; i < 8; i++)
	{
		int c0 = coeffs[i +  0];
		int c1 = coeffs[i +  8];
		int c2 = coeffs[i + 16];
		int c3 = coeffs[i + 24];
		int c4 = coeffs[i + 32];
		int c5 = coeffs[i + 40];
		int c6 = coeffs[i + 48];
		int c7 = coeffs[i + 56];

		// All AC zero: the column is just the DC.
		if ((c1 | c2 | c3 | c4 | c5 | c6 | c7) == 0)
		{
			for (uint k = 0; k < 64; k += 8) val[i + k] = c0 << 2;
			continue;
		}

		Idct1D r = idct_1d(c0, c1, c2, c3, c4, c5, c6, c7);
		// Drop the 1<<12 constant scale but keep 2 extra bits of precision.
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

	// Total scale is 1<<17 (constants 12, column pass 2, 1-D normalisation 3):
	// round to nearest and add the 128 level shift in the same step.
	const int BIAS = (1 << 16) + (128 << 17);
	for (uint i = 0; i < 8; i++)
	{
		int[] row = val[i * 8:8];
		Idct1D r = idct_1d(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7]);
		int x0 = r.x0 + BIAS;
		int x1 = r.x1 + BIAS;
		int x2 = r.x2 + BIAS;
		int x3 = r.x3 + BIAS;

		char[] out = dst[dst_offset + i * dst_stride:8];
		out[0] = clamp((x0 + r.t3) >> 17);
		out[7] = clamp((x0 - r.t3) >> 17);
		out[1] = clamp((x1 + r.t2) >> 17);
		out[6] = clamp((x1 - r.t2) >> 17);
		out[2] = clamp((x2 + r.t1) >> 17);
		out[5] = clamp((x2 - r.t1) >> 17);
		out[3] = clamp((x3 + r.t0) >> 17);
		out[4] = clamp((x3 - r.t0) >> 17);
	}
}
