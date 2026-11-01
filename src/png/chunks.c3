module image::png::chunks;
import std::hash::crc32;

excuse INVALID_HEADER,
       UNSUPPORTED_BIT_DEPTH,
       UNSUPPORTED_INTERLACE,
       INVALID_COLOR_TYPE,
       INVALID_CHUNK_CRC,
       INVALID_CHUNK_LENGTH,
       INCOMPLETE_DATA;

const char[8] PNG_SIGNATURE = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

const char COLOR_TYPE_GRAYSCALE = 0;
const char COLOR_TYPE_RGB = 2;
const char COLOR_TYPE_INDEXED = 3;
const char COLOR_TYPE_GRAYSCALE_ALPHA = 4;
const char COLOR_TYPE_RGBA = 6;

struct Chunk
{
	char[4] type;
	char[] data;
}

struct IhdrData
{
	uint width;
	uint height;
	char bit_depth;
	char color_type;
	char interlace;
}

fn uint read_u32_be(char[] data) @private => bitorder::read(data[:4], UIntBE);

fn bool verify_signature(char[] data) => data.len >= 8 && data[:8] == PNG_SIGNATURE[..];

<*
 Parse the chunk starting at `offset` and verify its CRC.

 @return? INCOMPLETE_DATA, INVALID_CHUNK_LENGTH, INVALID_CHUNK_CRC
*>
fn Chunk? parse_chunk(char[] data, sz offset)
{
	if (offset + 12 > data.len) return INCOMPLETE_DATA~;
	sz length = read_u32_be(data[offset:4]);
	if (offset + 12 + length > data.len) return INVALID_CHUNK_LENGTH~;

	// The CRC covers the type and the data, not the length.
	uint crc = read_u32_be(data[offset + 8 + length:4]);
	if (crc32::hash(data[offset + 4:4 + length]) != crc) return INVALID_CHUNK_CRC~;

	Chunk chunk = { .data = data[offset + 8:length] };
	chunk.type[..] = data[offset + 4:4];
	return chunk;
}

<*
 Decode and validate an IHDR chunk.

 @param [&in] chunk : "The first chunk of the file"

 @return? INVALID_HEADER, UNSUPPORTED_BIT_DEPTH, INVALID_COLOR_TYPE, UNSUPPORTED_INTERLACE
*>
fn IhdrData? parse_ihdr(Chunk* chunk)
{
	if (chunk.type[..] != "IHDR" || chunk.data.len != 13) return INVALID_HEADER~;

	IhdrData ihdr = {
		.width = read_u32_be(chunk.data[0:4]),
		.height = read_u32_be(chunk.data[4:4]),
		.bit_depth = chunk.data[8],
		.color_type = chunk.data[9],
		.interlace = chunk.data[12],
	};

	if (ihdr.width == 0 || ihdr.height == 0) return INVALID_HEADER~;
	if (ihdr.bit_depth != 8 && ihdr.bit_depth != 16) return UNSUPPORTED_BIT_DEPTH~;
	switch (ihdr.color_type)
	{
		case COLOR_TYPE_GRAYSCALE:
		case COLOR_TYPE_RGB:
		case COLOR_TYPE_GRAYSCALE_ALPHA:
		case COLOR_TYPE_RGBA:
			break;
		case COLOR_TYPE_INDEXED:
			if (ihdr.bit_depth != 8) return UNSUPPORTED_BIT_DEPTH~;
		default:
			return INVALID_COLOR_TYPE~;
	}
	if (ihdr.interlace != 0) return UNSUPPORTED_INTERLACE~;
	return ihdr;
}

<*
 @return "Bytes the chunk occupies in the file: length, type, data and CRC"
*>
fn sz Chunk.total_size(&self) => 12 + self.data.len;
