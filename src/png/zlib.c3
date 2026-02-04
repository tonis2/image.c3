module image::png::zlib;
import compress::flate;

faultdef ZLIB_HEADER_INVALID,
         ZLIB_CHECKSUM_MISMATCH,
         DECOMPRESSION_FAILED;

fn uint adler32(char[] data) {
	uint a = 1;
	uint b = 0;
	const uint MOD = 65521;

	foreach (byte : data) {
		a = (a + byte) % MOD;
		b = (b + a) % MOD;
	}
	return (b << 16) | a;
}

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
	char[]? result = flate::inflate(allocator, raw_deflate);
	if (catch err = result) {
		return DECOMPRESSION_FAILED~;
	}

	char[] decompressed = result;

	// Verify Adler-32 checksum (stored big-endian in last 4 bytes)
	uint stored_checksum = ((uint)data[^4] << 24) |
	                       ((uint)data[^3] << 16) |
	                       ((uint)data[^2] << 8) |
	                       (uint)data[^1];

	uint computed_checksum = adler32(decompressed);

	if (stored_checksum != computed_checksum) {
		allocator::free(allocator, decompressed);
		return ZLIB_CHECKSUM_MISMATCH~;
	}

	return decompressed;
}
