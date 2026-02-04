// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
<*
 This module implements the DEFLATE compression and decompression algorithm
 specified in RFC 1951.

 For normal use, call compress()/uncompress(); deflate()/inflate() are
 lower-level entry points with more control over block handling.
*>
module compress::flate;
import std::io;

<*
 Compresses the given input using the DEFLATE format (RFC 1951).  compress
 selects an appropriate block strategy (stored vs. compressed) based on the
 input and returns a single DEFLATE stream. The caller owns the returned buffer
 and must free it using the same allocator.
*>
fn char[]? compress(Allocator allocator, char[] bytes) @inline
{
	if (bytes.len < 32)
	{
		return deflate(allocator, bytes, &encode_stored_block);
	}
	return deflate(allocator, bytes, &encode_dynamic_block);
}

<*
 Convenience wrapper around compress() using the temporary allocator.
*>
fn char[]? tcompress(char[] bytes) @inline => compress(tmem, bytes);

<*
 Decompresses a complete DEFLATE stream into a newly allocated buffer.

 uncompress() validates block headers and reconstructs the original
 uncompressed data. The caller owns the returned buffer and must free it using
 the same allocator.
*>
fn char[]? uncompress(Allocator allocator, char[] bytes) @inline => inflate(allocator, bytes);

<*
 Convenience wrapper around uncompress() using the temporary allocator.
*>
fn char[]? tuncompress(char[] bytes) @inline => inflate(tmem, bytes);

const MAX_BLOCK_SIZE = 65_535;

<*
 Callback type for the DEFLATE block compressors.

 Implementations receive an initialized FlateCompressor and a contiguous
 slice of the input. They may emit one or more DEFLATE blocks and must set
 the BFINAL flag on the last block they emit when is_last_chunk is true.
*>
alias DeflateBlockFn = fn void?(FlateCompressor *c, char[] input_chunk, bool is_last_chunk);

<*
 deflate() compresses the input data with a pluggable block strategy.

 The input is processed in one or more chunks. For each chunk, this function
 calls the user-supplied block_fn, which is responsible for:
   - performing LZ77 tokenization as needed,
   - emitting a DEFLATE block into the FlateCompressor, and
   - ensuring the final block it emits has BFINAL = 1 when is_last_chunk
     is true.

 The FlateCompressor instance is initialized once and reused across all
 chunks so that a continuous LZ77 history window and streaming use cases
 can be supported. The compressed bitstream is accumulated and flushed
 into a newly allocated buffer, which is returned to the caller.

 max_block_len is an upper bound on the number of input bytes passed to a
 single block_fn call; block_fn is free to emit multiple DEFLATE blocks for its
 chunk if desired. Currently, the block lengths are set to a fixed length. In
 theory, the block lengths should be dynamically determined depending on
 changes in the underyling alphabets for best compression results.

 @param [&inout] allocator : "Allocator for compressed data."
 @param [in] bytes         : "Input data to be compressed."
 @param block_fn           : "Callback invoked for each logical input block."
 @param max_block_len      : "Maximum number of input bytes to pass to block_fn`."

 @return "A newly allocated char[] containing the complete DEFLATE stream."
*>
fn char[]? deflate(Allocator allocator, char[] bytes, DeflateBlockFn block_fn = &dynamic_block,
	usz max_block_len = MAX_BLOCK_SIZE) => @pool()
{
	ByteWriter out;
	out.init(allocator);

	FlateCompressor comp;
	comp.init(&out);

	usz offset = 0;
	while (offset < bytes.len)
	{
		usz remaining = bytes.len - offset;
		usz chunk_len = remaining > max_block_len ? max_block_len : remaining;
		bool is_last = (offset + chunk_len) >= bytes.len;

		block_fn(&comp, bytes[offset:chunk_len], is_last)!;
		offset += chunk_len;
	}

	comp.flush_bits()!;
	return out.array_view();
}

faultdef INVALID_BLOCK_TYPE;

<*
 Parses a complete DEFLATE stream, handling stored, fixed Huffman, and
 dynamic Huffman blocks. Blocks are processed sequentially until a block
 with BFINAL = 1 is encountered or an error is detected. On success, the
 function returns a newly allocated buffer containing all uncompressed
 bytes.

 @param [&inout] allocator : "Allocator for uncompressed data."
 @param [in] bytes         : "Input data to be compressed."
 @return? INVALID_BLOCK_TYPE
*>
fn char[]? inflate(Allocator allocator, char[] bytes)
{
	ByteReader byte_reader;
	byte_reader.init(bytes);

	ByteWriter byte_writer;
	byte_writer.init(allocator);

	FlateDecompressor decomp;
	decomp.init(&byte_reader, &byte_writer);

	uint bfinal, btype;
	do
	{
		bfinal = decomp.getbits(1)!;
		btype  = decomp.getbits(2)!;

		switch(btype)
		{
			case 0: decomp.decode_stored_block()!;
			case 1: decomp.decode_fixed_block()!;
			case 2: decomp.decode_dynamic_block()!;
			default: return INVALID_BLOCK_TYPE~;
		}
	} while (!bfinal);
	return byte_writer.array_view();
}


<*
 Emits a stored (uncompressed) DEFLATE block for the given input.

 The function writes a block header with BTYPE=00, aligns to the next
 byte boundary as required by RFC 1951, then outputs LEN, NLEN and the
 raw input bytes. If is_last_chunk is true, the block’s BFINAL bit is set.
*>
fn void? encode_stored_block(FlateCompressor *c, char[] chunk, bool is_last_chunk)
{
	uint n = (uint)chunk.len;

	// BFINAL (1 bit), BTYPE=00 (2bits)
	c.write_block_header(is_last_chunk ? 1 : 0, 0b00)!;

	// Align to next byte boundary before LEN/NLEN.
	c.flush_bits()!;

	// Set block length.
	c.putbits(n, 16)!;
	c.putbits(~n, 16)!;

	// Write uncompressed bytes.
	for (usz i = 0; i < n; i++)
	{
		c.putbits(chunk[i], 8)!;
	}
}

<*
 Emits a DEFLATE block using the fixed Huffman code trees.

 The function tokenizes the input with LZ77, uses the fixed literal/length
 and distance trees defined by RFC 1951, writes the fixed-block header,
 and then encodes all tokens plus an end-of-block symbol. If is_last_chunk
 is true, the last block written by this function sets BFINAL = 1.
*>
fn void? encode_fixed_block(FlateCompressor *c, char[] chunk, bool is_last_chunk) => @pool()
{
	LzToken[] tokens = lz77::tokenize(tmem, chunk);
	c.build_fixed_trees()!;
	c.write_block_header(is_last_chunk ? 1 : 0, 0b01)!;
	c.write_compressed_data(tokens)!;
	c.write_end_of_block()!;
}

<*
 Emits a DEFLATE blocks using dynamic Huffman coding.

 The function tokenizes the input with LZ77, builds dynamic Huffman trees
 from the token statistics, writes the dynamic Huffman header, and then
 encodes all tokens plus an end-of-block symbol. If is_last_chunk is true,
 the last block written by this function sets BFINAL = 1.
*>
fn void? encode_dynamic_block(FlateCompressor *c, char[] chunk, bool is_last_chunk) => @pool()
{
	LzToken[] tokens = lz77::tokenize(tmem, chunk);
	c.build_trees(tokens)!;
	c.write_dynamic_header(is_last_chunk)!;
	c.write_compressed_data(tokens)!;
	c.write_end_of_block()!;
}

module compress::deflate::test @test;
import compress::flate;

import std;
fn void test_deflate_dynamic() => @pool()
{
	char[] bytes = "hello world world hello";
	char[] comp = flate::deflate(tmem, bytes, &flate::encode_dynamic_block)!!;
	char[] want = x`2de8b1090000080341ace2700a160f011bd70f88cd15d7058ad590ef8d01`;
	assert(comp == want);

	char[] inflate = flate::inflate(tmem, comp)!!;
	assert(inflate == bytes, "got: '%s', want '%s'", (String)inflate, (String)bytes);
}

fn void test_flate_fixed() => @pool()
{
	char[] bytes = "hello world world hello";
	char[] fixed = flate::deflate(tmem, bytes, &flate::encode_fixed_block)!!;
	char[] want = x`cb48cdc9c95728cf2fca498192601100`;
	assert(fixed == want);

	char[] inflate = flate::inflate(tmem, fixed)!!;
	assert(inflate == bytes, "got: '%s', want: '%s'", (String)inflate, (String)bytes);
}

fn void test_flate_store() => @pool()
{
	char[] bytes = "hello world";
	char[] non_comp = flate::deflate(tmem, bytes, &flate::encode_stored_block)!!;
	assert(non_comp.len == 1 + 2 + 2 + bytes.len);
	assert(non_comp[0] == 1);
	assert(non_comp[5..] == bytes[..]);

	char[] inflate = flate::inflate(tmem, non_comp)!!;
	assert(inflate == bytes);
}

