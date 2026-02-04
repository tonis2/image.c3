module image::ktx;
import image::ktx::header;
import image::ktx::supercompression;
import std::io::file;

faultdef INVALID_FILE,
         ALLOCATION_FAILED;

// Mipmap level data
struct MipLevel {
	uint width;
	uint height;
	uint depth;
	char[] data;  // Raw or decompressed texture data
}

// KTX2 texture container
struct KtxImage {
	uint width;
	uint height;
	uint depth;
	uint layers;
	uint faces;
	uint mip_levels;
	uint vk_format;           // VkFormat enum value
	bool is_supercompressed;  // Was the data supercompressed
	MipLevel[] levels;
	Allocator allocator;
}

fn KtxImage? load_file(String path, Allocator allocator = mem) {
	char[] file_data = file::load(allocator, path)!;
	defer allocator::free(allocator, file_data);
	return load_bytes(file_data, allocator);
}

fn KtxImage? tload_file(String path) => load_file(path, tmem);

fn KtxImage? load_bytes(char[] data, Allocator allocator = mem) {
	// Verify KTX2 identifier
	if (!header::verify_identifier(data)) {
		return INVALID_FILE~;
	}

	// Parse header
	header::Header hdr = header::parse_header(data)!;

	// Parse level index
	header::LevelIndex[] level_index = header::parse_level_index(data, hdr.level_count, allocator)!;
	defer allocator::free(allocator, level_index);

	// Allocate mip levels array
	MipLevel[] levels = allocator::new_array(allocator, MipLevel, hdr.level_count);

	// Calculate dimensions for each mip level and decompress data
	uint w = hdr.pixel_width;
	uint h = hdr.pixel_height > 0 ? hdr.pixel_height : 1;
	uint d = hdr.pixel_depth > 0 ? hdr.pixel_depth : 1;

	for (uint i = 0; i < hdr.level_count; i++) {
		header::LevelIndex idx = level_index[i];

		// Extract compressed/raw data for this level
		// Note: C3 slices are inclusive on both ends, so [a..b] gives length b-a+1
		usz start = (usz)idx.byte_offset;
		usz end = start + (usz)idx.byte_length - 1;
		char[] level_data = data[start..end];

		// Decompress if needed
		char[]? decompressed = supercompression::decompress(
			level_data,
			(usz)idx.uncompressed_byte_length,
			hdr.supercompression_scheme,
			allocator
		);

		if (catch decompressed) {
			// Clean up already allocated levels
			for (uint j = 0; j < i; j++) {
				if (levels[j].data.len > 0) {
					allocator::free(allocator, levels[j].data);
				}
			}
			allocator::free(allocator, levels);
			return INVALID_FILE~;
		}

		levels[i] = {
			.width = w,
			.height = h,
			.depth = d,
			.data = decompressed,
		};

		// Calculate next mip level dimensions (halve, minimum 1)
		w = w > 1 ? w / 2 : 1;
		h = h > 1 ? h / 2 : 1;
		d = d > 1 ? d / 2 : 1;
	}

	return {
		.width = hdr.pixel_width,
		.height = hdr.pixel_height > 0 ? hdr.pixel_height : 1,
		.depth = hdr.pixel_depth > 0 ? hdr.pixel_depth : 1,
		.layers = hdr.layer_count > 0 ? hdr.layer_count : 1,
		.faces = hdr.face_count,
		.mip_levels = hdr.level_count,
		.vk_format = hdr.vk_format,
		.is_supercompressed = hdr.supercompression_scheme != header::SUPERCOMPRESSION_NONE,
		.levels = levels,
		.allocator = allocator,
	};
}

fn KtxImage? tload_bytes(char[] data) => load_bytes(data, tmem);

fn void KtxImage.free(&self) {
	if (self.allocator) {
		// Free each level's data
		foreach (&level : self.levels) {
			if (level.data.len > 0) {
				allocator::free(self.allocator, level.data);
				level.data = {};
			}
		}
		// Free the levels array
		if (self.levels.len > 0) {
			allocator::free(self.allocator, self.levels);
			self.levels = {};
		}
	}
}

// Get a specific mip level (0 = base level, largest)
fn MipLevel* KtxImage.get_level(&self, uint level) {
	if (level >= self.mip_levels) return null;
	return &self.levels[level];
}

// Check if the texture uses a GPU-compressed format (ASTC, BC, ETC2, etc.)
fn bool KtxImage.is_gpu_compressed(&self) {
	// VkFormat ranges for compressed formats:
	// BC1-BC7: 131-146
	// ETC2/EAC: 147-158
	// ASTC: 159-184
	uint f = self.vk_format;
	return (f >= 131 && f <= 184);
}

// Common VkFormat values for reference
const uint VK_FORMAT_R8G8B8A8_UNORM = 37;
const uint VK_FORMAT_R8G8B8A8_SRGB = 43;
const uint VK_FORMAT_B8G8R8A8_UNORM = 44;
const uint VK_FORMAT_B8G8R8A8_SRGB = 50;
const uint VK_FORMAT_R8G8B8_UNORM = 23;
const uint VK_FORMAT_R8G8B8_SRGB = 29;
const uint VK_FORMAT_R8_UNORM = 9;
const uint VK_FORMAT_R8G8_UNORM = 16;

// BC (Block Compression) formats
const uint VK_FORMAT_BC1_RGB_UNORM = 131;
const uint VK_FORMAT_BC1_RGBA_UNORM = 133;
const uint VK_FORMAT_BC3_UNORM = 137;
const uint VK_FORMAT_BC5_UNORM = 141;
const uint VK_FORMAT_BC7_UNORM = 145;

// ASTC formats
const uint VK_FORMAT_ASTC_4X4_UNORM = 157;
const uint VK_FORMAT_ASTC_4X4_SRGB = 158;

// ETC2 formats
const uint VK_FORMAT_ETC2_R8G8B8_UNORM = 147;
const uint VK_FORMAT_ETC2_R8G8B8A8_UNORM = 151;
