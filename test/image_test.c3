module image::test;
import image;

fn void test_to_rgba_expands_channels() @test
{
	char[4] gray_alpha = { 10, 200,  30, 40 };
	Image img = { .width = 2, .height = 1, .bit_depth = 8, .format = GRAYSCALE_ALPHA, .pixels = &gray_alpha };
	char[] rgba = img.to_rgba();
	defer alloc::free(mem, rgba);
	test::@check(rgba == (char[]){ 10, 10, 10, 200,  30, 30, 30, 40 });

	char[6] rgb = { 1, 2, 3,  4, 5, 6 };
	img = { .width = 2, .height = 1, .bit_depth = 8, .format = RGB, .pixels = &rgb };
	char[] opaque = img.to_rgba();
	defer alloc::free(mem, opaque);
	test::@check(opaque == (char[]){ 1, 2, 3, 255,  4, 5, 6, 255 });
}

fn void test_resize() @test
{
	char[4] gray = { 0, 100, 200, 255 };
	Image img = { .width = 2, .height = 2, .bit_depth = 8, .format = GRAYSCALE, .pixels = &gray };
	Image same = img.resize(2, 2);
	defer same.free();
	test::@check(same.pixels == img.pixels);

	Image one = img.resize(1, 1);
	defer one.free();
	test::@check(one.width == 1 && one.height == 1 && one.format == GRAYSCALE);
	// The centre of a 2x2 image averages all four samples.
	test::@check(one.pixels[0] == (0 + 100 + 200 + 255) / 4);
}
