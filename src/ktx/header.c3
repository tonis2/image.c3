module image::ktx::header;

// KTX2 file identifier (12 bytes)
const char[12] KTX2_IDENTIFIER = {
	0xAB, 0x4B, 0x54, 0x58, // «KTX
	0x20, 0x32, 0x30, 0xBB, //  20»
	0x0D, 0x0A, 0x1A, 0x0A  // \r\n\x1A\n
};

// Supercompression schemes
const uint SUPERCOMPRESSION_NONE = 0;
const uint SUPERCOMPRESSION_BASIS_LZ = 1;
const uint SUPERCOMPRESSION_ZSTD = 2;
const uint SUPERCOMPRESSION_ZLIB = 3;

faultdef INVALID_IDENTIFIER,
         INVALID_HEADER,
         UNSUPPORTED_SUPERCOMPRESSION,
         INVALID_LEVEL_INDEX;

// KTX2 header structure (80 bytes after identifier)
struct Header {
	uint vk_format;
	uint type_size;
	uint pixel_width;
	uint pixel_height;
	uint pixel_depth;
	uint layer_count;
	uint face_count;
	uint level_count;
	uint supercompression_scheme;
	uint dfd_byte_offset;
	uint dfd_byte_length;
	uint kvd_byte_offset;
	uint kvd_byte_length;
	ulong sgd_byte_offset;
	ulong sgd_byte_length;
}

// Level index entry (24 bytes per level)
struct LevelIndex {
	ulong byte_offset;
	ulong byte_length;
	ulong uncompressed_byte_length;
}

fn bool verify_identifier(char[] data) {
	if (data.len < 12) return false;
	for (int i = 0; i < 12; i++) {
		if (data[i] != KTX2_IDENTIFIER[i]) return false;
	}
	return true;
}

fn uint read_u32(char[] data, usz offset) {
	return ((uint)data[offset]) |
	       ((uint)data[offset + 1] << 8) |
	       ((uint)data[offset + 2] << 16) |
	       ((uint)data[offset + 3] << 24);
}

fn ulong read_u64(char[] data, usz offset) {
	return ((ulong)data[offset]) |
	       ((ulong)data[offset + 1] << 8) |
	       ((ulong)data[offset + 2] << 16) |
	       ((ulong)data[offset + 3] << 24) |
	       ((ulong)data[offset + 4] << 32) |
	       ((ulong)data[offset + 5] << 40) |
	       ((ulong)data[offset + 6] << 48) |
	       ((ulong)data[offset + 7] << 56);
}

fn Header? parse_header(char[] data) {
	// Header starts at offset 12, requires 68 bytes (80 - 12 identifier)
	if (data.len < 80) {
		return INVALID_HEADER~;
	}

	usz o = 12; // Skip identifier

	Header header = {
		.vk_format = read_u32(data, o),
		.type_size = read_u32(data, o + 4),
		.pixel_width = read_u32(data, o + 8),
		.pixel_height = read_u32(data, o + 12),
		.pixel_depth = read_u32(data, o + 16),
		.layer_count = read_u32(data, o + 20),
		.face_count = read_u32(data, o + 24),
		.level_count = read_u32(data, o + 28),
		.supercompression_scheme = read_u32(data, o + 32),
		.dfd_byte_offset = read_u32(data, o + 36),
		.dfd_byte_length = read_u32(data, o + 40),
		.kvd_byte_offset = read_u32(data, o + 44),
		.kvd_byte_length = read_u32(data, o + 48),
		.sgd_byte_offset = read_u64(data, o + 52),
		.sgd_byte_length = read_u64(data, o + 60),
	};

	// Validate basic constraints
	if (header.pixel_width == 0) {
		return INVALID_HEADER~;
	}
	if (header.level_count == 0) {
		return INVALID_HEADER~;
	}
	if (header.face_count == 0 || header.face_count > 6) {
		return INVALID_HEADER~;
	}

	return header;
}

fn LevelIndex[]? parse_level_index(char[] data, uint level_count, Allocator allocator) {
	// Level index starts immediately after the 80-byte header
	usz level_index_offset = 80;
	usz level_index_size = (usz)level_count * 24; // 24 bytes per level

	if (data.len < level_index_offset + level_index_size) {
		return INVALID_LEVEL_INDEX~;
	}

	LevelIndex[] levels = alloc::new_array(allocator, LevelIndex, level_count);

	for (uint i = 0; i < level_count; i++) {
		usz o = level_index_offset + (usz)i * 24;
		levels[i] = {
			.byte_offset = read_u64(data, o),
			.byte_length = read_u64(data, o + 8),
			.uncompressed_byte_length = read_u64(data, o + 16),
		};

		// Validate level data is within file bounds
		if (levels[i].byte_offset + levels[i].byte_length > (ulong)data.len) {
			alloc::free(allocator, levels);
			return INVALID_LEVEL_INDEX~;
		}
	}

	return levels;
}
