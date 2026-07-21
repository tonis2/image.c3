# image.c3

An image decoding library for C3 supporting PNG and JPEG formats.


## Features

### PNG
- Supports all color types: Grayscale, RGB, Indexed (palette), Grayscale+Alpha, RGBA
- 8-bit and 16-bit bit depths
- Indexed images are automatically expanded to RGB/RGBA

### JPEG
- Grayscale (1 component) and YCbCr (3 components, JFIF/Exif)
- Chroma subsampling 4:4:4, 4:2:2, 4:2:0, 4:4:0
- Restart markers (DRI / RSTn)
- Output is RGB for color, GRAYSCALE for single-component

## Usage

### PNG

Load from file

```c3
import image::png;

fn void main() {
    Image img = png::load_file("photo.png")!!;
    defer img.free();

    io::printfn("Size: %dx%d", img.width, img.height);
    io::printfn("Format: %s", img.format);

    // Access pixel data
    char[] pixels = img.pixels;  // Row-major, top-to-bottom
}
```

Load from memory

```c3
char[] png_data = /* ... */;
Image img = png::load_bytes(png_data)!!;
defer img.free();
```

### JPEG

```c3
import image::jpeg;

fn void main() {
    Image img = jpeg::load_file("photo.jpg")!!;
    defer img.free();

    io::printfn("Size: %dx%d", img.width, img.height);
    io::printfn("Format: %s", img.format); // RGB or GRAYSCALE

    char[] pixels = img.pixels;
}
```

Load from memory

```c3
char[] jpeg_data = /* ... */;
Image img = jpeg::load_bytes(jpeg_data)!!;
defer img.free();
```

## Limitations

### PNG
- No interlaced PNG support (Adam7)
- No 1/2/4-bit depth support

### JPEG
- 8-bit precision only (no 12-bit)
- 1 or 3 components only (no CMYK / Adobe transform)
- Sampling factors must be 1 or 2 per axis
- No EXIF orientation or ICC profile handling
- Decode only (no encoding)

---

> **KTX2 / GPU textures** KTX2 support has moved to its own library:
> [tonis2/ktx.c3](https://github.com/tonis2/ktx.c3)