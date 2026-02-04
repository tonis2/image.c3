// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate::lz77;
import std::io, std::collections;

const uint MIN_MATCH_LEN   = 3;
const uint MAX_MATCH_LEN   = 258;
const uint MAX_WINDOW_SIZE = 1U << 15;
const uint MIN_OFFSET_LEN  = 1;
const uint HASH_SIZE       = 1U << 15;
const uint HASH_MASK       = HASH_SIZE - 1;

enum LzTokenType : inline char
{
	INVALID,
	LITERAL,
	MATCH
}

bitstruct LzToken (Printable) : uint @bigendian @overlap
{
	LzTokenType type : 0..2;   // 2 bits:  0 = INVALID, 1 = LITERAL, 2 = MATCH, 3 = EOF
	char         len : 3..10;  // 8 bits:  len = length - MIN_MATCH_LENGTH, where length is [3-258]
	uint         off : 11..31; // 20 bits: off = offset - MIN_OFFSET_SIZE, where offset i [1-32768]
	char         lit : 24..31; // 8 bits:  store literal
}

fn uint LzToken.length(&self) => MIN_MATCH_LEN + self.len;
fn uint LzToken.offset(&self) => MIN_OFFSET_LEN + self.off;

<*
 @require length >= MIN_MATCH_LEN
 @require offset >= MIN_OFFSET_LEN
*>
fn LzToken make_match(uint length, uint offset)
{
	return (LzToken){
		.type = MATCH,
		.len = (char)(length - MIN_MATCH_LEN),
		.off = offset - MIN_OFFSET_LEN,
	};
}

fn LzToken make_literal(char literal)
{
	return (LzToken){
		.type = LITERAL,
		.lit = literal,
	};
}

fn usz? LzToken.to_format(&self, Formatter *f) @dynamic
{
	switch (self.type)
	{
		case LITERAL:
			return f.printf("LITERAL<%c>", self.lit);
		case MATCH:
			return f.printf("MATCH<%d:%d>", self.offset(), self.length());
		default:
			unreachable("invalid token type");
	}
}

alias HashKey  = uint;
fn HashKey hash(char[3] b) @private
{
	uint x = (b[0] << 16) | (b[1] << 8) | b[2];
	x ^= x >> 12;
	x ^= x << 5;
	return x & HASH_MASK;
}

alias LzRingBuf = CircularBuffer{ MAX_WINDOW_SIZE };

struct LzMatch
{
	uint length;
	uint distance;
}

struct LzMatchFinder
{
	LzRingBuf rb;
	int[] head;
	int[] prev;
	Allocator allocator;
}

fn void LzMatchFinder.init(&self, Allocator allocator)
{
	self.rb.init();
	self.head = allocator::new_array(allocator, int, HASH_SIZE);
	self.prev = allocator::new_array(allocator, int, MAX_WINDOW_SIZE);
	self.head[..] = -1;
	self.prev[..] = -1;
	self.allocator = allocator;
}

fn void LzMatchFinder.free(&self)
{
	allocator::free(self.allocator, self.head);
	allocator::free(self.allocator, self.prev);
	*self = {};
}

fn void LzMatchFinder.put_char(&self, char b) => self.rb.push(b);

<*
 Insert the current position p with hash h into the hash table.
*>
fn void LzMatchFinder.insert(&self, HashKey h, int p)
{
	ulong head_index = (ulong)h & (HASH_SIZE - 1);
	ulong prev_index = (ulong)p & (MAX_WINDOW_SIZE - 1);
	if (self.head[head_index] >= 0)
	{
		self.prev[prev_index] = self.head[head_index];
	}
	self.head[head_index] = p;
}

<*
 @require lookahead.len >= MIN_MATCH_LEN
*>
fn LzMatch? LzMatchFinder.find_match(&self, int p, char[] lookahead)
{
	uint match_len, dist_len, best_len, best_dist;
	int n, candidate, rem;
	char[MAX_MATCH_LEN] window;

	// Calculate hash at current position p
	HashKey h = hash(lookahead[:3]);

	// Get first candidate from head.
	candidate = self.head[h & (HASH_SIZE-1)];

	// Iterate the hash table and check valid candidates.
	while (candidate >= 0)
	{
		dist_len = p - candidate;
		if (dist_len > MAX_WINDOW_SIZE)
		{
			// "Remove" node.
			self.prev[candidate & (MAX_WINDOW_SIZE-1)] = -1;
			break;
		}

		// Fill "sliding window".
		n = (int)self.rb.read(candidate, window[:lookahead.len]);
		assert(n > 0);

		// Fill up remaining bytes in sliding window from lookahead.
		rem = lookahead.len - n;
		if (rem > 0)
		{
			window[n:rem] = lookahead[0:rem];
			n += rem;
		}

		// Find matching length.
		match_len = 0;
		while (match_len < n && window[match_len] == lookahead[match_len])
		{
				match_len++;
		}

		if (match_len >= MIN_MATCH_LEN && dist_len >= MIN_OFFSET_LEN &&
			(match_len > best_len || (match_len == best_len && dist_len < best_dist)))
		{
			best_len = match_len;
			best_dist = dist_len;

			if (best_len == MAX_MATCH_LEN) break; // Keep this match.
		}

		// Move to next match.
		candidate = self.prev[candidate & (MAX_WINDOW_SIZE-1)];
	}

	// Insert current hash.
	self.insert(h, p);

	// Put byte into sliding window.
	self.put_char(lookahead[0]);

	if (best_len == 0 || best_dist == 0) return NOT_FOUND~;

	// Insert all positions we're about to jump.
	for (int i = 1; i < best_len; i++)
	{
		self.put_char(lookahead[i]);
		if (i < lookahead.len - 2)
		{
			h = hash(lookahead[i:3]);
			self.insert(h, p+i);
		}
	}

	return {best_len, best_dist};
}

<*
 Tokenize input byte stream into literal or match tokens using the Lempel-Ziv
 compression approach.

 @param [&inout] allocator : "Allocator for the returned token array"
 @param [in] bytes         : "Input data to be compressed by LZ77"
*>
fn LzToken[] tokenize(Allocator allocator, char[] bytes) => @pool()
{
	int i, n, rem;

	List{LzToken} tokens;
	tokens.tinit();

	LzMatchFinder mf;
	mf.init(tmem);

	n = bytes.len;
	while (i < n - 2)
	{
		rem = n - i;
		rem = rem > MAX_MATCH_LEN ? MAX_MATCH_LEN : rem;
		if (try match = mf.find_match(i, bytes[i:rem]))
		{
			// Note: If we implement lazy matching, ensure that
			// logic from find_match about updating the sliding
			// window is adjusted.
			tokens.push(make_match(match.length, match.distance));
			i += match.length;
		}
		else
		{
			tokens.push(make_literal(bytes[i]));
			i++;
		}
	}

	// Emit remaining literal tokens.
	while (i < n)
	{
		tokens.push(make_literal(bytes[i]));
		i++;
	}

	return tokens.to_array(allocator);
}

<*
 Construct a byte array from a LZ77-compressed token array.
*>
fn char[] construct(Allocator allocator, LzToken[] tokens) => @pool()
{
	DString buf;
	buf.tinit();

	foreach (token: tokens)
	{
		switch (token.type)
		{
			case LITERAL:
				buf.append_char(token.lit);
			case MATCH:
				usz start = buf.len() - token.offset();
				usz end   = start + token.length();
				for (usz i = start; i < end; i++)
				{
					buf.append_char(buf[i]);
				}
			default:
				continue;
		}
	}

	return buf.copy_str(allocator);
}

<*
 circbuf implements a circular ring buffer with a fixed-size sliding window.
 The size of the sliding window is given by generic parameter N.
*>
module compress::flate::lz77::circbuf<N>;

struct CircularBuffer
{
	char[N] buf;
	usz write;
}

fn void CircularBuffer.init(&self)
{
	*self = {};
}

macro usz CircularBuffer.mask(&self, usz v)
{
	var $is_power_of_two = N != 0 && (N & (N-1)) == 0;
	$if $is_power_of_two:
		return v & (N - 1);
	$else
		return v % self.buf.len;
	$endif
}

<*
 Push a char into the buffer. If the buffer is full, it will wrap around and
 overwrite data.
*>
fn void CircularBuffer.push(&self, char b)
{
	self.buf[self.mask(self.write)] = b;
	self.write++;
}

<*
Reads up to dest.len bytes starting at position start into dest.
If start is before the oldest valid position, or if start is at or beyond
self.write, no data is available and the function returns 0. The actual number
of bytes copied is limited both by dest.len and by the number of bytes
available up to write.

@param start      : "Start position to read from."
@param [out] dest : "Destination buffer where the data will be copied."
@return "The number of bytes actually read into dest."
*>
fn usz CircularBuffer.read(&self, usz start, char[] dest)
{
	usz oldest = self.write > self.buf.len ? self.write - self.buf.len : 0;

	// Start outside of window.
	if (start < oldest) return 0; //start = oldest;

 	// Nothing available.
	if (start >= self.write) return 0;

	// Available bytes from start up to write
	usz available = self.write - start;

	// Clamp n to available bytes.
	usz n = dest.len;
	if (n > available) n = available;

	// Read n bytes from start:
	// First chunk until buffer end.
	usz first = self.buf.len - self.mask(start);
	if (first > n) first = n;
	dest[:first] = self.buf[self.mask(start):first];

	// Optional second chunk from beginning.
	if (first < n)
	{
		usz rem = n - first;
		dest[first:rem] = self.buf[:rem];
	}
	return n;
}


module compress::flate::lz77_bench @benchmark;
import compress::flate::lz77;
import compress::flate::lz77_test_data @public;

fn void bench_lz77_long_text() => @pool()
{
	String text = lz77_test_data::long_text;
	LzToken[] tokens = lz77::tokenize(tmem, text);
}

module compress::flate::lz77_test @test;
import compress::flate::lz77;
import compress::flate::lz77_test_data @public;

fn void test_lz77_short() => @pool()
{
	String[] tests = {
		"aaa aaaa aaaa",
 		"hello world world hello"
	};
	foreach (s: tests)
	{
		LzToken[] tokens = lz77::tokenize(tmem, s);
		String r = (String)lz77::construct(tmem, tokens);
		assert(r == s, "got: %s, want: %s", r, s);
	}
}

fn void test_lz77_long_text() => @pool()
{
	String text = lz77_test_data::long_text[..];
	LzToken[] tokens = lz77::tokenize(tmem, text);
	String r = (String)lz77::construct(tmem, tokens);
	test::eq(r, text);
}

module compress::flate::lz77_test_data @private;

String long_text = `{
  "provides" : "compress",
  "sources" : [ "src/**" ],
  "targets" : {
    "android-aarch64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "freebsd-x64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "linux-aarch64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "linux-riscv32" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "linux-riscv64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "linux-x86" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "linux-x64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "macos-aarch64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "macos-x64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "netbsd-aarch64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "netbsd-x64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "openbsd-x64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "wasm32" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "wasm64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "windows-aarch64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "windows-x64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
  }
}`;

