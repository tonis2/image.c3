module image::jpeg::markers;
import image::jpeg;

const char SOI  = 0xD8;
const char EOI  = 0xD9;
const char SOF0 = 0xC0;
const char SOF2 = 0xC2;
const char DHT  = 0xC4;
const char DAC  = 0xCC;
const char DQT  = 0xDB;
const char DRI  = 0xDD;
const char SOS  = 0xDA;
const char COM  = 0xFE;
const char RST0 = 0xD0;
const char TEM  = 0x01;

fn uint read_u16_be(char[] data) => bitorder::read(data[:2], UShortBE);
fn bool is_sof(char marker) => marker >= 0xC0 && marker <= 0xCF && marker != DHT && marker != DAC;
fn bool is_app_or_com(char marker) => (marker >= 0xE0 && marker <= 0xEF) || marker == COM;
fn bool is_rst(char marker) => marker >= RST0 && marker <= 0xD7;

struct Segment
{
	char marker;
	char[] payload;
	sz next_offset;
}

<*
 Read the next marker segment at or after `offset`, skipping fill bytes.
 Standalone markers (SOI, EOI, RSTn, TEM) have an empty payload.

 @return? jpeg::UNEXPECTED_EOF, jpeg::INVALID_SEGMENT
*>
fn Segment? next_segment(char[] data, sz offset)
{
	sz i = offset;
	while (i < data.len && data[i] != 0xFF) i++;
	while (i < data.len && data[i] == 0xFF) i++;
	if (i >= data.len) return jpeg::UNEXPECTED_EOF~;

	char marker = data[i++];
	if (marker == SOI || marker == EOI || is_rst(marker) || marker == TEM) return { marker, {}, i };

	if (i + 2 > data.len) return jpeg::UNEXPECTED_EOF~;
	sz length = read_u16_be(data[i:2]);
	if (length < 2) return jpeg::INVALID_SEGMENT~;
	if (i + length > data.len) return jpeg::UNEXPECTED_EOF~;
	return { marker, data[i + 2:length - 2], i + length };
}
