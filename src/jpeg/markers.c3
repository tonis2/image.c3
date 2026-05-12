module image::jpeg::markers;

faultdef UNEXPECTED_EOF, INVALID_SEGMENT;

const char SOI  = 0xD8;
const char EOI  = 0xD9;
const char SOF0 = 0xC0;
const char SOF1 = 0xC1;
const char SOF2 = 0xC2;
const char SOF3 = 0xC3;
const char DHT  = 0xC4;
const char SOF5 = 0xC5;
const char SOF6 = 0xC6;
const char SOF7 = 0xC7;
const char SOF9 = 0xC9;
const char SOFA = 0xCA;
const char SOFB = 0xCB;
const char DAC  = 0xCC;
const char SOFD = 0xCD;
const char SOFE = 0xCE;
const char SOFF = 0xCF;
const char DQT  = 0xDB;
const char DRI  = 0xDD;
const char SOS  = 0xDA;
const char COM  = 0xFE;
const char APP0 = 0xE0;
const char RST0 = 0xD0;

fn uint read_u16_be(char[] data) {
	return ((uint)data[0] << 8) | (uint)data[1];
}

fn bool is_sof(char marker) {
	return (marker >= 0xC0 && marker <= 0xCF) && marker != DHT && marker != DAC;
}

fn bool is_app_or_com(char marker) {
	return (marker >= 0xE0 && marker <= 0xEF) || marker == COM;
}

fn bool is_rst(char marker) {
	return marker >= RST0 && marker <= 0xD7;
}

struct Segment {
	char marker;
	char[] payload;
	sz next_offset;
}

<*
 Read the next marker segment.
 On entry `offset` should point at any byte; we skip 0xFF fill bytes
 and require a 0xFF prefix. Standalone markers (SOI, EOI, RSTn) return
 with `payload.len == 0`. Other markers read a big-endian length and
 carve the payload slice.
*>
fn Segment? next_segment(char[] data, sz offset) {
	sz i = offset;
	while (i < data.len && data[i] != 0xFF) i++;
	while (i < data.len && data[i] == 0xFF) i++;
	if (i >= data.len) return UNEXPECTED_EOF~;

	char marker = data[i];
	i++;

	if (marker == SOI || marker == EOI || is_rst(marker) || marker == 0x01) {
		return { marker, {}, i };
	}

	if (i + 2 > data.len) return UNEXPECTED_EOF~;
	uint length = read_u16_be(data[i:2]);
	if (length < 2) return INVALID_SEGMENT~;
	if (i + (sz)length > data.len) return UNEXPECTED_EOF~;

	char[] payload = data[i + 2 : (sz)length - 2];
	return { marker, payload, i + (sz)length };
}
