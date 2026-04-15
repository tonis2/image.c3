module image::png::zlib;
import std::compression::deflate;
import std::hash::adler32;

faultdef ZLIB_HEADER_INVALID,
         ZLIB_CHECKSUM_MISMATCH,
         DECOMPRESSION_FAILED,
         COMPRESSION_FAILED;

fn char[]? decompress(Allocator allocator, char[] data) {
	// Minimum zlib stream: 2 byte header + 4 byte trailer
	if (data.len < 6) {
		return ZLIB_HEADER_INVALID~;
	}

	char cmf = data[0];
	char flg = data[1];

	// Check compression method (bits 0-3 of CMF must be 8 = DEFLATE)
	if ((cmf & 0x0F) != 8) {
		return ZLIB_HEADER_INVALID~;
	}

	// Check header checksum: (CMF * 256 + FLG) % 31 == 0
	uint check = (uint)cmf * 256 + (uint)flg;
	if (check % 31 != 0) {
		return ZLIB_HEADER_INVALID~;
	}

	// Check for preset dictionary (bit 5 of FLG must be 0)
	if (flg & 0x20) {
		return ZLIB_HEADER_INVALID~;
	}

	// Extract raw DEFLATE data (skip 2-byte header, exclude 4-byte Adler-32 trailer)
	char[] raw_deflate = data[2..^4];

	// Decompress using flate::inflate
	char[]? result = deflate::decompress(allocator, raw_deflate);
	if (catch err = result) {
		return DECOMPRESSION_FAILED~;
	}

	char[] decompressed = result;

	// Verify Adler-32 checksum (stored big-endian in last 4 bytes)
	uint stored_checksum = ((uint)data[^4] << 24) |
	                       ((uint)data[^3] << 16) |
	                       ((uint)data[^2] << 8) |
	                       (uint)data[^1];

	uint computed_checksum = adler32::hash(decompressed);

	if (stored_checksum != computed_checksum) {
		alloc::free(allocator, decompressed);
		return ZLIB_CHECKSUM_MISMATCH~;
	}

	return decompressed;
}

fn char[]? compress(Allocator allocator, char[] data) {
	char[]? compressed = deflate::compress(allocator, data);
	if (catch err = compressed) {
		return COMPRESSION_FAILED~;
	}
	char[] deflated = compressed;

	// Compute Adler-32 checksum of uncompressed data
	uint checksum = adler32::hash(data);

	// Assemble: 2-byte header + DEFLATE data + 4-byte Adler-32
	usz total = 2 + deflated.len + 4;
	char[] result = alloc::new_array(allocator, char, total);

	// ZLIB header: CMF=0x78 (DEFLATE, 32K window), FLG=0x01
	result[0] = 0x78;
	result[1] = 0x01;

	// Copy DEFLATE data
	for (usz i = 0; i < deflated.len; i++) {
		result[2 + i] = deflated[i];
	}

	// Adler-32 checksum (big-endian)
	result[total - 4] = (char)(checksum >> 24);
	result[total - 3] = (char)(checksum >> 16);
	result[total - 2] = (char)(checksum >> 8);
	result[total - 1] = (char)(checksum);

	alloc::free(allocator, deflated);

	return result;
}
