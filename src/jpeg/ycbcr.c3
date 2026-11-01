module image::jpeg::ycbcr;
import image::jpeg::idct;

<*
 BT.601 full-range JFIF YCbCr -> RGB conversion using Q16 fixed point.

 @require cb_plane.len == y_plane.len && cr_plane.len == y_plane.len : "Planes must be the same size"
 @require dst_rgb.len >= y_plane.len * 3 : "Output too small"
*>
fn void ycbcr_to_rgb(char[] y_plane, char[] cb_plane, char[] cr_plane, char[] dst_rgb)
{
	foreach (i, luma : y_plane)
	{
		int y  = luma;
		int cb = (int)cb_plane[i] - 128;
		int cr = (int)cr_plane[i] - 128;
		dst_rgb[i * 3 + 0] = idct::clamp(y + ((91881 * cr) >> 16));
		dst_rgb[i * 3 + 1] = idct::clamp(y - ((22554 * cb + 46802 * cr) >> 16));
		dst_rgb[i * 3 + 2] = idct::clamp(y + ((116130 * cb) >> 16));
	}
}
