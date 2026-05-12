module image::jpeg::huffman;

faultdef INVALID_HUFFMAN_TABLE, INVALID_BITSTREAM, UNEXPECTED_EOF;

const uint FAST_BITS = 9;
const uint FAST_SIZE = 1 << FAST_BITS;
const ushort FAST_EMPTY = 0xFFFF;

// JPEG zigzag order: index in natural row-major order for each zigzag position.
const char[64] ZIGZAG = {
	 0,  1,  8, 16,  9,  2,  3, 10,
	17, 24, 32, 25, 18, 11,  4,  5,
	12, 19, 26, 33, 40, 48, 41, 34,
	27, 20, 13,  6,  7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36,
	29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46,
	53, 60, 61, 54, 47, 55, 62, 63,
};

struct HuffmanTable {
	bool defined;
	ushort[FAST_SIZE] fast;     // (length << 8) | symbol, or FAST_EMPTY
	int[17] mincode;            // mincode[L] for length L in 1..16; entry 0 unused
	int[17] maxcode;            // -1 if no codes of that length
	int[17] valptr;             // index into values[] for first code of length L
	char[256] values;
	int num_values;
}

<*
 Build a JPEG Huffman table from BITS[16] (counts per code length 1..16)
 and HUFFVAL[] (symbols ordered by code length).
*>
fn void? HuffmanTable.build(&self, char[] bits, char[] values) {
	if (bits.len < 16) return INVALID_HUFFMAN_TABLE~;

	sz total = 0;
	for (uint i = 0; i < 16; i++) total += (sz)bits[i];
	if (total > 256 || total > values.len) return INVALID_HUFFMAN_TABLE~;

	*self = {};
	self.defined = true;
	self.num_values = (int)total;
	for (sz i = 0; i < total; i++) self.values[i] = values[i];

	// Initialize fast lookup to "empty" sentinel.
	for (uint i = 0; i < FAST_SIZE; i++) self.fast[i] = FAST_EMPTY;

	// Canonical code generation (JPEG Annex C / ITU T.81 figure C.2-C.3).
	int code = 0;
	int idx = 0;
	for (uint len = 1; len <= 16; len++) {
		uint count = (uint)bits[len - 1];
		if (count == 0) {
			self.mincode[len] = 0;
			self.maxcode[len] = -1;
			self.valptr[len] = 0;
			code <<= 1;
			continue;
		}
		self.valptr[len] = idx;
		self.mincode[len] = code;
		self.maxcode[len] = code + (int)count - 1;

		if (len <= FAST_BITS) {
			uint shift = FAST_BITS - len;
			for (uint i = 0; i < count; i++) {
				uint base = (uint)(code + (int)i) << shift;
				ushort entry = (ushort)((len << 8) | (uint)self.values[idx + (int)i]);
				uint span = 1u << shift;
				for (uint j = 0; j < span; j++) {
					self.fast[base + j] = entry;
				}
			}
		}
		code += (int)count;
		idx += (int)count;
		code <<= 1;
	}
	return;
}

struct BitReader {
	char[] data;
	sz pos;
	ulong buf;        // MSB-aligned 64-bit shift register
	int  bits;        // valid bit count in buf, top-aligned
	bool marker_seen; // true once a non-stuffed 0xFF<xx> appears
	char marker;      // the marker byte (xx) once marker_seen
}

fn void BitReader.init(&self, char[] data, sz pos) {
	*self = { .data = data, .pos = pos };
}

<*
 Pull bytes from the entropy stream, handling 0xFF byte stuffing.
 Stops feeding once a real marker is encountered.
*>
fn void BitReader.refill(&self) {
	while (self.bits <= 56) {
		if (self.marker_seen) return;
		if (self.pos >= self.data.len) {
			self.marker_seen = true;
			self.marker = 0;
			return;
		}
		char b = self.data[self.pos];
		self.pos++;
		if (b == 0xFF) {
			if (self.pos >= self.data.len) {
				self.marker_seen = true;
				self.marker = 0;
				return;
			}
			char nx = self.data[self.pos];
			if (nx == 0x00) {
				self.pos++;
				// emit 0xFF
			} else {
				self.marker_seen = true;
				self.marker = nx;
				self.pos++;
				return;
			}
		}
		self.buf |= (ulong)b << (56 - self.bits);
		self.bits += 8;
	}
}

fn uint BitReader.peek(&self, uint n) {
	if (n == 0) return 0;
	return (uint)(self.buf >> (64 - n));
}

fn void BitReader.consume(&self, uint n) {
	self.buf <<= n;
	self.bits -= (int)n;
}

fn int? BitReader.receive(&self, uint n) {
	if (n == 0) return 0;
	if (self.bits < (int)n) {
		self.refill();
		if (self.bits < (int)n) return UNEXPECTED_EOF~;
	}
	uint v = self.peek(n);
	self.consume(n);
	return (int)v;
}

<*
 Decode the signed amplitude of `n` bits per JPEG Figure F.12 EXTEND.
*>
fn int? BitReader.receive_extend(&self, uint n) {
	if (n == 0) return 0;
	int v = self.receive(n)!;
	if (v < (1 << (n - 1))) {
		v += (-1 << n) + 1;
	}
	return v;
}

fn void BitReader.flush_to_byte(&self) {
	int drop = self.bits & 7;
	self.consume((uint)drop);
}

fn int? BitReader.decode_symbol(&self, HuffmanTable* tbl) {
	if (self.bits < 16) self.refill();
	if (self.bits == 0) return INVALID_BITSTREAM~;

	// Fast path. Buffer is MSB-aligned, so high `bits` are real and the rest
	// are zero — a valid index for a code of length <= bits.
	uint idx = (uint)(self.buf >> (64 - FAST_BITS));
	ushort entry = tbl.fast[idx];
	if (entry != FAST_EMPTY) {
		uint len = (uint)(entry >> 8);
		if ((int)len <= self.bits) {
			uint sym = (uint)(entry & 0xFF);
			self.consume(len);
			return (int)sym;
		}
	}

	// Slow path: walk lengths 10..16.
	for (uint len = FAST_BITS + 1; len <= 16; len++) {
		if (self.bits < (int)len) {
			self.refill();
			if (self.bits < (int)len) return INVALID_BITSTREAM~;
		}
		int code = (int)self.peek(len);
		if (code <= tbl.maxcode[len]) {
			self.consume(len);
			int j = tbl.valptr[len] + (code - tbl.mincode[len]);
			if (j < 0 || j >= tbl.num_values) return INVALID_BITSTREAM~;
			return (int)tbl.values[j];
		}
	}
	return INVALID_BITSTREAM~;
}

<*
 Decode one 8x8 block of DCT coefficients into `coeffs` (in natural row-major order),
 starting from a zeroed buffer. Updates `dc_pred` in place.
*>
fn void? decode_block(BitReader* br, HuffmanTable* dc_tbl, HuffmanTable* ac_tbl, int* coeffs, int* dc_pred) {
	for (int i = 0; i < 64; i++) coeffs[i] = 0;

	int t = br.decode_symbol(dc_tbl)!;
	if (t < 0 || t > 15) return INVALID_BITSTREAM~;
	int diff = br.receive_extend((uint)t)!;
	*dc_pred += diff;
	coeffs[0] = *dc_pred;

	int k = 1;
	while (k < 64) {
		int rs = br.decode_symbol(ac_tbl)!;
		int r = rs >> 4;
		int s = rs & 0x0F;
		if (s == 0) {
			if (r == 15) {
				k += 16;
				continue;
			}
			break; // EOB
		}
		k += r;
		if (k >= 64) return INVALID_BITSTREAM~;
		int v = br.receive_extend((uint)s)!;
		coeffs[ZIGZAG[k]] = v;
		k++;
	}
	return;
}
