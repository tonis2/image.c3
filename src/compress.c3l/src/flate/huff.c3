// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
<*
 Huffman code generation utilities for DEFLATE.
*>
module compress::flate::huff;
import std::bits, compress::flate::pkgmerge;

<*
 Maximum allowed Huffman code length (in bits) for DEFLATE.
*>
const MAX_CODE_BITS = 15;

<*
 Canonical code lengths for the fixed literal/length Huffman tree defined by DEFLATE.
*>
const char[] FIXED_LITERAL_LENGTH_CODE_LENGTHS = {
	[  0..143] = 8,
 	[144..255] = 9,
 	[256..279] = 7,
 	[280..287] = 8,
};

<*
 Canonical code lengths for the fixed distance Huffman tree defined by DEFLATE.
*>
const char[] FIXED_DISTANCE_CODE_LENGTHS = {
	[0..31] = 5,
};

<*
 HuffCodes holds a canonical Huffman codebook for DEFLATE-style coding.
 It stores the code length and codeword for each symbol index, plus the
 highest symbol index that has a non-zero length. This is the structure
 used on the encoding side to map symbols to (code, bit length).
*>
struct HuffCodes
{
	char[288] blen;  // Code length (in bits) for each symbol; 0 means “no code”.
	uint[288] codes; // Canonical Huffman codeword for each symbol.
	int max_sym;     // Highest symbol index with a non-zero code length; -1 if empty.
}

<*
 Reverse bit order of all non-zero-length codes, preparing them for LSB-first
 DEFLATE bitstream output. Not needed for decoding.
*>
fn void HuffCodes.reverse(&self)
{
	foreach (i, &code: self.codes)
	{
		if (self.blen[i] == 0) continue;
		uint shift = $typeof(*code).sizeof * 8 - self.blen[i];
		*code = bits::reverse(*code << shift);
	}
}

<*
 Build a HuffCodes from symbol frequencies using a package-merge length
 generator, optionally bit-reversing codes for DEFLATE encoding.

 @require freqs.len <= 288 : "Cannot be larger than 288"
*>
fn HuffCodes? build_codes_from_freqs(uint[] freqs,
	uint max_code_bits = MAX_CODE_BITS, bool reverse = true) => @pool()
{
	char[] codelen = pkgmerge::codelen(tmem, freqs, max_code_bits);
	return build_codes_from_lengths(codelen: codelen, reverse: reverse);
}

<*
 Build a HuffCodes from given code lengths using canonical Huffman rules;
 optionally bit-reverse codes for DEFLATE’s LSB-first packing.

 @require codelen.len <= 288 : "Cannot be larger than 288"
*>
fn HuffCodes? build_codes_from_lengths(char[] codelen, bool reverse = true)
{
	HuffCodes h;
	h.blen[:codelen.len] = codelen[..];
	h.max_sym = build_canonical_codes(&h.codes, &h.blen)!;
	if (reverse) h.reverse();
	return h;
}

faultdef ERR_CODEGEN;

<*
 Compute canonical Huffman codes from code lengths (RFC 1951, section 3.2.2),
 returning the highest symbol index that received a code.

 This function computes the corresponding canonical codes and stores them in
 codes, using MSB-oriented integers.

 @param [out] codes        : "Canonical Huffman codes."
 @param [in] blen          : "Bit lengths for Huffman codes"
 @return "Max symbol for generated Huffman codes."
 @return? ERR_CODEGEN
*>
fn int? build_canonical_codes(uint[] codes, char[] blen)
{
	uint[MAX_CODE_BITS + 1] bl_count;
	uint[MAX_CODE_BITS] next_code;
	int max_sym = -1;

	foreach (len: blen)
	{
		assert(len < 16, "got: %d", len);
		bl_count[len]++;
	}

	if (bl_count[0] == blen.len) return 0;
	bl_count[0] = 0;

	uint code = 0;
	for (uint bits = 1; bits <= MAX_CODE_BITS; bits++)
	{
	        code = (code + bl_count[bits-1]) << 1;
		next_code[bits-1] = code;
	}

	foreach (int i, len: blen)
	{
		if (len == 0) continue;
		codes[i] = next_code[len-1];
		next_code[len-1]++;
		max_sym = i;
	}
	if (max_sym < 0) return ERR_CODEGEN~;
	return max_sym;
}

fn void test_huff_codegen() @test
{
	char[4] blen = { 2, 1, 3, 3 };
	uint[4] want= { 0b10, 0b0, 0b110, 0b111 };
	uint[4] codes;
	int max_sym = build_canonical_codes(&codes, &blen)!!;
	assert(max_sym == 3);
	assert(codes == want);
}

<*
 HuffOrder represents the canonical ordering of symbols implied by their
 code lengths. It is derived from the length array and is typically used
 as an intermediate for Huffman decoding.
*>
struct HuffOrder
{
	uint[MAX_CODE_BITS + 1] counts; // Number of symbols of each lengths (0-15).
	uint[288] symbols;          // Symbols in canonical order.
}

<*
 Derive canonical symbol ordering and per-length counts from code lengths,
 for decoding.
*>
fn HuffOrder build_canonical_symbols(char[] lengths)
{
	uint[MAX_CODE_BITS+1] offs;
	HuffOrder h;

	foreach (len : lengths) h.counts[len]++;
	if (h.counts[0] == lengths.len) return h; // No codes.

	offs[1] = 0;
	for (int len = 1; len < huff::MAX_CODE_BITS; len++)
	{
		offs[len+1] = offs[len] + h.counts[len];
	}

	foreach (int sym, len: lengths)
	{
		if (len != 0) h.symbols[offs[len]++] = sym;
	}
	return h;
}

