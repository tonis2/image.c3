// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate;
import std::io;

<*
 FlateDecompressor holds the bit reader, output writer, and the canonical
 Huffman metadata for literal/length and distance symbols. It provides methods
 to decode stored, fixed, and dynamic Huffman blocks.
*>
struct FlateDecompressor
{
	FlateReader reader; // Bit-level input reader (LSB-first).
	ByteWriter *writer; // Destination for uncompressed bytes.
	HuffOrder ls;       // Canonical order for literal/length symbols.
	HuffOrder ds;       // Canonical order for distance symbols.
}

<*
 Initializes a FlateDecompressor with the given input and output streams.
*>
fn void FlateDecompressor.init(&self, InStream r, ByteWriter *w)
{
	self.reader.init(r);
	self.writer = w;
}

<*
 Resets the decompressor state.
*>
fn void FlateDecompressor.free(&self)
{
	*self = {};
}

<*
 Reads and consumes nbits from the underlying bitstream (LSB-first).
*>
fn uint? FlateDecompressor.getbits(&self, uint nbits) @inline
{
	return self.reader.read_bits(nbits);
}

faultdef INVALID_LENGTH;
<*
 Decodes a stored (uncompressed) block.
 @return? INVALID_LENGTH
*>
fn void? FlateDecompressor.decode_stored_block(&self)
{
	// We already consumed BFINAL and BTYPE in the caller.
	// Discard remaining bits in this byte to reach next byte boundary.
	self.getbits(5)!;

	// Lengths are stored in 16bits in little endian (LSB).
	uint length = self.getbits(8)! | self.getbits(8)! << 8;
	uint inv_length = self.getbits(8)! | self.getbits(8)! << 8;

	// Sanity check: compare length with the inverse.
	if (length != (~inv_length & 0x0000FFFF))
	{
		return INVALID_LENGTH~;
	}

	LimitReader lr;
	lr.init(&self.reader, length);
	io::copy_to(&lr, self.writer)!;
}

<*
 Decodes a block compressed with the fixed Huffman code trees.
 Rebuilds the fixed literal/length and distance canonical Huffman structures.
*>
fn void? FlateDecompressor.decode_fixed_block(&self)
{
	self.ls = huff::build_canonical_symbols(
		huff::FIXED_LITERAL_LENGTH_CODE_LENGTHS);

	self.ds = huff::build_canonical_symbols(
		huff::FIXED_DISTANCE_CODE_LENGTHS);

	return self.inflate_block();
}

<*
 Decodes a block compressed with dynamic Huffman coding.
 Reads the dynamic Huffman tree description from the bitstream, builds the
 corresponding canonical literal/length and distance codes.
*>
fn void? FlateDecompressor.decode_dynamic_block(&self)
{
	self.decode_trees()!;
	return self.inflate_block();
}

<*
 Parses and builds the dynamic Huffman trees.
*>
fn void? FlateDecompressor.decode_trees(&self)
{
	char[288 + 32] lengths;
	uint nlit, ndist, nclen;
	int sym, len;

	nlit = self.getbits(5)! + 257;
	ndist = self.getbits(5)! + 1;
	nclen = self.getbits(4)! + 4;

	// Read bit lengths for code length codes.
	lengths[:19] = 0;
	for (usz i = 0; i < nclen; i++)
	{
		lengths[hc_order[i]] = (char)self.getbits(3)!;
	}

	// Build code length tree.
	HuffOrder code_length = huff::build_canonical_symbols(lengths[:19]);
	lengths[:19] = 0;

	// Decode code length for the dynamic trees.
	for (uint num = 0; num < nlit + ndist;)
	{
		len = 1;
		sym = self.decode_symbol(&code_length)!!;
		switch (sym)
		{
			case 16:
				sym = lengths[num-1];
				len = self.getbits(2)! + 3;
			case 17:
				sym = 0;
				len = self.getbits(3)! + 3;
			case 18:
				sym = 0;
				len = self.getbits(7)! + 11;
		}
		while (len--) lengths[num++] = (char)sym;
	}

	self.ls = huff::build_canonical_symbols(lengths[0:nlit]);
	self.ds = huff::build_canonical_symbols(lengths[nlit:ndist]);
}

<*
 Inflates a single compressed block using current Huffman data.
 Uses the literal/length (ls) and distance (ds) canonical information to
 decode symbols from the bitstream. Literals are written directly to the
 output; length/distance pairs cause bytes to be copied from already
 decompressed output until the end-of-block symbol is reached.
 Based on the tinf implementation.
*>
fn void? FlateDecompressor.inflate_block(&self)
{
	uint length, off;
	while (try sym = self.decode_symbol(&self.ls))
	{
		if (sym < END_OF_BLOCK)
		{
			self.writer.write_byte((char)sym)!;
			continue;
		}
		if (sym == END_OF_BLOCK) break;

		sym -= 257;

		length = len_base[sym];
		if (len_extra[sym])
		{
			length += self.getbits(len_extra[sym])!;
		}

		if (try dist = self.decode_symbol(&self.ds))
		{
			off = dist_base[dist];
			if (dist_extra[dist])
			{
				off += self.getbits(dist_extra[dist])!;
			}
		}

		for (usz i = 0; i < length; i++)
		{
			char[] out = self.writer.array_view();
			self.writer.write_byte(out[^off])!;
		}
	}
}

<*
 Decodes a single Huffman-coded symbol using canonical metadata.
 Interprets bits from the input as a canonical Huffman codeword of
 increasing length, using counts and symbols from the given HuffOrder.
 Based on zlib's puff implementation.

 @return "Returns the decoded symbol index"
 @return? NOT_FOUND
*>
fn int? FlateDecompressor.decode_symbol(&self, HuffOrder *h)
{
	int code, first, count, index;
	code = 0; first = 0; index = 0;
	for (int len = 1; len <= huff::MAX_CODE_BITS; len++)
	{
		code = (code << 1) | self.getbits(1)!;
		count = h.counts[len];
		if (code - count < first)
		{
			return h.symbols[index + (code - first)];
		}
		index += count;
		first += count;
		first <<= 1;
	}
	return NOT_FOUND~;
}


