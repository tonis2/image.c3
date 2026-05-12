module image::jpeg::sanity_test @test;
import image::jpeg;
import std::io::file;
import std::io;

macro check_against_ppm($jpg, $ppm, $w, $h) {
	Image img = jpeg::tload_file($jpg)!!;
	assert(img.width == $w);
	assert(img.height == $h);
	assert(img.format == RGB);

	char[] ppm = file::load(tmem, $ppm)!!;
	int newlines = 0;
	sz i = 0;
	while (i < ppm.len && newlines < 3) {
		if (ppm[i] == '\n') newlines++;
		i++;
	}
	char[] ref_pixels = ppm[i..];

	assert(ref_pixels.len == img.pixels.len);
	uint mismatches = 0;
	for (sz k = 0; k < img.pixels.len; k++) {
		int a = (int)img.pixels[k];
		int b = (int)ref_pixels[k];
		int d = a > b ? a - b : b - a;
		if (d > 2) mismatches++;
	}
	if (mismatches > 0) io::printfn("%s mismatches > 2: %d / %d", $jpg, mismatches, img.pixels.len);
	assert(mismatches == 0);
}

fn void test_plasma_matches_djpeg() {
	check_against_ppm("test/test_plasma.jpg", "test/test_plasma.ppm", 16, 16);
}

fn void test_420_matches_djpeg() {
	check_against_ppm("test/test_rgb_420.jpg", "test/test_rgb_420.ppm", 64, 64);
}

fn void test_restart_matches_djpeg() {
	check_against_ppm("test/test_rgb_restart.jpg", "test/test_rgb_restart.ppm", 64, 64);
}
