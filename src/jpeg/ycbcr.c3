module image::jpeg::ycbcr;

<*
 Nearest-neighbor upsample `src` (size src_w x src_h, row stride src_stride)
 into `dst` (size dst_w x dst_h, contiguous rows of dst_w).
*>
fn void upsample_nearest(char[] src, usz src_stride, uint src_w, uint src_h,
                          char[] dst, uint dst_w, uint dst_h) {
	for (uint y = 0; y < dst_h; y++) {
		uint sy = y * src_h / dst_h;
		if (sy >= src_h) sy = src_h - 1;
		usz src_row = (usz)sy * src_stride;
		usz dst_row = (usz)y * (usz)dst_w;
		for (uint x = 0; x < dst_w; x++) {
			uint sx = x * src_w / dst_w;
			if (sx >= src_w) sx = src_w - 1;
			dst[dst_row + x] = src[src_row + sx];
		}
	}
}

fn char clamp(int x) @inline {
	if (x < 0) return 0;
	if (x > 255) return 255;
	return (char)x;
}

<*
 BT.601 full-range JFIF YCbCr -> RGB conversion using Q16 fixed point.
 Each plane is `width * height` bytes contiguous; output is row-major RGB triplets.
*>
fn void ycbcr_to_rgb(char[] y_plane, char[] cb_plane, char[] cr_plane,
                     char[] dst_rgb, uint width, uint height) {
	usz n = (usz)width * (usz)height;
	for (usz i = 0; i < n; i++) {
		int y  = (int)y_plane[i];
		int cb = (int)cb_plane[i] - 128;
		int cr = (int)cr_plane[i] - 128;

		int r = y + ((91881  * cr) >> 16);
		int g = y - ((22554  * cb + 46802 * cr) >> 16);
		int b = y + ((116130 * cb) >> 16);

		usz o = i * 3;
		dst_rgb[o + 0] = clamp(r);
		dst_rgb[o + 1] = clamp(g);
		dst_rgb[o + 2] = clamp(b);
	}
}
