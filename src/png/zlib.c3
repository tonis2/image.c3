module image::png::zlib;
import std::compression::deflate;
import std::hash::adler32;

excuse ZLIB_HEADER_INVALID,
       ZLIB_CHECKSUM_MISMATCH,
       DECOMPRESSION_FAILED,
       COMPRESSION_FAILED;

<*
 Inflate a zlib stream (RFC 1950) and verify its Adler-32 trailer.

 @return "The inflated bytes, owned by `allocator`"
 @return? ZLIB_HEADER_INVALID, DECOMPRESSION_FAILED, ZLIB_CHECKSUM_MISMATCH
*>
fn char[]? decompress(Allocator allocator, char[] data)
{
	// 2-byte header + 4-byte trailer.
	if (data.len < 6) return ZLIB_HEADER_INVALID~;
	char cmf = data[0];
	char flg = data[1];
	if ((cmf & 0x0F) != 8) return ZLIB_HEADER_INVALID~;           // not DEFLATE
	if (((uint)cmf * 256 + flg) % 31 != 0) return ZLIB_HEADER_INVALID~;
	if (flg & 0x20) return ZLIB_HEADER_INVALID~;                   // preset dictionary

	char[] decompressed = deflate::decompress(allocator, data[2..^5]) ?? DECOMPRESSION_FAILED~!;
	if (adler32::hash(decompressed) != bitorder::read(data[^4..], UIntBE))
	{
		alloc::free(allocator, decompressed);
		return ZLIB_CHECKSUM_MISMATCH~;
	}
	return decompressed;
}

<*
 Deflate `data` into a zlib stream.

 @return "The zlib stream, owned by `allocator`"
 @return? COMPRESSION_FAILED
*>
fn char[]? compress(Allocator allocator, char[] data)
{
	char[] deflated = deflate::compress(allocator, data) ?? COMPRESSION_FAILED~!;
	defer alloc::free(allocator, deflated);

	char[] result = alloc::new_array(allocator, char, 2 + deflated.len + 4);
	result[0] = 0x78;  // DEFLATE, 32K window
	result[1] = 0x01;
	result[2:deflated.len] = deflated[..];
	bitorder::write(adler32::hash(data), result[^4..], UIntBE);
	return result;
}
