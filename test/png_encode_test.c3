module image::png::test @test;
import image::png;
import std::io::file;

fn void test_encode_rgba() {
	char[16] pixels = {
		255, 0, 0, 255,    0, 255, 0, 255,
		0, 0, 255, 255,    255, 255, 0, 255,
	};
	Image img = {
		.width = 2,
		.height = 2,
		.bit_depth = 8,
		.format = RGBA,
		.pixels = pixels[..],
	};

	char[] encoded = png::save_bytes(&img)!!;
	defer alloc::free(mem, encoded);

	Image decoded = png::load_bytes(encoded)!!;
	defer decoded.free();

	assert(decoded.width == 2);
	assert(decoded.height == 2);
	assert(decoded.bit_depth == 8);
	assert(decoded.format == RGBA);
	assert(decoded.pixels.len == 16);
	for (usz i = 0; i < decoded.pixels.len; i++) {
		assert(decoded.pixels[i] == pixels[i]);
	}
}

fn void test_encode_rgb() {
	char[12] pixels = {
		255, 0, 0,    0, 255, 0,
		0, 0, 255,    255, 255, 0,
	};
	Image img = {
		.width = 2,
		.height = 2,
		.bit_depth = 8,
		.format = RGB,
		.pixels = pixels[..],
	};

	char[] encoded = png::save_bytes(&img)!!;
	defer alloc::free(mem, encoded);

	Image decoded = png::load_bytes(encoded)!!;
	defer decoded.free();

	assert(decoded.width == 2);
	assert(decoded.height == 2);
	assert(decoded.format == RGB);
	assert(decoded.pixels.len == 12);
	for (usz i = 0; i < decoded.pixels.len; i++) {
		assert(decoded.pixels[i] == pixels[i]);
	}
}

fn void test_encode_grayscale() {
	char[4] pixels = { 0, 85, 170, 255 };
	Image img = {
		.width = 2,
		.height = 2,
		.bit_depth = 8,
		.format = GRAYSCALE,
		.pixels = pixels[..],
	};

	char[] encoded = png::save_bytes(&img)!!;
	defer alloc::free(mem, encoded);

	Image decoded = png::load_bytes(encoded)!!;
	defer decoded.free();

	assert(decoded.width == 2);
	assert(decoded.height == 2);
	assert(decoded.format == GRAYSCALE);
	assert(decoded.pixels.len == 4);
	for (usz i = 0; i < decoded.pixels.len; i++) {
		assert(decoded.pixels[i] == pixels[i]);
	}
}

fn void test_encode_grayscale_alpha() {
	char[8] pixels = {
		0, 255,    85, 200,
		170, 128,  255, 0,
	};
	Image img = {
		.width = 2,
		.height = 2,
		.bit_depth = 8,
		.format = GRAYSCALE_ALPHA,
		.pixels = pixels[..],
	};

	char[] encoded = png::save_bytes(&img)!!;
	defer alloc::free(mem, encoded);

	Image decoded = png::load_bytes(encoded)!!;
	defer decoded.free();

	assert(decoded.width == 2);
	assert(decoded.height == 2);
	assert(decoded.format == GRAYSCALE_ALPHA);
	assert(decoded.pixels.len == 8);
	for (usz i = 0; i < decoded.pixels.len; i++) {
		assert(decoded.pixels[i] == pixels[i]);
	}
}

fn void test_save_file() {
	char[16] pixels = {
		255, 0, 0, 255,    0, 255, 0, 255,
		0, 0, 255, 255,    255, 255, 0, 255,
	};
	Image img = {
		.width = 2,
		.height = 2,
		.bit_depth = 8,
		.format = RGBA,
		.pixels = pixels[..],
	};

	png::save_file(&img, "/tmp/c3_test_encode.png")!!;

	Image decoded = png::load_file("/tmp/c3_test_encode.png")!!;
	defer decoded.free();

	assert(decoded.width == 2);
	assert(decoded.height == 2);
	assert(decoded.format == RGBA);
	assert(decoded.pixels.len == 16);
	for (usz i = 0; i < decoded.pixels.len; i++) {
		assert(decoded.pixels[i] == pixels[i]);
	}
}

fn void test_roundtrip_existing() {
	Image original = png::load_file("test/test_rgba.png")!!;
	defer original.free();

	char[] encoded = png::save_bytes(&original)!!;
	defer alloc::free(mem, encoded);

	Image decoded = png::load_bytes(encoded)!!;
	defer decoded.free();

	assert(decoded.width == original.width);
	assert(decoded.height == original.height);
	assert(decoded.bit_depth == original.bit_depth);
	assert(decoded.format == original.format);
	assert(decoded.pixels.len == original.pixels.len);
	for (usz i = 0; i < decoded.pixels.len; i++) {
		assert(decoded.pixels[i] == original.pixels[i]);
	}
}
