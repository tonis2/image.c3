module image::h264;
import image;

<*
 The picture's shown area as 8-bit RGB: BT.709 when the stream says so, else
 BT.601; limited range unless flagged full. Chroma is nearest-sample.
*>
fn Image Picture.to_image(&self, Allocator allocator = mem)
{
	uint w = self.shown_width();
	uint h = self.shown_height();
	char[] out = alloc::new_array(allocator, char, (usz)w * h * 3);
	bool bt709 = self.matrix == 1;
	// 16.16 fixed point: luma gain, then V→R, U→G, V→G, U→B.
	int ky;
	int vr;
	int ug;
	int vg;
	int ub;
	if (self.full_range)
	{
		ky = 65536;
		vr = bt709 ? 103206 : 91881;
		ug = bt709 ? 12276 : 22554;
		vg = bt709 ? 30679 : 46802;
		ub = bt709 ? 121609 : 116130;
	}
	else
	{
		ky = 76309;
		vr = bt709 ? 117489 : 104597;
		ug = bt709 ? 13975 : 25675;
		vg = bt709 ? 34925 : 53279;
		ub = bt709 ? 138438 : 132201;
	}
	int y_base = self.full_range ? 0 : 16;
	usz cw = self.width / 2;
	usz at;
	for (uint j = 0; j < h; j++)
	{
		usz sy = (usz)(j + self.crop_top);
		for (uint i = 0; i < w; i++)
		{
			usz sx = (usz)(i + self.crop_left);
			int yv = ((int)self.y[sy * self.width + sx] - y_base) * ky + 32768;
			usz c = (sy >> 1) * cw + (sx >> 1);
			int u = (int)self.u[c] - 128;
			int v = (int)self.v[c] - 128;
			out[at++] = (char)clip1((yv + vr * v) >> 16);
			out[at++] = (char)clip1((yv - ug * u - vg * v) >> 16);
			out[at++] = (char)clip1((yv + ub * u) >> 16);
		}
	}
	return { .width = w, .height = h, .bit_depth = 8, .format = RGB, .pixels = out, .allocator = allocator };
}
