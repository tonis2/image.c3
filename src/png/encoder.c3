module image::png;
import image;
import image::png::chunks;
import image::png::zlib;
import std::hash::crc32;
import std::io::file;
import std::io;

// Validate image data for basic correctness.
fn bool validate_image_data(Image* img) {
	if (img.pixels.len == 0) return false;
	if (img.width == 0 || img.height == 0) return false;

	usz expected = (usz)img.width * (usz)img.height * img.bytes_per_pixel();
	if (img.pixels.len < expected) return false;

	return true;
}

fn char[]? save_bytes(Image* img, Allocator allocator = mem, bool check_valid = false) {
	// Validate image data before encoding
	if (!validate_image_data(img)) {
		io::printfn("ERROR: Image data validation failed - refusing to save corrupted image");
		return INVALID_IMAGE_DATA~;
	}
	
	char color_type = format_to_color_type(img.format);

	// Prepend filter byte (0x00 = None) to each scanline
	char[] filtered = apply_filter_none(allocator, img);
	defer alloc::free(allocator, filtered);

	// ZLIB compress the filtered data
	char[] compressed = zlib::compress(allocator, filtered)!;
	defer alloc::free(allocator, compressed);

	// Build IHDR data (13 bytes)
	char[13] ihdr_data;
	ihdr_data[0] = (char)(img.width >> 24);
	ihdr_data[1] = (char)(img.width >> 16);
	ihdr_data[2] = (char)(img.width >> 8);
	ihdr_data[3] = (char)(img.width);
	ihdr_data[4] = (char)(img.height >> 24);
	ihdr_data[5] = (char)(img.height >> 16);
	ihdr_data[6] = (char)(img.height >> 8);
	ihdr_data[7] = (char)(img.height);
	ihdr_data[8] = img.bit_depth;
	ihdr_data[9] = color_type;
	ihdr_data[10] = 0; // compression method
	ihdr_data[11] = 0; // filter method
	ihdr_data[12] = 0; // interlace method

	// Calculate total output size
	usz total = 8 + (12 + 13) + (12 + compressed.len) + 12;
	char[] output = alloc::new_array(allocator, char, total);
	usz pos = 0;

	// PNG signature
	for (usz i = 0; i < 8; i++) {
		output[i] = chunks::PNG_SIGNATURE[i];
	}
	pos = 8;

	// IHDR chunk
	pos += write_chunk(output[pos..], "IHDR", ihdr_data[..]);

	// IDAT chunk
	pos += write_chunk(output[pos..], "IDAT", compressed);

	// IEND chunk
	char[] no_data;
	pos += write_chunk(output[pos..], "IEND", no_data);

	return output;
}

fn void? save_file(Image* img, String path, Allocator allocator = mem, bool check_valid = false) {
	char[] data = save_bytes(img, allocator, check_valid)!;
	defer alloc::free(allocator, data);
	file::save(path, data)!;
}

fn char[]? tsave_bytes(Image* img, bool check_valid = false) => save_bytes(img, tmem, check_valid);

fn void? tsave_file(Image* img, String path, bool check_valid = false) => save_file(img, path, tmem, check_valid);

fn usz write_chunk(char[] buf, String chunk_type, char[] data) {
	usz len = data.len;

	// Length (big-endian)
	buf[0] = (char)((uint)len >> 24);
	buf[1] = (char)((uint)len >> 16);
	buf[2] = (char)((uint)len >> 8);
	buf[3] = (char)((uint)len);

	// Type
	buf[4] = chunk_type[0];
	buf[5] = chunk_type[1];
	buf[6] = chunk_type[2];
	buf[7] = chunk_type[3];

	// Data
	for (usz i = 0; i < len; i++) {
		buf[8 + i] = data[i];
	}

	// CRC over type + data
	uint crc = crc32::hash(buf[4 : 4 + len]);
	buf[8 + len] = (char)(crc >> 24);
	buf[9 + len] = (char)(crc >> 16);
	buf[10 + len] = (char)(crc >> 8);
	buf[11 + len] = (char)(crc);

	return 12 + len;
}

fn char format_to_color_type(PixelFormat format) {
	switch (format) {
		case GRAYSCALE: return chunks::COLOR_TYPE_GRAYSCALE;
		case GRAYSCALE_ALPHA: return chunks::COLOR_TYPE_GRAYSCALE_ALPHA;
		case RGB: return chunks::COLOR_TYPE_RGB;
		case RGBA: return chunks::COLOR_TYPE_RGBA;
	}
}

fn char[] apply_filter_none(Allocator allocator, Image* img) {
	usz bpp = img.bytes_per_pixel();
	usz row_bytes = (usz)img.width * bpp;
	usz filtered_size = (usz)img.height * (row_bytes + 1);

	char[] filtered = alloc::new_array(allocator, char, filtered_size);

	for (uint y = 0; y < img.height; y++) {
		usz src_offset = (usz)y * row_bytes;
		usz dst_offset = (usz)y * (row_bytes + 1);

		filtered[dst_offset] = 0; // Filter type: None

		for (usz i = 0; i < row_bytes; i++) {
			filtered[dst_offset + 1 + i] = img.pixels[src_offset + i];
		}
	}

	return filtered;
}
