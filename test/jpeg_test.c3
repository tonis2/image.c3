module image::jpeg::test;
import image::jpeg;
import std::io::file;
import std::math;

// Decode `jpg` and compare it to djpeg's output `ppm`, allowing ±2 per sample for IDCT rounding.
fn void matches_djpeg(String jpg, String ppm, uint width, uint height)
{
	Image img = jpeg::tload_file(jpg)!!;
	test::@check(img.width == width && img.height == height && img.format == RGB);

	// Skip the three header lines: magic, size, maxval.
	char[] ref_data = file::load(tmem, ppm)!!;
	sz i;
	for (int lines = 0; i < ref_data.len && lines < 3; i++)
	{
		if (ref_data[i] == '\n') lines++;
	}
	char[] want = ref_data[i..];
	test::@check(want.len == img.pixels.len);

	uint mismatches;
	foreach (k, got : img.pixels)
	{
		if (math::abs((int)got - (int)want[k]) > 2) mismatches++;
	}
	test::@check(mismatches == 0, "%s: %d / %d samples off by more than 2", jpg, mismatches, img.pixels.len);
}

fn void test_load_rgb() @test
{
	Image img = jpeg::tload_file("test/test_rgb.jpg")!!;
	test::@check(img.width == 4 && img.height == 4 && img.bit_depth == 8);
	test::@check(img.format == RGB && img.pixels.len == 48);
}

fn void test_load_grayscale() @test
{
	Image img = jpeg::tload_file("test/test_gray.jpg")!!;
	test::@check(img.width == 4 && img.height == 4 && img.bit_depth == 8);
	test::@check(img.format == GRAYSCALE && img.pixels.len == 16);
}

fn void test_load_bytes() @test
{
	char[] data = file::load(tmem, "test/test_rgb.jpg")!!;
	Image img = jpeg::tload_bytes(data)!!;
	test::@check(img.width == 4 && img.format == RGB);
}

fn void test_invalid_signature() @test
{
	test::@error(jpeg::tload_bytes("not a jpeg file"), jpeg::INVALID_SIGNATURE);
}

// Code lengths that overfill the code space must be rejected, not written past the lookup table.
fn void test_overfull_huffman_table() @test
{
	char[] data = file::load(tmem, "test/test_plasma.jpg")!!;
	for (sz i = 0; i + 21 < data.len; i++)
	{
		if (data[i] != 0xFF || data[i + 1] != 0xC4) continue;
		// FF C4, length, class/id, then 16 code-length counts. Turn three 3-bit codes into
		// 1-bit codes: same total, so the segment still parses, but only two 1-bit codes exist.
		char[] counts = data[i + 5:16];
		if (counts[2] < 3) continue;
		counts[2] -= 3;
		counts[0] += 3;
		break;
	}
	test::@error(jpeg::tload_bytes(data), jpeg::INVALID_HUFFMAN_TABLE);
}

fn void test_plasma_matches_djpeg() @test
{
	matches_djpeg("test/test_plasma.jpg", "test/test_plasma.ppm", 16, 16);
}

fn void test_420_matches_djpeg() @test
{
	matches_djpeg("test/test_rgb_420.jpg", "test/test_rgb_420.ppm", 64, 64);
}

fn void test_restart_matches_djpeg() @test
{
	matches_djpeg("test/test_rgb_restart.jpg", "test/test_rgb_restart.ppm", 64, 64);
}

// The last MCU ends on a restart boundary, so the marker after it is EOI, not RSTn.
fn void test_restart_on_last_mcu_matches_djpeg() @test
{
	matches_djpeg("test/test_plasma_restart.jpg", "test/test_plasma_restart.ppm", 16, 16);
}

fn void test_progressive_444_matches_djpeg() @test
{
	matches_djpeg("test/test_rgb_progressive.jpg", "test/test_rgb_progressive.ppm", 16, 16);
}

fn void test_progressive_420_matches_djpeg() @test
{
	matches_djpeg("test/test_rgb_420_progressive.jpg", "test/test_rgb_420_progressive.ppm", 64, 64);
}

fn void test_progressive_420_plasma_matches_djpeg() @test
{
	matches_djpeg("test/test_plasma_420_progressive.jpg", "test/test_plasma_420_progressive.ppm", 64, 64);
}

// Every scan ends on a restart boundary, so the marker after it is DHT or SOS.
fn void test_progressive_restart_matches_djpeg() @test
{
	matches_djpeg("test/test_plasma_progressive_restart.jpg", "test/test_plasma_progressive_restart.ppm", 16, 16);
}
