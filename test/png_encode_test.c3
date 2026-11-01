module image::png::encode_test;
import image::png;
import std::io::file;
import std::hash::crc32;

const char[16] RGBA_2X2 = { 255, 0, 0, 255,  0, 255, 0, 255,  0, 0, 255, 255,  255, 255, 0, 255 };

fn void roundtrip(PixelFormat format, char[] pixels)
{
	Image img = { .width = 2, .height = 2, .bit_depth = 8, .format = format, .pixels = pixels };
	char[] encoded = png::save_bytes(&img)!!;
	defer alloc::free(mem, encoded);

	Image decoded = png::load_bytes(encoded)!!;
	defer decoded.free();
	test::@check(decoded.width == 2);
	test::@check(decoded.height == 2);
	test::@check(decoded.bit_depth == 8);
	test::@check(decoded.format == format);
	test::@check(decoded.pixels == pixels);
}

fn void test_encode_rgba() @test
{
	roundtrip(RGBA, &&RGBA_2X2);
}

fn void test_encode_rgb() @test
{
	roundtrip(RGB, &&(char[12]){ 255, 0, 0,  0, 255, 0,  0, 0, 255,  255, 255, 0 });
}

fn void test_encode_grayscale() @test
{
	roundtrip(GRAYSCALE, &&(char[4]){ 0, 85, 170, 255 });
}

fn void test_encode_grayscale_alpha() @test
{
	roundtrip(GRAYSCALE_ALPHA, &&(char[8]){ 0, 255,  85, 200,  170, 128,  255, 0 });
}

fn void test_save_file() @test
{
	const String PATH = "build/c3_test_encode.png";
	char[16] pixels = RGBA_2X2;
	Image img = { .width = 2, .height = 2, .bit_depth = 8, .format = RGBA, .pixels = &pixels };
	png::save_file(&img, PATH)!!;
	defer (void)file::delete(PATH);

	Image decoded = png::load_file(PATH)!!;
	defer decoded.free();
	test::@check(decoded.format == RGBA);
	test::@check(decoded.pixels == pixels[..]);
}

fn void test_roundtrip_existing() @test
{
	Image original = png::load_file("test/test_rgba.png")!!;
	defer original.free();
	char[] encoded = png::save_bytes(&original)!!;
	defer alloc::free(mem, encoded);

	Image decoded = png::load_bytes(encoded)!!;
	defer decoded.free();
	test::@check(decoded.width == original.width);
	test::@check(decoded.height == original.height);
	test::@check(decoded.format == original.format);
	test::@check(decoded.pixels == original.pixels);
}

fn void test_rejects_invalid_image() @test
{
	Image img = { .width = 2, .height = 2, .bit_depth = 8, .format = RGBA, .pixels = RGBA_2X2[:8] };
	test::@error(png::save_bytes(&img), png::INVALID_IMAGE_DATA);
}

// A file whose IHDR claims more rows than its IDAT holds must fail cleanly.
fn void test_truncated_idat() @test
{
	char[16] pixels = RGBA_2X2;
	Image img = { .width = 2, .height = 2, .bit_depth = 8, .format = RGBA, .pixels = &pixels };
	char[] encoded = png::save_bytes(&img)!!;
	defer alloc::free(mem, encoded);

	// IHDR data starts at byte 16; height is at 20 and the CRC follows the 13 data bytes.
	bitorder::write(3u, encoded[20:4], UIntBE);
	bitorder::write(crc32::hash(encoded[12:17]), encoded[29:4], UIntBE);
	test::@error(png::load_bytes(encoded), png::INCOMPLETE_DATA);
}
