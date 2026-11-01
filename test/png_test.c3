module image::png::test;
import image::png;
import std::io::file;

fn void check(Image img, uint width, uint height, char bit_depth, PixelFormat format)
{
	test::@check(img.width == width);
	test::@check(img.height == height);
	test::@check(img.bit_depth == bit_depth);
	test::@check(img.format == format);
	test::@check(img.pixels.len == (sz)width * height * img.bytes_per_pixel());
}

fn void test_load_rgba() @test
{
	Image img = png::load_file("test/test_rgba.png")!!;
	defer img.free();
	check(img, 2, 2, 8, RGBA);
}

fn void test_load_rgb() @test
{
	check(png::tload_file("test/test_rgb.png")!!, 4, 4, 8, RGB);
}

fn void test_load_grayscale() @test
{
	check(png::tload_file("test/test_gray.png")!!, 4, 4, 8, GRAYSCALE);
}

fn void test_load_indexed() @test
{
	// Indexed images expand to RGB.
	check(png::tload_file("test/test_indexed.png")!!, 4, 4, 8, RGB);
}

fn void test_load_grayscale_16bit() @test
{
	check(png::tload_file("test/test_gray16.png")!!, 2, 2, 16, GRAYSCALE);
}

fn void test_invalid_signature() @test
{
	test::@error(png::tload_bytes("not a png file"), png::INVALID_SIGNATURE);
}

fn void test_load_bytes() @test
{
	char[] data = file::load(tmem, "test/test_rgba.png")!!;
	check(png::tload_bytes(data)!!, 2, 2, 8, RGBA);
}
