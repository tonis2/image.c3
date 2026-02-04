module image::png::chunks;
import std::hash::crc32;

faultdef INVALID_SIGNATURE,
         INVALID_HEADER,
         UNSUPPORTED_BIT_DEPTH,
         UNSUPPORTED_INTERLACE,
         INVALID_COLOR_TYPE,
         MISSING_PALETTE,
         INVALID_CHUNK_CRC,
         INVALID_CHUNK_LENGTH,
         INCOMPLETE_DATA;

const char[8] PNG_SIGNATURE = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

// PNG color types
const char COLOR_TYPE_GRAYSCALE = 0;
const char COLOR_TYPE_RGB = 2;
const char COLOR_TYPE_INDEXED = 3;
const char COLOR_TYPE_GRAYSCALE_ALPHA = 4;
const char COLOR_TYPE_RGBA = 6;

struct Chunk {
	uint length;
	char[4] type;
	char[] data;
	uint crc;
}

struct IhdrData {
	uint width;
	uint height;
	char bit_depth;
	char color_type;
	char compression;
	char filter;
	char interlace;
}

fn uint read_u32_be(char[] data) {
	return ((uint)data[0] << 24) |
	       ((uint)data[1] << 16) |
	       ((uint)data[2] << 8) |
	       (uint)data[3];
}

fn uint read_u16_be(char[] data) {
	return ((uint)data[0] << 8) | (uint)data[1];
}

fn bool verify_signature(char[] data) {
	if (data.len < 8) return false;
	return data[:8] == PNG_SIGNATURE[..];
}

fn Chunk? parse_chunk(char[] data, usz offset) {
	if (offset + 12 > data.len) {
		return INCOMPLETE_DATA~;
	}

	uint length = read_u32_be(data[offset:4]);

	if (offset + 12 + length > data.len) {
		return INVALID_CHUNK_LENGTH~;
	}

	Chunk chunk;
	chunk.length = length;
	chunk.type[..] = data[offset+4:4];

	if (length > 0) {
		chunk.data = data[offset+8:(usz)length];
	} else {
		chunk.data = {};
	}

	chunk.crc = read_u32_be(data[offset+8+length:4]);

	// Verify CRC (computed over type + data)
	char[] crc_data = data[offset+4:4+(usz)length];
	uint computed_crc = crc32::hash(crc_data);

	if (computed_crc != chunk.crc) {
		return INVALID_CHUNK_CRC~;
	}

	return chunk;
}

fn IhdrData? parse_ihdr(Chunk* chunk) {
	if (chunk.type[..] != "IHDR") {
		return INVALID_HEADER~;
	}

	if (chunk.length != 13) {
		return INVALID_HEADER~;
	}

	IhdrData ihdr;
	ihdr.width = read_u32_be(chunk.data[0:4]);
	ihdr.height = read_u32_be(chunk.data[4:4]);
	ihdr.bit_depth = chunk.data[8];
	ihdr.color_type = chunk.data[9];
	ihdr.compression = chunk.data[10];
	ihdr.filter = chunk.data[11];
	ihdr.interlace = chunk.data[12];

	// Validate dimensions
	if (ihdr.width == 0 || ihdr.height == 0) {
		return INVALID_HEADER~;
	}

	// Only support 8 and 16 bit depths
	if (ihdr.bit_depth != 8 && ihdr.bit_depth != 16) {
		return UNSUPPORTED_BIT_DEPTH~;
	}

	// Validate color type
	if (ihdr.color_type != COLOR_TYPE_GRAYSCALE &&
	    ihdr.color_type != COLOR_TYPE_RGB &&
	    ihdr.color_type != COLOR_TYPE_INDEXED &&
	    ihdr.color_type != COLOR_TYPE_GRAYSCALE_ALPHA &&
	    ihdr.color_type != COLOR_TYPE_RGBA) {
		return INVALID_COLOR_TYPE~;
	}

	// Indexed must be 8-bit
	if (ihdr.color_type == COLOR_TYPE_INDEXED && ihdr.bit_depth != 8) {
		return UNSUPPORTED_BIT_DEPTH~;
	}

	// No interlacing support
	if (ihdr.interlace != 0) {
		return UNSUPPORTED_INTERLACE~;
	}

	return ihdr;
}

fn usz Chunk.total_size(Chunk* chunk) => 12 + (usz)chunk.length; // 4 (length) + 4 (type) + data + 4 (crc)
