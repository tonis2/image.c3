module image;
import std::math;

enum PixelFormat : char
{
	GRAYSCALE,
	GRAYSCALE_ALPHA,
	RGB,
	RGBA,
}

struct Image
{
	uint width;
	uint height;
	char bit_depth;
	PixelFormat format;
	char[] pixels;
	Allocator allocator;
}

<*
 Bytes per pixel, counting every channel at the image's bit depth.
*>
fn sz Image.bytes_per_pixel(&self)
{
	sz channels;
	switch (self.format)
	{
		case GRAYSCALE: channels = 1;
		case GRAYSCALE_ALPHA: channels = 2;
		case RGB: channels = 3;
		case RGBA: channels = 4;
	}
	return self.bit_depth == 16 ? channels * 2 : channels;
}

<*
 Bilinear resize into a new image owned by `allocator`.

 @require self.bit_depth == 8 : "Only 8-bit images can be resized"
 @require self.width > 0 && self.height > 0 : "Source image is empty"
 @require new_width > 0 && new_height > 0 : "Target size must be positive"

 @return "The resized image; free it with Image.free"
*>
fn Image Image.resize(&self, uint new_width, uint new_height, Allocator allocator = mem)
{
	sz bpp = self.bytes_per_pixel();
	sz src_stride = (sz)self.width * bpp;
	sz dst_stride = (sz)new_width * bpp;
	char[] dst_pixels = alloc::new_array(allocator, char, (sz)new_width * (sz)new_height * bpp);

	for (uint y = 0; y < new_height; y++)
	{
		// Sample at pixel centres so the image doesn't shift by half a pixel.
		float src_yf = math::max(((float)y + 0.5f) * (float)self.height / (float)new_height - 0.5f, 0.0f);
		uint sy0 = (uint)src_yf;
		uint sy1 = math::min(sy0 + 1, self.height - 1);
		float fy = src_yf - (float)sy0;

		for (uint x = 0; x < new_width; x++)
		{
			float src_xf = math::max(((float)x + 0.5f) * (float)self.width / (float)new_width - 0.5f, 0.0f);
			uint sx0 = (uint)src_xf;
			uint sx1 = math::min(sx0 + 1, self.width - 1);
			float fx = src_xf - (float)sx0;

			sz i00 = (sz)sy0 * src_stride + (sz)sx0 * bpp;
			sz i10 = (sz)sy0 * src_stride + (sz)sx1 * bpp;
			sz i01 = (sz)sy1 * src_stride + (sz)sx0 * bpp;
			sz i11 = (sz)sy1 * src_stride + (sz)sx1 * bpp;
			sz dst_off = (sz)y * dst_stride + (sz)x * bpp;

			for (sz c = 0; c < bpp; c++)
			{
				float v = (float)self.pixels[i00 + c] * (1 - fx) * (1 - fy)
				        + (float)self.pixels[i10 + c] * fx * (1 - fy)
				        + (float)self.pixels[i01 + c] * (1 - fx) * fy
				        + (float)self.pixels[i11 + c] * fx * fy;
				dst_pixels[dst_off + c] = (char)math::clamp(v, 0.0f, 255.0f);
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

<*
 Expand the image to RGBA8; missing alpha becomes 0xff.

 @require self.bit_depth == 8 : "Only 8-bit images can be converted"

 @return "A new buffer owned by the caller; free with alloc::free(allocator, ...)"
*>
fn char[] Image.to_rgba(&self, Allocator allocator = mem)
{
	sz pixel_count = (sz)self.width * (sz)self.height;
	char[] result = alloc::new_array(allocator, char, pixel_count * 4);
	switch (self.format)
	{
		case RGBA:
			result[..] = self.pixels[:pixel_count * 4];
		case RGB:
			for (sz p = 0; p < pixel_count; p++)
			{
				result[p * 4 : 3] = self.pixels[p * 3 : 3];
				result[p * 4 + 3] = 0xff;
			}
		case GRAYSCALE:
			foreach (p, g : self.pixels[:pixel_count])
			{
				result[p * 4 : 3] = g;
				result[p * 4 + 3] = 0xff;
			}
		case GRAYSCALE_ALPHA:
			for (sz p = 0; p < pixel_count; p++)
			{
				result[p * 4 : 3] = self.pixels[p * 2];
				result[p * 4 + 3] = self.pixels[p * 2 + 1];
			}
	}
	return result;
}

<*
 Free the pixel buffer; safe to call twice.
*>
fn void Image.free(&self)
{
	if (self.pixels.len > 0 && self.allocator)
	{
		alloc::free(self.allocator, self.pixels);
		self.pixels = {};
	}
}
