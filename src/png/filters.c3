module image::png::filters;

faultdef INVALID_FILTER;

const char FILTER_NONE = 0;
const char FILTER_SUB = 1;
const char FILTER_UP = 2;
const char FILTER_AVERAGE = 3;
const char FILTER_PAETH = 4;

fn char paeth_predictor(int a, int b, int c) {
	int p = a + b - c;
	int pa = p > a ? p - a : a - p;
	int pb = p > b ? p - b : b - p;
	int pc = p > c ? p - c : c - p;

	if (pa <= pb && pa <= pc) {
		return (char)a;
	} else if (pb <= pc) {
		return (char)b;
	} else {
		return (char)c;
	}
}

// Reconstruct filtered scanlines in-place
// scanlines: raw decompressed data with filter byte per row
// width: image width in pixels
// height: image height
// bytes_per_pixel: number of bytes per pixel
fn void? reconstruct(char[] scanlines, uint width, uint height, usz bytes_per_pixel) {
	usz row_bytes = (usz)width * bytes_per_pixel;
	usz stride = row_bytes + 1; // +1 for filter byte

	for (uint y = 0; y < height; y++) {
		usz row_start = (usz)y * stride;
		char filter_type = scanlines[row_start];
		char[] row = scanlines[row_start + 1 : row_bytes];
		char[] prev_row;

		if (y > 0) {
			usz prev_start = ((usz)y - 1) * stride;
			prev_row = scanlines[prev_start + 1 : row_bytes];
		}

		switch (filter_type) {
			case FILTER_NONE: break;
			case FILTER_SUB:
				for (usz i = bytes_per_pixel; i < row.len; i++) {
					row[i] = (char)((uint)row[i] + (uint)row[i - bytes_per_pixel]);
				}
			case FILTER_UP:
				if (y > 0) {
					for (usz i = 0; i < row.len; i++) {
						row[i] = (char)((uint)row[i] + (uint)prev_row[i]);
					}
				}
			case FILTER_AVERAGE:
				for (usz i = 0; i < row.len; i++) {
					uint left = i >= bytes_per_pixel ? row[i - bytes_per_pixel] : 0;
					uint up = y > 0 ? prev_row[i] : 0;
					row[i] = (char)((uint)row[i] + (left + up) / 2);
				}
			case FILTER_PAETH:
				for (usz i = 0; i < row.len; i++) {
					int a = i >= bytes_per_pixel ? row[i - bytes_per_pixel] : 0;
					int b = y > 0 ? prev_row[i] : 0;
					int c = (i >= bytes_per_pixel && y > 0) ? prev_row[i - bytes_per_pixel] : 0;
					row[i] = (char)((uint)row[i] + (uint)paeth_predictor(a, b, c));
				}
			default:
				return INVALID_FILTER~;
		}
	}
}

// Remove filter bytes and compact pixel data
fn void compact_pixels(char[] scanlines, char[] output, uint width, uint height, usz bytes_per_pixel) {
	usz stride = (usz)width * bytes_per_pixel + 1;
	usz out_stride = (usz)width * bytes_per_pixel;

	for (uint y = 0; y < height; y++) {
		usz src_start = (usz)y * stride + 1; // Skip filter byte
		usz dst_start = (usz)y * out_stride;
		output[dst_start : out_stride] = scanlines[src_start : out_stride];
	}
}
