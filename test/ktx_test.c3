module image::ktx::test @test;
import image::ktx;
import std::io::file;

fn void test_load_rgba() {
	KtxImage img = ktx::load_file("test/test_rgba.ktx2")!!;
	defer img.free();

	assert(img.width == 2);
	assert(img.height == 2);
	assert(img.mip_levels == 1);
	assert(img.vk_format == ktx::VK_FORMAT_R8G8B8A8_UNORM);
	assert(img.faces == 1);
	assert(!img.is_supercompressed);

	MipLevel* level = img.get_level(0);
	assert(level != null);
	assert(level.width == 2);
	assert(level.height == 2);
	assert(level.data.len == 16); // 2x2x4 bytes
}

fn void test_load_grayscale() {
	KtxImage img = ktx::tload_file("test/test_gray.ktx2")!!;

	assert(img.width == 4);
	assert(img.height == 4);
	assert(img.mip_levels == 1);
	assert(img.vk_format == ktx::VK_FORMAT_R8_UNORM);

	MipLevel* level = img.get_level(0);
	assert(level != null);
	assert(level.data.len == 16); // 4x4x1 bytes
}

fn void test_load_zlib_compressed() {
	KtxImage img = ktx::tload_file("test/test_rgba_zlib.ktx2")!!;

	assert(img.width == 2);
	assert(img.height == 2);
	assert(img.vk_format == ktx::VK_FORMAT_R8G8B8A8_UNORM);
	assert(img.is_supercompressed);

	MipLevel* level = img.get_level(0);
	assert(level != null);
	assert(level.data.len == 16); // Decompressed size

	// Verify pixel data matches expected (red, green, blue, yellow)
	assert(level.data[0] == 255 && level.data[1] == 0 && level.data[2] == 0);     // Red
	assert(level.data[4] == 0 && level.data[5] == 255 && level.data[6] == 0);     // Green
	assert(level.data[8] == 0 && level.data[9] == 0 && level.data[10] == 255);    // Blue
	assert(level.data[12] == 255 && level.data[13] == 255 && level.data[14] == 0); // Yellow
}

fn void test_load_mipmaps() {
	KtxImage img = ktx::tload_file("test/test_mipmaps.ktx2")!!;

	assert(img.width == 4);
	assert(img.height == 4);
	assert(img.mip_levels == 3);

	// Level 0: 4x4
	MipLevel* level0 = img.get_level(0);
	assert(level0 != null);
	assert(level0.width == 4);
	assert(level0.height == 4);
	assert(level0.data.len == 64); // 4x4x4 bytes

	// Level 1: 2x2
	MipLevel* level1 = img.get_level(1);
	assert(level1 != null);
	assert(level1.width == 2);
	assert(level1.height == 2);
	assert(level1.data.len == 16); // 2x2x4 bytes

	// Level 2: 1x1
	MipLevel* level2 = img.get_level(2);
	assert(level2 != null);
	assert(level2.width == 1);
	assert(level2.height == 1);
	assert(level2.data.len == 4); // 1x1x4 bytes

	// Invalid level returns null
	assert(img.get_level(3) == null);
}

fn void test_invalid_signature() {
	KtxImage? result = ktx::tload_bytes("not a ktx file");
	assert(@catch(result) == ktx::INVALID_FILE);
}

fn void test_load_bytes() {
	char[] data = file::load(tmem, "test/test_rgba.ktx2")!!;
	KtxImage img = ktx::tload_bytes(data)!!;
	assert(img.width == 2);
	assert(img.height == 2);
	assert(img.vk_format == ktx::VK_FORMAT_R8G8B8A8_UNORM);
}

fn void test_is_gpu_compressed() {
	KtxImage img = ktx::tload_file("test/test_rgba.ktx2")!!;

	// R8G8B8A8 is not a GPU-compressed format
	assert(!img.is_gpu_compressed());
}
