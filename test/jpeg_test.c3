module image::jpeg::test @test;
import image::jpeg;
import std::io::file;

fn void test_load_rgb() {
	Image img = jpeg::tload_file("test/test_rgb.jpg")!!;
	assert(img.width == 4);
	assert(img.height == 4);
	assert(img.bit_depth == 8);
	assert(img.format == RGB);
	assert(img.pixels.len == 48);
}

fn void test_load_grayscale() {
	Image img = jpeg::tload_file("test/test_gray.jpg")!!;
	assert(img.width == 4);
	assert(img.height == 4);
	assert(img.bit_depth == 8);
	assert(img.format == GRAYSCALE);
	assert(img.pixels.len == 16);
}

fn void test_load_420() {
	Image img = jpeg::tload_file("test/test_rgb_420.jpg")!!;
	assert(img.width == 64);
	assert(img.height == 64);
	assert(img.bit_depth == 8);
	assert(img.format == RGB);
	assert(img.pixels.len == 64 * 64 * 3);
}

fn void test_load_with_restart() {
	Image img = jpeg::tload_file("test/test_rgb_restart.jpg")!!;
	assert(img.width == 64);
	assert(img.height == 64);
	assert(img.format == RGB);
	assert(img.pixels.len == 64 * 64 * 3);
}

fn void test_invalid_signature() {
	Image? result = jpeg::tload_bytes("not a jpeg file");
	assert(@catch(result) == jpeg::INVALID_SIGNATURE);
}

fn void test_load_bytes() {
	char[] data = file::load(tmem, "test/test_rgb.jpg")!!;
	Image img = jpeg::tload_bytes(data)!!;
	assert(img.width == 4);
	assert(img.format == RGB);
}
