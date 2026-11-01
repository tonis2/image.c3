module image::png;
import image;
import image::png::chunks;
import image::png::filters;
import image::png::zlib;
import std::io::file;
import std::collections::list;

excuse INVALID_SIGNATURE,
       MISSING_PALETTE,
       INCOMPLETE_DATA,
       INVALID_IMAGE_DATA;

<*
 Load and decode a PNG file.

 @return? INVALID_SIGNATURE, MISSING_PALETTE, INCOMPLETE_DATA, file::load!, load_bytes!
*>
fn Image? load_file(String path, Allocator allocator = mem)
{
	char[] file_data = file::load(allocator, path)!;
	defer alloc::free(allocator, file_data);
	return load_bytes(file_data, allocator);
}

fn Image? tload_file(String path) => load_file(path, tmem);

<*
 Decode a PNG held in memory. Indexed images are expanded to RGB, or RGBA when tRNS is present.

 @return "The decoded image; free it with Image.free"
 @return? INVALID_SIGNATURE, MISSING_PALETTE, INCOMPLETE_DATA, chunks::parse_chunk!, chunks::parse_ihdr!, zlib::decompress!, filters::reconstruct!
*>
fn Image? load_bytes(char[] data, Allocator allocator = mem)
{
	if (!chunks::verify_signature(data)) return INVALID_SIGNATURE~;

	sz offset = 8;
	chunks::Chunk ihdr_chunk = chunks::parse_chunk(data, offset)!;
	chunks::IhdrData ihdr = chunks::parse_ihdr(&ihdr_chunk)!;
	offset += ihdr_chunk.total_size();

	List {char} idat_buffer;
	idat_buffer.init(allocator);
	defer idat_buffer.free();

	char[] palette;
	char[] trns;
	while CHUNKS: (offset < data.len)
	{
		chunks::Chunk chunk = chunks::parse_chunk(data, offset)!;
		offset += chunk.total_size();
		switch (chunk.type[..])
		{
			case "IDAT": idat_buffer.push_all(chunk.data);
			case "PLTE": palette = chunk.data;
			case "tRNS": trns = chunk.data;
			case "IEND": break CHUNKS;
		}
	}

	bool indexed = ihdr.color_type == chunks::COLOR_TYPE_INDEXED;
	if (indexed && palette.len == 0) return MISSING_PALETTE~;

	char[] decompressed = zlib::decompress(allocator, idat_buffer.array_view())!;
	defer alloc::free(allocator, decompressed);

	sz filter_bpp = bytes_per_pixel(ihdr.color_type, ihdr.bit_depth);
	// A truncated stream would otherwise be read past its end below.
	if (decompressed.len < (sz)ihdr.height * ((sz)ihdr.width * filter_bpp + 1)) return INCOMPLETE_DATA~;
	filters::reconstruct(decompressed, ihdr.width, ihdr.height, filter_bpp)!;

	PixelFormat out_format = indexed ? (trns.len > 0 ? RGBA : RGB) : color_type_to_format(ihdr.color_type);
	sz out_bpp = indexed ? (trns.len > 0 ? 4 : 3) : filter_bpp;
	char[] output = alloc::new_array(allocator, char, (sz)ihdr.width * (sz)ihdr.height * out_bpp);

	if (indexed)
	{
		expand_indexed(decompressed, output, ihdr.width, ihdr.height, palette, trns);
	}
	else
	{
		filters::compact_pixels(decompressed, output, ihdr.width, ihdr.height, filter_bpp);
	}

	return {
		.width = ihdr.width,
		.height = ihdr.height,
		.bit_depth = ihdr.bit_depth,
		.format = out_format,
		.pixels = output,
		.allocator = allocator
	};
}

fn Image? tload_bytes(char[] data) => load_bytes(data, tmem);

<*
 @require color_type != chunks::COLOR_TYPE_INDEXED : "Indexed images are expanded separately"
*>
fn PixelFormat color_type_to_format(char color_type) @private
{
	switch (color_type)
	{
		case chunks::COLOR_TYPE_GRAYSCALE: return GRAYSCALE;
		case chunks::COLOR_TYPE_RGB: return RGB;
		case chunks::COLOR_TYPE_GRAYSCALE_ALPHA: return GRAYSCALE_ALPHA;
		default: return RGBA;
	}
}

// Bytes per pixel in the filtered scanlines; parse_ihdr has already rejected unknown color types.
fn sz bytes_per_pixel(char color_type, char bit_depth) @private
{
	sz channels;
	switch (color_type)
	{
		case chunks::COLOR_TYPE_GRAYSCALE:
		case chunks::COLOR_TYPE_INDEXED: channels = 1;
		case chunks::COLOR_TYPE_GRAYSCALE_ALPHA: channels = 2;
		case chunks::COLOR_TYPE_RGB: channels = 3;
		default: channels = 4;
	}
	return bit_depth == 16 ? channels * 2 : channels;
}

fn void expand_indexed(char[] scanlines, char[] output, uint width, uint height, char[] palette, char[] trns) @private
{
	sz stride = (sz)width + 1;
	bool has_alpha = trns.len > 0;
	sz out_bpp = has_alpha ? 4 : 3;

	for (uint y = 0; y < height; y++)
	{
		char[] src = scanlines[(sz)y * stride + 1 : width];
		sz dst_row = (sz)y * (sz)width * out_bpp;
		foreach (x, index : src)
		{
			sz pal_offset = (sz)index * 3;
			sz dst = dst_row + x * out_bpp;
			// Out-of-range indices are left black rather than rejected.
			if (pal_offset + 2 < palette.len) output[dst:3] = palette[pal_offset:3];
			if (has_alpha) output[dst + 3] = index < trns.len ? trns[index] : 255;
		}
	}
}
