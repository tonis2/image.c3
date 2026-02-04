// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate;
import std::collections::list, std::io;

const END_OF_BLOCK = 256;

<*
 FlateCompressor owns the bit writer and the canonical Huffman codes for
 literal/length and distance symbols. It provides methods to build Huffman
 trees from token statistics and to emit block headers and compressed data into
 the output stream.
*>
struct FlateCompressor
{
	FlateWriter writer; // Bit-level output writer (LSB-first).
	HuffCodes lt;       // Literal/Length Huffman codes.
	HuffCodes dt;       // Distance Huffman codes.
}

<*
 Initializes a FlateCompressor with the given output stream.
*>
fn void FlateCompressor.init(&self, OutStream wrapped)
{
	self.writer.init(wrapped);
}

<*
 Writes nbits bits to the bitstream.
*>
fn void? FlateCompressor.putbits(&self, uint bits, uint nbits) @inline
{
	self.writer.write_bits(bits, nbits)!;
}

<*
 Flushes all remaining bits from the internal bit buffer.
 Writes any partial byte with zero padding in the unused high bits. Typically
 called once after all blocks have been emitted to finish the bitstream.
*>
fn void? FlateCompressor.flush_bits(&self) @inline
{
	self.writer.flush()!;
}

<*
 Builds dynamic Huffman codes from LZ77 tokens.
 Computes literal/length and distance symbol frequencies from the supplied
 tokens, adds the end-of-block marker, and generates canonical Huffman codes
 for both alphabets.
*>
fn void? FlateCompressor.build_trees(&self, LzToken[] tokens)
{
	// Calculate literal, length and distance frequencies.
	uint[288] lt_freqs;
	uint[30] dt_freqs;
	usz index;
	foreach (token: tokens)
	{
		switch (token.type)
		{
			case LITERAL:
				if (lt_freqs[token.lit] == uint.max)
				{
					// Overflow check.
					continue;
				}
				lt_freqs[token.lit]++;

			case MATCH:
				index = 257 + huff_index_lookup(&len_base, token.length());
				if (lt_freqs[index] == uint.max)
				{
					// Overflow check.
					continue;
				}
				lt_freqs[index]++;

				index = huff_index_lookup(&dist_base, token.offset());
				if (dt_freqs[index] == uint.max)
				{
					// Overflow check.
					continue;
				}
				dt_freqs[index]++;

			default:
				unreachable("invalid token encountered");
		}
	}

 	// Don't forget the end of block marker.
	lt_freqs[END_OF_BLOCK]++;

	// Generate Huffman codes.
	self.lt = huff::build_codes_from_freqs(&lt_freqs)!;
	self.dt = huff::build_codes_from_freqs(&dt_freqs)!;
}

<*
 Writes the dynamic Huffman block header.
 Run-length encodes the literal/length and distance code lengths, builds the
 code-length Huffman tree, and writes the corresponding header and encoded
 code-length sequence to the bitstream. If final is true, BFINAL is set on this
 block.
*>
fn void? FlateCompressor.write_dynamic_header(&self, bool bfinal = true) => @pool()
{
	char sym;
	uint i, hlit, hdist, hclen;

	hlit = (self.lt.max_sym < 257) ? 0 : self.lt.max_sym + 1 - 257;
	hdist = self.dt.max_sym;

	// Create run-length encoder.
	CodeLengthEncoder encoder;
	encoder.init(tmem);
	encoder.encode(self.lt.blen[:hlit+257], self.dt.blen[:hdist+1])!;

	hclen = encoder.max_sym + 1 - 4;

	// Write block header.
	// Push BFINAL (0b1 or 0b0) and BTYPE (0b10).
	self.write_block_header(bfinal ? 1 : 0, 0b10)!;

	// Write 5 bits HLIT (# of literal/length codes - 257)
	assert(hlit <= 31);
	self.putbits(hlit, 5)!;

	// Write 5 bits HDIST (# of distance codes - 1)
	assert(hdist+1 > 0 && hdist < 30);
	self.putbits(hdist, 5)!;

	// Push 4 bits HCLEN (# of code length codes - 4)
	assert(hclen >= 4);
	self.putbits(hclen, 4)!;

	for (i = 0; i < hclen + 4; i++)
	{
		self.putbits(encoder.cl_codes.blen[hc_order[i]], 3)!;
	}

	// Write encoded code length.
	char[] enc = encoder.encoded.array_view();
	for (i = 0; i < enc.len; )
	{
		sym = enc[i++];
		self.putbits(encoder.cl_codes.codes[sym], encoder.cl_codes.blen[sym])!;
		switch (sym)
		{
			case 16: self.putbits(enc[i++], 2)!;
			case 17: self.putbits(enc[i++], 3)!;
			case 18: self.putbits(enc[i++], 7)!;
		}
	}

}

<*
 Builds the fixed Huffman codes.
 Initializes lt and dt with the canonical fixed literal/length and
 distance codes specified in RFC 1951.
*>
fn void? FlateCompressor.build_fixed_trees(&self)
{
	self.lt = huff::build_codes_from_lengths(
		huff::FIXED_LITERAL_LENGTH_CODE_LENGTHS)!;

	self.dt = huff::build_codes_from_lengths(
		huff::FIXED_DISTANCE_CODE_LENGTHS)!;
}

<*
 Writes a block header given BFINAL and BTYPE.
*>
fn void? FlateCompressor.write_block_header(&self, uint bfinal, uint btype) @inline
{
	self.putbits(bfinal, 1)!;
	self.putbits(btype, 2)!;
}


<*
 Encodes all LZ77 tokens for the current block using lt and dt.
 Literals are encoded directly with the literal/length tree; matches
 are mapped to length and distance codes plus any required extra bits.
*>
fn void? FlateCompressor.write_compressed_data(&self, LzToken[] tokens)
{
	foreach (token: tokens)
	{
		switch (token.type)
		{
			case LITERAL: self.write_literal(token.lit)!;
			case MATCH:   self.write_match(token.length(), token.offset())!;
			default: unreachable("invalid token type encountered");
		}
	}
}

<*
 Writes a distance Huffman code for the given distance slot.
*>
fn void? FlateCompressor.write_distance(&self, usz l) @inline
{
	char len = self.dt.blen[l];
	uint code = self.dt.codes[l];
	self.putbits(code, len)!;
}

<*
 Writes a literal/length Huffman code for the given symbol.
*>
fn void? FlateCompressor.write_literal(&self, usz c) @inline
{
	char len = self.lt.blen[c];
	uint code = self.lt.codes[c];
	self.putbits(code, len)!;
}

<*
 Writes the end-of-block symbol for the current block.
*>
fn void? FlateCompressor.write_end_of_block(&self) @inline
{
	self.write_literal(END_OF_BLOCK)!;
}

<*
 Writes a match (length, distance) pair to the stream.
*>
fn void? FlateCompressor.write_match(&self, uint len, uint dist)
{
	usz index;

	// Write length code.
	index = huff_index_lookup(&len_base, len);
	self.write_literal(index + 257)!;

	// Write extra bit.
	if (len_extra[index])
	{
		self.putbits(len-len_base[index], len_extra[index])!;
	}

	// Write distance code.
	index = huff_index_lookup(&dist_base, dist);
	self.write_distance(index)!;

	// Write extra bit.
	if (dist_extra[index])
	{
		self.putbits(dist-dist_base[index], dist_extra[index])!;
	}
}

<* Create code-length Huff codes. *>
char[*] hc_order = {
	16, 17, 18,  0,  8, 7,  9,  6, 10,  5,
	11,  4, 12,  3, 13, 2, 14,  1, 15,
 };

<* Lengths base values. *>
uint[*] len_base = {
	3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17,
	19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
	99, 115, 131, 163, 195, 227, 258,
};

<* Extra bits for lengths. *>
char[*] len_extra = {
	0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1,
	2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
	5, 5, 5, 5, 0,
};

<* Distance base values. *>
uint[*] dist_base = {
	1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97,
	129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
	4097, 6145, 8193, 12289, 16385, 24577,
};

<* Extra bits for distance. *>
char[*] dist_extra = {
	0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4,
	5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
	11, 11, 12, 12, 13, 13,
};

<*
 Returns the index for the the value v in the provided set of base values.
*>
fn usz huff_index_lookup(uint[] base, uint v) @inline
{
	usz i;
	while (i < base.len - 1)
	{
		if (v < base[i+1]) break;
		i++;
	}
	return i;
}

<*
 CodeLengthEncoder takes the literal/length and distance code-length sequences,
 run-length encodes them using symbols 0–18, and computes canonical Huffman
 codes for those symbols. The encoded sequence is stored in encoded.
*>
struct CodeLengthEncoder
{
	ByteWriter encoded; // Encoded code-length stream (symbols 0–18 plus extra bytes).
	HuffCodes cl_codes; // Canonical Huffman codes for the code-length alphabet.
	int max_sym;        // Highest hc_order[] symbol used in ct.
}

fn void CodeLengthEncoder.init(&self, Allocator allocator)
{
	self.encoded.init(allocator);
	self.cl_codes = {};
	self.max_sym = -1;
}

fn void CodeLengthEncoder.free(&self)
{
	(void)self.encoded.destroy();
}

<*
 Encodes literal/length and distance code lengths and builds the code-length
 tree.
*>
fn void? CodeLengthEncoder.encode(&self, char[] lt_len, char[] dt_len)
{
	usz i, n;
	char sym;
	uint[19] freqs;

	n = lt_len.len + dt_len.len;
	self.encoded.ensure_capacity(n)!;
	@pool()
	{
		// Combine literal/length and distance code lengths.
		char[] lengths = mem::temp_array(char, n);
		lengths[:lt_len.len] = lt_len[:lt_len.len];
		lengths[lt_len.len:dt_len.len] = dt_len[:dt_len.len];

		// Encode the code lengths.
		encode_code_lengths(&self.encoded, lengths)!;
	};

	// Calculate frequencies of the encoded code lengths.
	char[] enc = self.encoded.array_view();
	self.max_sym = -1;
	i = 0;
	while (i < enc.len)
	{
		sym = enc[i++];
		if (sym > 15) i++; // Skip extra bits for symbols 16,17,18
		if (hc_order[sym] > self.max_sym) self.max_sym = hc_order[sym];
		freqs[sym]++;
	}

	assert(self.max_sym >= 0);

	self.cl_codes = huff::build_codes_from_freqs(freqs[..], 5)!;
}

<*
 Takes a sequence of code lengths and emits a compact representation into enc
 using the code-length alphabet (RFC 1951):
   - literal length values 0–15 are directly encoded,
   - symbol 16 is used for repeated non-zero lengths (3–6 repeats),
   - symbol 17 is used for repeated zero lengths (3–10 zeros),
   - symbol 18 is used for repeated zero lengths (11–138 zeros).
 Extra repeat counts for symbols 16–18 are emitted as following bytes.
*>
fn void? encode_code_lengths(ByteWriter *enc, char[] seq) @private => @pool()
{
	usz i, r, rem;
	while (i < seq.len)
	{
 		// Code length symbol.
		char sym = seq[i];
		assert(sym < huff::MAX_CODE_BITS);

		// Count repetitions of sym.
		r = 1;
		while (i+r < seq.len && seq[i+r] == sym) r++;
		switch
		{
			case (sym != 0 && r <= 3) || (sym == 0 && r < 3):
				rem = r;
				while (rem--) enc.write_byte(sym)!;
				i += r;
			case sym != 0 && r > 3:
				enc.write_byte(sym)!;
				i++; r--;
				while (r > 2)
				{
					rem = r > 6 ? 6 : r;
					enc.write_byte(16)!;
					enc.write_byte((char)rem-3)!;
					r -= rem;
					i += rem;
				}
			case sym == 0 && r >= 3 && r < 11:
				enc.write_byte(17)!;
				enc.write_byte((char)r-3)!;
				i += r;
			case sym == 0 && r >= 11:
				while (r > 10)
				{
					rem = r > 138 ? 138 : r;
					enc.write_byte(18)!;
					enc.write_byte((char)rem-11)!;
					r -= rem;
					i += rem;
				}
			default: unreachable("internal error");
		}
	}
}

struct CodeLengthTestCase @private
{
	char[] input;
	char[] want;
}

fn void test_encode_code_lengths() @test => @pool()
{
	CodeLengthTestCase[*] tests = {
		{
			.input = {1,2,3,4},
			.want  = {1,2,3,4},
		},
		{
			.input = {1,1},
			.want  = {1,1},
		},
		{
			.input = {1,1,1},
			.want  = {1,1,1},
		},
		{
			.input = {1,1,1,1},
			.want  = {1,16,0},
		},
		{
			.input = {1,1,1,1,1,1,1},
			.want  = {1,16,3},
		},
		{
			.input = {1,1,1,1,1,1,1,1},
			.want  = {1,16,3,1},
		},
		{
			.input = {0,0},
			.want  = {0,0},
		},
		{
			.input = {0,0,0},
			.want  = {17,0},
		},
		{
			.input = {0,0,0,0,0},
			.want  = {17,2},
		},
		{
			.input = {[9]=0},
			.want  = {17,7},
		},
		{
			.input = {[10]=0},
			.want  = {18,0},
		},
		{
			.input = {[11]=0},
			.want  = {18,1},
		},
		{
			.input = {[137]=0},
			.want  = {18,127},
		},
		{
			.input = {[138]=0},
			.want  = {18,127,0},
		},
	};

	foreach (j, test: tests)
	{
		ByteWriter bw;
		bw.tinit();
		encode_code_lengths(&bw, test.input)!!;
		char[] enc = bw.array_view();
		test::eq(enc.len, test.want.len);
		foreach (i, got: enc)
		{
			test::eq(got, test.want[i]);
		}
	}
}
