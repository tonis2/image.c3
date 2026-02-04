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

fn void Image.free(&self) {
	if (self.pixels.len > 0 && self.allocator) {
		allocator::free(self.allocator, self.pixels);
		self.pixels = {};
	}
}
