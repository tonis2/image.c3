module image::png::test @test;
import image::png;
import std::io::file;

fn void test_load_rgba() {
	Image img = png::load_file("test/test_rgba.png")!!;
	defer img.free();
	
	assert(img.width == 2);
	assert(img.height == 2);
	assert(img.bit_depth == 8);
	assert(img.format == RGBA);
	assert(img.pixels.len == 16); // 2x2x4 bytes
}

fn void test_load_rgb() {
	Image img = png::tload_file("test/test_rgb.png")!!;
	assert(img.width == 4);
	assert(img.height == 4);
	assert(img.bit_depth == 8);
	assert(img.format == RGB);
	assert(img.pixels.len == 48); // 4x4x3 bytes
}

fn void test_load_grayscale() {
	Image img = png::tload_file("test/test_gray.png")!!;
	assert(img.width == 4);
	assert(img.height == 4);
	assert(img.bit_depth == 8);
	assert(img.format == GRAYSCALE);
	assert(img.pixels.len == 16); // 4x4x1 bytes
}

fn void test_load_indexed() {
	Image img = png::tload_file("test/test_indexed.png")!!;
	assert(img.width == 4);
	assert(img.height == 4);
	assert(img.bit_depth == 8);
	assert(img.format == RGB); // Indexed expands to RGB
	assert(img.pixels.len == 48); // 4x4x3 bytes
}

fn void test_load_grayscale_16bit() {
	Image img = png::tload_file("test/test_gray16.png")!!;
	assert(img.width == 2);
	assert(img.height == 2);
	assert(img.bit_depth == 16);
	assert(img.format == GRAYSCALE);
	assert(img.pixels.len == 8); // 2x2x2 bytes
}

fn void test_invalid_signature() {
	Image? result = png::tload_bytes("not a png file");
	assert(@catch(result) == png::INVALID_SIGNATURE);
}

fn void test_load_bytes() {
	char[] data = file::load(tmem, "test/test_rgba.png")!!;
	Image img = png::tload_bytes(data)!!;
	assert(img.width == 2);
	assert(img.height == 2);
	assert(img.format == RGBA);
}
