module image::png;
import image;
import image::png::chunks;
import image::png::filters;
import image::png::zlib;
import std::io::file;
import std::collections::list;

faultdef INVALID_SIGNATURE,
         MISSING_PALETTE,
         INCOMPLETE_DATA,
         INVALID_IMAGE_DATA;

fn Image? load_file(String path, Allocator allocator = mem) {
	char[] file_data = file::load(allocator, path)!;
	defer alloc::free(allocator, file_data);
	return load_bytes(file_data, allocator);
}

fn Image? tload_file(String path) => load_file(path, tmem);

fn Image? load_bytes(char[] data, Allocator allocator = mem) {
	// Verify PNG signature
	if (!chunks::verify_signature(data)) {
		return INVALID_SIGNATURE~;
	}

	sz offset = 8; // Skip signature

	// Parse IHDR (must be first chunk)
	chunks::Chunk ihdr_chunk = chunks::parse_chunk(data, offset)!;
	chunks::IhdrData ihdr = chunks::parse_ihdr(&ihdr_chunk)!;
	offset += ihdr_chunk.total_size();

	// Collect IDAT data and optional PLTE/tRNS
	List{char} idat_buffer;
	idat_buffer.init(allocator);
	defer idat_buffer.free();

	char[] palette;
	char[] trns;

	// Parse remaining chunks
	while (offset < data.len) {
		chunks::Chunk chunk = chunks::parse_chunk(data, offset)!;
		offset += chunk.total_size();

		if (chunk.type[..] == "IDAT") {
			idat_buffer.push_all(chunk.data);
		} else if (chunk.type[..] == "PLTE") {
			palette = chunk.data;
		} else if (chunk.type[..] == "tRNS") {
			trns = chunk.data;
		} else if (chunk.type[..] == "IEND") {
			break;
		}
		// Skip other chunks (ancillary)
	}

	// Validate palette requirement for indexed color
	if (ihdr.color_type == chunks::COLOR_TYPE_INDEXED && palette.len == 0) {
		return MISSING_PALETTE~;
	}

	// Decompress IDAT data
	char[] compressed_data = idat_buffer.array_view();
	char[] decompressed = zlib::decompress(allocator, compressed_data)!;
	defer alloc::free(allocator, decompressed);

	// Calculate bytes per pixel for filter reconstruction
	sz filter_bpp = get_filter_bytes_per_pixel(ihdr.color_type, ihdr.bit_depth);

	// Reconstruct filters in-place
	filters::reconstruct(decompressed, ihdr.width, ihdr.height, filter_bpp)!;

	// Determine output format and allocate output buffer
	PixelFormat out_format;
	sz out_bpp;

	if (ihdr.color_type == chunks::COLOR_TYPE_INDEXED) {
		// Indexed will expand to RGB or RGBA
		if (trns.len > 0) {
			out_format = PixelFormat.RGBA;
			out_bpp = 4;
		} else {
			out_format = PixelFormat.RGB;
			out_bpp = 3;
		}
	} else {
		out_format = color_type_to_format(ihdr.color_type);
		out_bpp = get_output_bytes_per_pixel(ihdr.color_type, ihdr.bit_depth);
	}

	sz output_size = (sz)ihdr.width * (sz)ihdr.height * out_bpp;
	char[] output = alloc::new_array(allocator, char, output_size);

	if (ihdr.color_type == chunks::COLOR_TYPE_INDEXED) {
		// Expand indexed to RGB/RGBA
		expand_indexed(decompressed, output, ihdr.width, ihdr.height, palette, trns);
	} else {
		// Compact pixels (remove filter bytes)
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

fn PixelFormat color_type_to_format(char color_type) {
	switch (color_type) {
		case chunks::COLOR_TYPE_GRAYSCALE: return PixelFormat.GRAYSCALE;
		case chunks::COLOR_TYPE_RGB: return PixelFormat.RGB;
		case chunks::COLOR_TYPE_GRAYSCALE_ALPHA: return PixelFormat.GRAYSCALE_ALPHA;
		case chunks::COLOR_TYPE_RGBA: return PixelFormat.RGBA;
		default: return PixelFormat.RGBA;
	}
}

fn sz get_filter_bytes_per_pixel(char color_type, char bit_depth) {
	sz channels;
	switch (color_type) {
		case chunks::COLOR_TYPE_GRAYSCALE: channels = 1;
		case chunks::COLOR_TYPE_RGB: channels = 3;
		case chunks::COLOR_TYPE_INDEXED: channels = 1;
		case chunks::COLOR_TYPE_GRAYSCALE_ALPHA: channels = 2;
		case chunks::COLOR_TYPE_RGBA: channels = 4;
		default: channels = 4;
	}
	sz bytes_per_channel = bit_depth == 16 ? 2 : 1;
	return channels * bytes_per_channel;
}

fn sz get_output_bytes_per_pixel(char color_type, char bit_depth) {
	sz channels;
	switch (color_type) {
		case chunks::COLOR_TYPE_GRAYSCALE: channels = 1;
		case chunks::COLOR_TYPE_RGB: channels = 3;
		case chunks::COLOR_TYPE_GRAYSCALE_ALPHA: channels = 2;
		case chunks::COLOR_TYPE_RGBA: channels = 4;
		default: channels = 4;
	}
	sz bytes_per_channel = bit_depth == 16 ? 2 : 1;
	return channels * bytes_per_channel;
}

fn void expand_indexed(char[] scanlines, char[] output, uint width, uint height, char[] palette, char[] trns) {
	sz stride = (sz)width + 1; // 1 byte per pixel + filter byte
	bool has_alpha = trns.len > 0;
	sz out_bpp = has_alpha ? 4 : 3;

	for (uint y = 0; y < height; y++) {
		sz src_row = (sz)y * stride + 1; // Skip filter byte
		sz dst_row = (sz)y * (sz)width * out_bpp;

		for (uint x = 0; x < width; x++) {
			char index = scanlines[src_row + x];
			sz pal_offset = (sz)index * 3;
			sz dst_offset = dst_row + (sz)x * out_bpp;

			// Copy RGB from palette
			if (pal_offset + 2 < palette.len) {
				output[dst_offset] = palette[pal_offset];
				output[dst_offset + 1] = palette[pal_offset + 1];
				output[dst_offset + 2] = palette[pal_offset + 2];
			}

			// Add alpha if tRNS present
			if (has_alpha) {
				if ((sz)index < trns.len) {
					output[dst_offset + 3] = trns[index];
				} else {
					output[dst_offset + 3] = 255;
				}
			}
		}
	}
}
