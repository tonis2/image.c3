# image.c3

A PNG decoding library for C3.

## Features

- Supports all PNG color types: Grayscale, RGB, Indexed (palette), Grayscale+Alpha, RGBA
- 8-bit and 16-bit bit depths
- Indexed images are automatically expanded to RGB/RGBA

## Usage

```c3
import image;
import image::png;

fn void main() {
    // Load from file
    Image img = png::load_file("photo.png")!!;
    defer img.free();

    io::printfn("Size: %dx%d", img.width, img.height);
    io::printfn("Format: %s", img.format);

    // Access pixel data
    char[] pixels = img.pixels;  // Row-major, top-to-bottom
}
```

### Load from memory

```c3
char[] png_data = /* ... */;
Image img = png::load_bytes(png_data)!!;
defer img.free();
```

## Limitations

- No interlaced PNG support (Adam7)
- No 1/2/4-bit depth support
- Decode only (no encoding)

## Dependencies

- [`compress.c3l`](https://github.com/konimarti/compress.c3l) - For DEFLATE decompression
