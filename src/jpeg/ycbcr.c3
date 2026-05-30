module image::jpeg::ycbcr;
import std::math;

fn char clamp(int x) @inline => (char)math::clamp(x, 0, 255);

<*
 BT.601 full-range JFIF YCbCr -> RGB conversion using Q16 fixed point.
 Each plane is `width * height` bytes contiguous; output is row-major RGB triplets.
*>
fn void ycbcr_to_rgb(char[] y_plane, char[] cb_plane, char[] cr_plane,
                     char[] dst_rgb, uint width, uint height) {
	sz n = (sz)width * (sz)height;
	for (sz i = 0; i < n; i++) {
		int y  = (int)y_plane[i];
		int cb = (int)cb_plane[i] - 128;
		int cr = (int)cr_plane[i] - 128;

		int r = y + ((91881  * cr) >> 16);
		int g = y - ((22554  * cb + 46802 * cr) >> 16);
		int b = y + ((116130 * cb) >> 16);

		sz o = i * 3;
		dst_rgb[o + 0] = clamp(r);
		dst_rgb[o + 1] = clamp(g);
		dst_rgb[o + 2] = clamp(b);
	}
}
