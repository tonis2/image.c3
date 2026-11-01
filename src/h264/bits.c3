module image::h264;
import std::collections::list;

// An RBSP's bits, most significant first; reads past the end give zeros.
struct Bits @private
{
	char[] data;
	usz pos;  // bits read
	usz end;  // the rbsp_stop_one_bit's position
}

fn Bits bits_of(char[] data) @private
{
	Bits b = { .data = data };
	usz n = data.len;
	while (n > 0 && data[n - 1] == 0) n--;
	if (n == 0) return b;
	char last = data[n - 1];
	uint low = 0;
	while (((last >> low) & 1) == 0) low++;
	b.end = n * 8 - 1 - low;
	return b;
}

<*
 The next n bits, not consumed.

 @require n >= 1 && n <= 25 : "peek reads 1 to 25 bits"
*>
fn uint Bits.peek(&self, uint n) @inline
{
	usz at = self.pos >> 3;
	uint v;
	if (at + 4 <= self.data.len)
	{
		v = bitorder::read(self.data[at:4], UIntBE);
	}
	else
	{
		for (usz i = 0; i < 4; i++) v = v << 8 | (at + i < self.data.len ? (uint)self.data[at + i] : 0);
	}
	v <<= self.pos & 7;
	return v >> (32 - n);
}

<*
 @require n <= 32 : "u reads at most 32 bits"
*>
fn uint Bits.u(&self, uint n)
{
	if (n == 0) return 0;
	if (n > 24)
	{
		uint high = self.u(n - 16);
		return high << 16 | self.u(16);
	}
	uint v = self.peek(n);
	self.pos += n;
	return v;
}

fn bool Bits.flag(&self) @inline => self.u(1) != 0;

fn void Bits.skip(&self, uint n) @inline
{
	self.pos += n;
}

// ue(v); 0xFFFFFFFF when the code runs past 32 zeros.
fn uint Bits.ue(&self)
{
	uint zeros;
	uint v = self.peek(16);
	if (v != 0)
	{
		while ((v & 0x8000) == 0)
		{
			zeros++;
			v <<= 1;
		}
		self.pos += (usz)zeros + 1;
		return (1u << zeros) - 1 + self.u(zeros);
	}
	while (zeros < 32 && self.u(1) == 0) zeros++;
	if (zeros >= 32) return 0xFFFF_FFFF;
	return (1u << zeros) - 1 + self.u(zeros);
}

fn int Bits.se(&self)
{
	uint k = self.ue();
	if (k == 0xFFFF_FFFF) return 0;
	return (k & 1) ? (int)((k + 1) >> 1) : -(int)(k >> 1);
}

// te(v) with the range's top value.
fn uint Bits.te(&self, uint top) => top > 1 ? self.ue() : 1 - self.u(1);

fn bool Bits.more_data(&self) => self.pos < self.end;

fn bool Bits.overrun(&self) => self.pos > self.data.len * 8;

// A NAL unit's payload with emulation prevention bytes (00 00 03) taken out, into `out`.
fn char[] unescape(char[] nal, List {char}* out) @private
{
	out.clear();
	usz zeros;
	foreach (c : nal)
	{
		if (zeros >= 2 && c == 3)
		{
			zeros = 0;
			continue;
		}
		zeros = c == 0 ? zeros + 1 : 0;
		out.push(c);
	}
	return out.array_view();
}
