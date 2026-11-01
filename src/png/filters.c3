module image::png::filters;
import std::math;

excuse INVALID_FILTER;

const char FILTER_NONE @private = 0;
const char FILTER_SUB @private = 1;
const char FILTER_UP @private = 2;
const char FILTER_AVERAGE @private = 3;
const char FILTER_PAETH @private = 4;

fn char paeth_predictor(int a, int b, int c) @private
{
	int p = a + b - c;
	int pa = math::abs(p - a);
	int pb = math::abs(p - b);
	int pc = math::abs(p - c);
	if (pa <= pb && pa <= pc) return (char)a;
	if (pb <= pc) return (char)b;
	return (char)c;
}

<*
 Undo the per-row filters in place; each row is a filter byte followed by the row data.

 @require scanlines.len >= (sz)height * ((sz)width * bytes_per_pixel + 1) : "Scanline data too short"

 @return? INVALID_FILTER
*>
fn void? reconstruct(char[] scanlines, uint width, uint height, sz bytes_per_pixel)
{
	sz row_bytes = (sz)width * bytes_per_pixel;
	sz stride = row_bytes + 1;

	for (uint y = 0; y < height; y++)
	{
		sz row_start = (sz)y * stride;
		char[] row = scanlines[row_start + 1 : row_bytes];
		char[] prev_row = y > 0 ? scanlines[row_start - stride + 1 : row_bytes] : {};

		switch (scanlines[row_start])
		{
			case FILTER_NONE:
				break;
			case FILTER_SUB:
				for (sz i = bytes_per_pixel; i < row.len; i++) row[i] += row[i - bytes_per_pixel];
			case FILTER_UP:
				foreach (i, up : prev_row) row[i] += up;
			case FILTER_AVERAGE:
				for (sz i = 0; i < row.len; i++)
				{
					uint left = i >= bytes_per_pixel ? row[i - bytes_per_pixel] : 0;
					uint up = y > 0 ? prev_row[i] : 0;
					row[i] += (char)((left + up) / 2);
				}
			case FILTER_PAETH:
				for (sz i = 0; i < row.len; i++)
				{
					int a = i >= bytes_per_pixel ? row[i - bytes_per_pixel] : 0;
					int b = y > 0 ? prev_row[i] : 0;
					int c = i >= bytes_per_pixel && y > 0 ? prev_row[i - bytes_per_pixel] : 0;
					row[i] += paeth_predictor(a, b, c);
				}
			default:
				return INVALID_FILTER~;
		}
	}
}

<*
 Copy the row data out of filtered scanlines, dropping each row's filter byte.

 @require scanlines.len >= (sz)height * ((sz)width * bytes_per_pixel + 1) : "Scanline data too short"
 @require output.len >= (sz)height * (sz)width * bytes_per_pixel : "Output too small"
*>
fn void compact_pixels(char[] scanlines, char[] output, uint width, uint height, sz bytes_per_pixel)
{
	sz row_bytes = (sz)width * bytes_per_pixel;
	for (uint y = 0; y < height; y++)
	{
		output[(sz)y * row_bytes : row_bytes] = scanlines[(sz)y * (row_bytes + 1) + 1 : row_bytes];
	}
}
