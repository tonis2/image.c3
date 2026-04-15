module image;

enum PixelFormat : char {
	GRAYSCALE,
	GRAYSCALE_ALPHA,
	RGB,
	RGBA,
}

struct Image {
	uint width;
	uint height;
	char bit_depth;
	PixelFormat format;
	char[] pixels;
	Allocator allocator;
}

fn usz Image.bytes_per_pixel(&self) {
	usz channels;
	switch (self.format) {
		case GRAYSCALE: channels = 1;
		case GRAYSCALE_ALPHA: channels = 2;
		case RGB: channels = 3;
		case RGBA: channels = 4;
	}
	usz bytes_per_channel = self.bit_depth == 16 ? 2 : 1;
	return channels * bytes_per_channel;
}

fn Image Image.resize(&self, uint new_width, uint new_height, Allocator allocator = mem) {
	usz bpp = self.bytes_per_pixel();
	usz src_stride = (usz)self.width * bpp;
	usz dst_stride = (usz)new_width * bpp;
	char[] dst_pixels = alloc::new_array(allocator, char, (usz)new_width * (usz)new_height * bpp);

	for (uint y = 0; y < new_height; y++)
	{
		// Map destination y to source y (center of pixel)
		float src_yf = ((float)y + 0.5) * (float)self.height / (float)new_height - 0.5;
		if (src_yf < 0) src_yf = 0;
		uint sy0 = (uint)src_yf;
		uint sy1 = sy0 + 1;
		if (sy1 >= self.height) sy1 = self.height - 1;
		float fy = src_yf - (float)sy0;

		for (uint x = 0; x < new_width; x++)
		{
			float src_xf = ((float)x + 0.5) * (float)self.width / (float)new_width - 0.5;
			if (src_xf < 0) src_xf = 0;
			uint sx0 = (uint)src_xf;
			uint sx1 = sx0 + 1;
			if (sx1 >= self.width) sx1 = self.width - 1;
			float fx = src_xf - (float)sx0;

			usz i00 = (usz)sy0 * src_stride + (usz)sx0 * bpp;
			usz i10 = (usz)sy0 * src_stride + (usz)sx1 * bpp;
			usz i01 = (usz)sy1 * src_stride + (usz)sx0 * bpp;
			usz i11 = (usz)sy1 * src_stride + (usz)sx1 * bpp;
			usz dst_off = (usz)y * dst_stride + (usz)x * bpp;

			for (usz c = 0; c < bpp; c++)
			{
				float v00 = (float)self.pixels[i00 + c];
				float v10 = (float)self.pixels[i10 + c];
				float v01 = (float)self.pixels[i01 + c];
				float v11 = (float)self.pixels[i11 + c];
				float v = v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy)
				        + v01 * (1 - fx) * fy + v11 * fx * fy;
				if (v < 0) v = 0;
				if (v > 255) v = 255;
				dst_pixels[dst_off + c] = (char)(uint)v;
			}
		}
	}

	return {
		.width = new_width,
		.height = new_height,
		.bit_depth = self.bit_depth,
		.format = self.format,
		.pixels = dst_pixels,
		.allocator = allocator,
	};
}

fn void Image.free(&self) {
	if (self.pixels.len > 0 && self.allocator) {
		alloc::free(self.allocator, self.pixels);
		self.pixels = {};
	}
}
