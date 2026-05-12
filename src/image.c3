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

fn sz Image.bytes_per_pixel(&self) {
	sz channels;
	switch (self.format) {
		case GRAYSCALE: channels = 1;
		case GRAYSCALE_ALPHA: channels = 2;
		case RGB: channels = 3;
		case RGBA: channels = 4;
	}
	sz bytes_per_channel = self.bit_depth == 16 ? 2 : 1;
	return channels * bytes_per_channel;
}

fn Image Image.resize(&self, uint new_width, uint new_height, Allocator allocator = mem) {
	sz bpp = self.bytes_per_pixel();
	sz src_stride = (sz)self.width * bpp;
	sz dst_stride = (sz)new_width * bpp;
	char[] dst_pixels = alloc::new_array(allocator, char, (sz)new_width * (sz)new_height * bpp);

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

			sz i00 = (sz)sy0 * src_stride + (sz)sx0 * bpp;
			sz i10 = (sz)sy0 * src_stride + (sz)sx1 * bpp;
			sz i01 = (sz)sy1 * src_stride + (sz)sx0 * bpp;
			sz i11 = (sz)sy1 * src_stride + (sz)sx1 * bpp;
			sz dst_off = (sz)y * dst_stride + (sz)x * bpp;

			for (sz c = 0; c < bpp; c++)
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

// Returns a freshly-allocated RGBA8 byte buffer for `self`. Single-channel and
// RGB inputs are expanded; alpha defaults to 0xff. The result is always a new
// allocation owned by the caller — free with `alloc::free(allocator, ...)`.
// 16-bit images are not handled here; convert to 8-bit first.
fn char[] Image.to_rgba(&self, Allocator allocator = mem) {
	sz pixel_count = (sz)self.width * (sz)self.height;
	char[] result = alloc::new_array(allocator, char, pixel_count * 4);
	switch (self.format) {
		case RGBA:
			mem::copy(result.ptr, self.pixels.ptr, pixel_count * 4);
		case RGB:
			for (sz p = 0; p < pixel_count; p++) {
				result[p * 4 + 0] = self.pixels[p * 3 + 0];
				result[p * 4 + 1] = self.pixels[p * 3 + 1];
				result[p * 4 + 2] = self.pixels[p * 3 + 2];
				result[p * 4 + 3] = (char)0xff;
			}
		case GRAYSCALE:
			for (sz p = 0; p < pixel_count; p++) {
				char g = self.pixels[p];
				result[p * 4 + 0] = g;
				result[p * 4 + 1] = g;
				result[p * 4 + 2] = g;
				result[p * 4 + 3] = (char)0xff;
			}
		case GRAYSCALE_ALPHA:
			for (sz p = 0; p < pixel_count; p++) {
				char g = self.pixels[p * 2 + 0];
				result[p * 4 + 0] = g;
				result[p * 4 + 1] = g;
				result[p * 4 + 2] = g;
				result[p * 4 + 3] = self.pixels[p * 2 + 1];
			}
	}
	return result;
}

fn void Image.free(&self) {
	if (self.pixels.len > 0 && self.allocator) {
		alloc::free(self.allocator, self.pixels);
		self.pixels = {};
	}
}
