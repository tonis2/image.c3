module image::png;
import image;
import image::png::chunks;
import image::png::zlib;
import std::hash::crc32;
import std::io::file;

fn bool is_valid_image(Image* img) @private
{
	if (img.width == 0 || img.height == 0) return false;
	if (img.bit_depth != 8 && img.bit_depth != 16) return false;
	return img.pixels.len >= (sz)img.width * (sz)img.height * img.bytes_per_pixel();
}

<*
 Encode an image as PNG (no filtering, single IDAT).

 @param [&in] img : "The image to encode"

 @return "The PNG file bytes, owned by `allocator`"
 @return? INVALID_IMAGE_DATA, zlib::compress!
*>
fn char[]? save_bytes(Image* img, Allocator allocator = mem)
{
	if (!is_valid_image(img)) return INVALID_IMAGE_DATA~;

	char[] filtered = add_filter_bytes(allocator, img);
	defer alloc::free(allocator, filtered);
	char[] compressed = zlib::compress(allocator, filtered)!;
	defer alloc::free(allocator, compressed);

	// Compression, filter and interlace methods stay 0.
	char[13] ihdr;
	bitorder::write(img.width, ihdr[0:4], UIntBE);
	bitorder::write(img.height, ihdr[4:4], UIntBE);
	ihdr[8] = img.bit_depth;
	ihdr[9] = color_type_of(img.format);

	char[] output = alloc::new_array(allocator, char, 8 + (12 + ihdr.len) + (12 + compressed.len) + 12);
	output[:8] = chunks::PNG_SIGNATURE[..];
	sz pos = 8;
	pos += write_chunk(output[pos..], "IHDR", ihdr[..]);
	pos += write_chunk(output[pos..], "IDAT", compressed);
	write_chunk(output[pos..], "IEND", {});
	return output;
}

<*
 Encode an image as PNG and write it to `path`.

 @param [&in] img : "The image to encode"

 @return? save_bytes!, file::save!
*>
fn void? save_file(Image* img, String path, Allocator allocator = mem)
{
	char[] data = save_bytes(img, allocator)!;
	defer alloc::free(allocator, data);
	file::save(path, data)!;
}

fn char[]? tsave_bytes(Image* img) => save_bytes(img, tmem);

fn void? tsave_file(Image* img, String path) => save_file(img, path, tmem);

<*
 Write one chunk (length, type, data, CRC) to the start of `buf`.

 @require chunk_type.len == 4 : "Chunk types are four characters"
 @require buf.len >= 12 + data.len : "Buffer too small"

 @return "Bytes written"
*>
fn sz write_chunk(char[] buf, String chunk_type, char[] data) @private
{
	sz len = data.len;
	bitorder::write((uint)len, buf[0:4], UIntBE);
	buf[4:4] = chunk_type[..];
	buf[8:len] = data[..];
	bitorder::write(crc32::hash(buf[4:4 + len]), buf[8 + len:4], UIntBE);
	return 12 + len;
}

fn char color_type_of(PixelFormat format) @private
{
	switch (format)
	{
		case GRAYSCALE: return chunks::COLOR_TYPE_GRAYSCALE;
		case GRAYSCALE_ALPHA: return chunks::COLOR_TYPE_GRAYSCALE_ALPHA;
		case RGB: return chunks::COLOR_TYPE_RGB;
		case RGBA: return chunks::COLOR_TYPE_RGBA;
	}
}

// Prefix every row with filter type 0 (None).
fn char[] add_filter_bytes(Allocator allocator, Image* img) @private
{
	sz row_bytes = (sz)img.width * img.bytes_per_pixel();
	char[] filtered = alloc::new_array(allocator, char, (sz)img.height * (row_bytes + 1));
	for (uint y = 0; y < img.height; y++)
	{
		filtered[(sz)y * (row_bytes + 1) + 1 : row_bytes] = img.pixels[(sz)y * row_bytes : row_bytes];
	}
	return filtered;
}
