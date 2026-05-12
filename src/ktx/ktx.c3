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
	defer alloc::free(allocator, file_data);
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
	defer alloc::free(allocator, level_index);

	// Allocate mip levels array
	MipLevel[] levels = alloc::new_array(allocator, MipLevel, hdr.level_count);

	// Calculate dimensions for each mip level and decompress data
	uint w = hdr.pixel_width;
	uint h = hdr.pixel_height > 0 ? hdr.pixel_height : 1;
	uint d = hdr.pixel_depth > 0 ? hdr.pixel_depth : 1;

	for (uint i = 0; i < hdr.level_count; i++) {
		header::LevelIndex idx = level_index[i];

		// Extract compressed/raw data for this level
		// Note: C3 slices are inclusive on both ends, so [a..b] gives length b-a+1
		sz start = (sz)idx.byte_offset;
		sz end = start + (sz)idx.byte_length - 1;
		char[] level_data = data[start..end];

		// Decompress if needed
		char[]? decompressed = supercompression::decompress(
			level_data,
			(sz)idx.uncompressed_byte_length,
			hdr.supercompression_scheme,
			allocator
		);

		if (catch decompressed) {
			// Clean up already allocated levels
			for (uint j = 0; j < i; j++) {
				if (levels[j].data.len > 0) {
					alloc::free(allocator, levels[j].data);
				}
			}
			alloc::free(allocator, levels);
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
				alloc::free(self.allocator, level.data);
				level.data = {};
			}
		}
		// Free the levels array
		if (self.levels.len > 0) {
			alloc::free(self.allocator, self.levels);
			self.levels = {};
		}
	}
}

// Get a specific mip level (0 = base level, largest)
fn MipLevel* KtxImage.get_level(&self, uint level) {
	if (level >= self.mip_levels) return null;
	return &self.levels[level];
}

// Compression family enum
enum CompressionType : char {
	NONE,        // Uncompressed (R8, RG8, RGB8, RGBA8, etc.)
	BC,          // BC1-BC7 (Desktop GPUs)
	ETC2,        // ETC2/EAC (Android, OpenGL ES 3.0+)
	ASTC,        // ASTC (Modern mobile, Apple Silicon)
}

// Check if the texture uses a GPU-compressed format (ASTC, BC, ETC2, etc.)
fn bool KtxImage.is_gpu_compressed(&self) {
	return self.compression_type() != CompressionType.NONE;
}

// Get the compression family
fn CompressionType KtxImage.compression_type(&self) {
	return get_compression_type(self.vk_format);
}

// Get block dimensions for compressed formats (returns 1x1 for uncompressed)
fn uint[<2>] KtxImage.block_dimensions(&self) {
	return get_block_dimensions(self.vk_format);
}

// Get bytes per block (or per pixel for uncompressed)
fn uint KtxImage.block_size(&self) {
	return get_block_size(self.vk_format);
}

// Calculate expected data size for a mip level
fn sz KtxImage.calculate_level_size(&self, uint level) {
	if (level >= self.mip_levels) return 0;
	MipLevel* mip = &self.levels[level];
	return calculate_image_size(self.vk_format, mip.width, mip.height);
}

// Get compression type from VkFormat
fn CompressionType get_compression_type(uint vk_format) {
	if (vk_format >= 131 && vk_format <= 146) return CompressionType.BC;
	if (vk_format >= 147 && vk_format <= 158) return CompressionType.ETC2;
	if (vk_format >= 159 && vk_format <= 184) return CompressionType.ASTC;
	return CompressionType.NONE;
}

// Get block dimensions for a VkFormat
fn uint[<2>] get_block_dimensions(uint vk_format) {
	// BC formats: 4x4 blocks
	if (vk_format >= 131 && vk_format <= 146) return { 4, 4 };

	// ETC2/EAC formats: 4x4 blocks
	if (vk_format >= 147 && vk_format <= 158) return { 4, 4 };

	// ASTC formats: variable block sizes
	if (vk_format >= 159 && vk_format <= 184) {
		return get_astc_block_dimensions(vk_format);
	}

	// Uncompressed: 1x1
	return { 1, 1 };
}

// Get ASTC block dimensions from VkFormat
fn uint[<2>] get_astc_block_dimensions(uint vk_format) {
	// ASTC formats come in pairs (UNORM, SRGB)
	// VK_FORMAT_ASTC_4x4_UNORM = 157, VK_FORMAT_ASTC_4x4_SRGB = 158, etc.
	uint base = (vk_format - 157) / 2;
	switch (base) {
		case 0: return { 4, 4 };
		case 1: return { 5, 4 };
		case 2: return { 5, 5 };
		case 3: return { 6, 5 };
		case 4: return { 6, 6 };
		case 5: return { 8, 5 };
		case 6: return { 8, 6 };
		case 7: return { 8, 8 };
		case 8: return { 10, 5 };
		case 9: return { 10, 6 };
		case 10: return { 10, 8 };
		case 11: return { 10, 10 };
		case 12: return { 12, 10 };
		case 13: return { 12, 12 };
		default: return { 4, 4 };
	}
}

// Get bytes per block for a VkFormat
fn uint get_block_size(uint vk_format) {
	// BC formats
	if (vk_format >= 131 && vk_format <= 146) {
		// BC1/BC4: 8 bytes per block
		// BC2/BC3/BC5/BC6H/BC7: 16 bytes per block
		switch (vk_format) {
			case 131: return 8;  // BC1_RGB_UNORM
			case 132: return 8;  // BC1_RGB_SRGB
			case 133: return 8;  // BC1_RGBA_UNORM
			case 134: return 8;  // BC1_RGBA_SRGB
			case 139: return 8;  // BC4_UNORM
			case 140: return 8;  // BC4_SNORM
			default: return 16;  // BC2, BC3, BC5, BC6H, BC7
		}
	}

	// ETC2/EAC formats
	if (vk_format >= 147 && vk_format <= 158) {
		switch (vk_format) {
			case 147: return 8;  // ETC2_R8G8B8_UNORM
			case 148: return 8;  // ETC2_R8G8B8_SRGB
			case 149: return 8;  // ETC2_R8G8B8A1_UNORM
			case 150: return 8;  // ETC2_R8G8B8A1_SRGB
			case 153: return 8;  // EAC_R11_UNORM
			case 154: return 8;  // EAC_R11_SNORM
			default: return 16;  // ETC2_R8G8B8A8, EAC_R11G11
		}
	}

	// ASTC formats: all 16 bytes per block
	if (vk_format >= 159 && vk_format <= 184) return 16;

	// Uncompressed formats
	switch (vk_format) {
		case 9: return 1;   // R8_UNORM
		case 16: return 2;  // R8G8_UNORM
		case 23: return 3;  // R8G8B8_UNORM
		case 29: return 3;  // R8G8B8_SRGB
		case 37: return 4;  // R8G8B8A8_UNORM
		case 43: return 4;  // R8G8B8A8_SRGB
		case 44: return 4;  // B8G8R8A8_UNORM
		case 50: return 4;  // B8G8R8A8_SRGB
		default: return 4;  // Assume 4 bytes
	}
}

// Calculate image data size in bytes
fn sz calculate_image_size(uint vk_format, uint width, uint height) {
	uint[<2>] block_dim = get_block_dimensions(vk_format);
	uint block_size = get_block_size(vk_format);

	// Round up to block boundaries
	uint blocks_x = (width + block_dim[0] - 1) / block_dim[0];
	uint blocks_y = (height + block_dim[1] - 1) / block_dim[1];

	return (sz)blocks_x * (sz)blocks_y * (sz)block_size;
}

// ============================================================================
// VkFormat constants
// ============================================================================

// Uncompressed formats
const uint VK_FORMAT_R8_UNORM = 9;
const uint VK_FORMAT_R8G8_UNORM = 16;
const uint VK_FORMAT_R8G8B8_UNORM = 23;
const uint VK_FORMAT_R8G8B8_SRGB = 29;
const uint VK_FORMAT_R8G8B8A8_UNORM = 37;
const uint VK_FORMAT_R8G8B8A8_SRGB = 43;
const uint VK_FORMAT_B8G8R8A8_UNORM = 44;
const uint VK_FORMAT_B8G8R8A8_SRGB = 50;

// BC (Block Compression) formats - Desktop GPUs
const uint VK_FORMAT_BC1_RGB_UNORM = 131;
const uint VK_FORMAT_BC1_RGB_SRGB = 132;
const uint VK_FORMAT_BC1_RGBA_UNORM = 133;
const uint VK_FORMAT_BC1_RGBA_SRGB = 134;
const uint VK_FORMAT_BC2_UNORM = 135;
const uint VK_FORMAT_BC2_SRGB = 136;
const uint VK_FORMAT_BC3_UNORM = 137;
const uint VK_FORMAT_BC3_SRGB = 138;
const uint VK_FORMAT_BC4_UNORM = 139;
const uint VK_FORMAT_BC4_SNORM = 140;
const uint VK_FORMAT_BC5_UNORM = 141;
const uint VK_FORMAT_BC5_SNORM = 142;
const uint VK_FORMAT_BC6H_UFLOAT = 143;
const uint VK_FORMAT_BC6H_SFLOAT = 144;
const uint VK_FORMAT_BC7_UNORM = 145;
const uint VK_FORMAT_BC7_SRGB = 146;

// ETC2/EAC formats - Android, OpenGL ES 3.0+
const uint VK_FORMAT_ETC2_R8G8B8_UNORM = 147;
const uint VK_FORMAT_ETC2_R8G8B8_SRGB = 148;
const uint VK_FORMAT_ETC2_R8G8B8A1_UNORM = 149;
const uint VK_FORMAT_ETC2_R8G8B8A1_SRGB = 150;
const uint VK_FORMAT_ETC2_R8G8B8A8_UNORM = 151;
const uint VK_FORMAT_ETC2_R8G8B8A8_SRGB = 152;
const uint VK_FORMAT_EAC_R11_UNORM = 153;
const uint VK_FORMAT_EAC_R11_SNORM = 154;
const uint VK_FORMAT_EAC_R11G11_UNORM = 155;
const uint VK_FORMAT_EAC_R11G11_SNORM = 156;

// ASTC formats - Modern mobile, Apple Silicon
const uint VK_FORMAT_ASTC_4X4_UNORM = 157;
const uint VK_FORMAT_ASTC_4X4_SRGB = 158;
const uint VK_FORMAT_ASTC_5X4_UNORM = 159;
const uint VK_FORMAT_ASTC_5X4_SRGB = 160;
const uint VK_FORMAT_ASTC_5X5_UNORM = 161;
const uint VK_FORMAT_ASTC_5X5_SRGB = 162;
const uint VK_FORMAT_ASTC_6X5_UNORM = 163;
const uint VK_FORMAT_ASTC_6X5_SRGB = 164;
const uint VK_FORMAT_ASTC_6X6_UNORM = 165;
const uint VK_FORMAT_ASTC_6X6_SRGB = 166;
const uint VK_FORMAT_ASTC_8X5_UNORM = 167;
const uint VK_FORMAT_ASTC_8X5_SRGB = 168;
const uint VK_FORMAT_ASTC_8X6_UNORM = 169;
const uint VK_FORMAT_ASTC_8X6_SRGB = 170;
const uint VK_FORMAT_ASTC_8X8_UNORM = 171;
const uint VK_FORMAT_ASTC_8X8_SRGB = 172;
const uint VK_FORMAT_ASTC_10X5_UNORM = 173;
const uint VK_FORMAT_ASTC_10X5_SRGB = 174;
const uint VK_FORMAT_ASTC_10X6_UNORM = 175;
const uint VK_FORMAT_ASTC_10X6_SRGB = 176;
const uint VK_FORMAT_ASTC_10X8_UNORM = 177;
const uint VK_FORMAT_ASTC_10X8_SRGB = 178;
const uint VK_FORMAT_ASTC_10X10_UNORM = 179;
const uint VK_FORMAT_ASTC_10X10_SRGB = 180;
const uint VK_FORMAT_ASTC_12X10_UNORM = 181;
const uint VK_FORMAT_ASTC_12X10_SRGB = 182;
const uint VK_FORMAT_ASTC_12X12_UNORM = 183;
const uint VK_FORMAT_ASTC_12X12_SRGB = 184;
