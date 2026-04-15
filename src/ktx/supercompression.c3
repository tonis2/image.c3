module image::ktx::supercompression;
import image::ktx::header;
import std::compression::deflate;
import std::hash::adler32;

faultdef DECOMPRESSION_FAILED,
         UNSUPPORTED_SCHEME;

// Decompress level data based on supercompression scheme
fn char[]? decompress(
	char[] compressed_data,
	usz uncompressed_size,
	uint scheme,
	Allocator allocator
) {
	switch (scheme) {
		case header::SUPERCOMPRESSION_NONE:
			// No compression - just copy
			return copy_data(compressed_data, allocator);

		case header::SUPERCOMPRESSION_ZLIB:
			return decompress_zlib(compressed_data, allocator);

		case header::SUPERCOMPRESSION_BASIS_LZ:
			// Basis LZ requires Basis Universal transcoder - not supported
			return UNSUPPORTED_SCHEME~;

		case header::SUPERCOMPRESSION_ZSTD:
			// Zstd would require additional dependency - not supported
			return UNSUPPORTED_SCHEME~;

		default:
			return UNSUPPORTED_SCHEME~;
	}
}

fn char[]? copy_data(char[] data, Allocator allocator) {
	char[] copy = alloc::new_array(allocator, char, data.len);
	copy[..] = data[..];
	return copy;
}

fn char[]? decompress_zlib(char[] data, Allocator allocator) {
	// Minimum zlib stream: 2 byte header + 4 byte trailer
	if (data.len < 6) {
		return DECOMPRESSION_FAILED~;
	}

	char cmf = data[0];
	char flg = data[1];

	// Check compression method (bits 0-3 of CMF must be 8 = DEFLATE)
	if ((cmf & 0x0F) != 8) {
		return DECOMPRESSION_FAILED~;
	}

	// Check header checksum: (CMF * 256 + FLG) % 31 == 0
	uint check = (uint)cmf * 256 + (uint)flg;
	if (check % 31 != 0) {
		return DECOMPRESSION_FAILED~;
	}

	// Extract raw DEFLATE data (skip 2-byte header, exclude 4-byte Adler-32 trailer)
	char[] raw_deflate = data[2..^4];

	// Decompress using flate::inflate
	char[]? decompressed = deflate::decompress(allocator, raw_deflate)!;
	if (catch decompressed) {
		return DECOMPRESSION_FAILED~;
	}

	// Verify Adler-32 checksum
	uint stored_checksum = ((uint)data[^4] << 24) |
	                       ((uint)data[^3] << 16) |
	                       ((uint)data[^2] << 8) |
	                       (uint)data[^1];

	if (stored_checksum != adler32::hash(decompressed)) {
		alloc::free(allocator, decompressed);
		return DECOMPRESSION_FAILED~;
	}

	return decompressed;
}
