// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
<*
 Bit-level I/O utilities for DEFLATE streams, providing LSB-first reading and
 writing of arbitrary-width fields.
*>
module compress::flate::bitio;
import std::io;

<*
 FlateWriter accumulates bits in a little-endian buffer and writes bytes to the
 underlying stream as soon as the internal buffer fills up. Bits are appended
 starting at the least significant bit (LSB-first), which matches DEFLATE’s bit
 ordering requirements for headers and Huffman codes.
*>
struct FlateWriter
{
	OutStream writer;
	uint bits;
	uint nbits;
}

<*
 Initialize a FlateWriter with the given output stream.
*>
fn void FlateWriter.init(&self, OutStream w)
{
	*self = { .writer = w, .bits = 0, .nbits = 0 };
}

<*
 Writes the lowest num_bits of bits to the bitstream (LSB-first).

 Bits are appended to the internal buffer and flushed to the underlying
 writer in full bytes when enough bits have accumulated.

 @param bits     : "Bits to write LSB-first to the output stream."
 @param num_bits : "Number of bits to write"
 @require num_bits > 0 && num_bits <= 32
*>
fn void? FlateWriter.write_bits(&self, uint bits, uint num_bits)
{
	while (self.nbits + num_bits >= 32)
	{
		self.writer.write_byte((char)(self.bits & 0xff))!;
		self.bits >>= 8;
		self.nbits -= 8;
	}

	bits &= (1 << num_bits) - 1;
	self.bits |= bits << self.nbits;
	self.nbits += num_bits;
}

<*
 Flushes all remaining bits in the buffer as bytes with zero padding.

 Any partial byte is written with its unused high bits set to zero. After this
 call, the internal bit buffer is empty.
*>
fn void? FlateWriter.flush(&self)
{
	int rem;
	while (self.nbits)
	{
		rem = self.nbits > 8 ? 8 : self.nbits;
		self.writer.write_byte((char)(self.bits & 0xff))!;
		self.bits >>= rem;
		self.nbits -= rem;
	}
	assert(self.nbits == 0);
}

<*
 FlateReader reads bits from an underlying byte stream in little-endian
 order, maintaining an internal bit buffer. New bytes are appended at the
 current highest bit position; callers can read arbitrary bit widths, which
 is required for DEFLATE headers and Huffman-coded fields.
*>
struct FlateReader (InStream)
{
	InStream reader;
	ulong bits;
	uint  nbits;
}

<*
 Initializes a FlateReader with the given input stream.
*>
fn void FlateReader.init(&self, InStream reader)
{
	*self = { .reader = reader, .bits = 0, .nbits = 0};
}

<*
 Reads a raw byte from the underlying stream.

 This requires that the internal bit buffer is empty to avoid mixing
 byte-wise and bit-wise reads.
*>
fn char? FlateReader.read_byte(&self) @dynamic
{
	assert(self.nbits == 0);
	return self.reader.read_byte();
}

<*
 Reads raw bytes into buf from the underlying stream.

 This requires that the internal bit buffer is empty, ensuring consistent
 alignment between byte-wise and bit-wise operations.
*>
fn usz? FlateReader.read(&self, char[] buf) @dynamic
{
	assert(self.nbits == 0);
	return self.reader.read(buf);
}

<*
 Returns the next num_bits bits without consuming them (LSB-first).

 The function fills the internal buffer from the underlying stream until
 at least num_bits are available, then returns the masked low bits.

 @param num_bits : "Number of bits to peek"
 @require num_bits > 0 && num_bits <= 32
*>
fn uint? FlateReader.peek_bits(&self, isz num_bits)
{
	while (self.nbits < num_bits)
	{
		// New bits are appended on the left.
		char c = self.reader.read_byte()!;
		self.bits |= (ulong)c << self.nbits;
		self.nbits += 8;
	}

	ulong mask = (1UL << num_bits) - 1;
	return (uint)(self.bits & mask);
}

<*
 Reads and consumes num_bits bits from the stream (LSB-first).

 Bits are taken from the low end of the internal buffer, then the buffer
 is shifted down and its bit count reduced. This matches the way DEFLATE
 packs integers and Huffman codes into the bitstream.

 @param num_bits : "Number of bits to read"
 @require num_bits > 0 && num_bits <= 32
*>
fn uint? FlateReader.read_bits(&self, uint num_bits)
{
	uint v = self.peek_bits(num_bits)!;
	self.bits >>= num_bits;
	self.nbits -= num_bits;
	return v;
}

module compress::flate::bench @benchmark;
import compress::flate::bitio;

fn void test_bitwriter_bench() @benchmark
{
	ByteWriter byte_writer;
	byte_writer.init(mem);
	defer byte_writer.free();

	FlateWriter bw;
	bw.init(&byte_writer);

	for (uint i = 0; i < (1<<9); i++)
	{
		bw.write_bits(0b1010011, 7);
	}
}

module compress::flate::test @test;
import compress::flate::bitio, std::io;

fn void test_bitwriter() => @pool()
{
	ByteWriter byte_writer;
	byte_writer.tinit();

	FlateWriter bw;
	bw.init(&byte_writer);

	bw.write_bits(0b1111101, 3)!!;
	assert(bw.nbits == 3);
	assert(bw.bits == 0b101);

	bw.write_bits(0b1001001, 7)!!;
	assert(bw.nbits == 10);
	assert(bw.bits == 0b1001001_101);

	bw.write_bits(0b10011, 5)!!;
	assert(bw.nbits == 15);
	assert(bw.bits == 0b10011_1001001_101);

	bw.flush()!!;
	char[] out = byte_writer.array_view();
	assert(out.len == 2);
	assert(out[0] == 0b01001101);
	assert(out[1] == 0b01001110);
}

fn void test_bitreader()
{
	ByteReader r = io::wrap_bytes({0b10000001, 0b1110});
	FlateReader br;
	br.init(&r);
	assert(br.read_bits(1)!! == 1);
	assert(br.read_bits(2)!! == 0);
	assert(br.read_bits(3)!! == 0);
	assert(br.read_bits(1)!! == 0);
	assert(br.read_bits(1)!! == 1);
	assert(br.read_bits(2)!! == 2);
	assert(br.read_bits(2)!! == 3);
}

fn void test_bitreader_boundary()
{
	ByteReader r = io::wrap_bytes({0b10000011, 0b101110});
	FlateReader br;
	br.init(&r);
	assert(br.read_bits(5)!! == 3);
	assert(br.read_bits(9)!! == 0b101110100);
}

fn void test_bitreader_example()
{
	ByteReader r = io::wrap_bytes(x`2de8b1090000080341ace2700a160f011bd70f88cd15d7058ad590ef8d01`);
	FlateReader br;
	br.init(&r);
	assert(br.read_bits(1)!! == 1);
	assert(br.read_bits(2)!! == 0b10);
	assert(br.read_bits(5)!! == 5);  // HLIT
	assert(br.read_bits(5)!! == 8);  // HDIST
	assert(br.read_bits(4)!! == 15); // HDIST
}

