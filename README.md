# image.c3

An image decoding library for C3 supporting PNG, JPEG, and KTX2 formats.

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

### KTX2
- Khronos Texture format for GPU textures
- Mipmap support
- Supercompression: None, ZLIB
- Pass-through for GPU-compressed formats (ASTC, BC, ETC2)
- Direct VkFormat values for Vulkan integration

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

### KTX2

```c3
import image::ktx;

fn void main() {
    KtxImage img = ktx::load_file("texture.ktx2")!!;
    defer img.free();

    io::printfn("Size: %dx%d", img.width, img.height);
    io::printfn("VkFormat: %d", img.vk_format);
    io::printfn("Mip levels: %d", img.mip_levels);

    // Access base mip level
    MipLevel* level = img.get_level(0);
    char[] data = level.data;

    // Check if GPU-compressed (ASTC/BC/ETC2)
    if (img.is_gpu_compressed()) {
        // Pass data directly to Vulkan
    }
}
```

### GPU Compressed Formats

The library supports loading GPU-compressed textures that can be uploaded directly to Vulkan without CPU-side decoding:

| Format | Use Case | VkFormat Range |
|--------|----------|----------------|
| BC1-BC7 | Desktop GPUs (NVIDIA, AMD, Intel) | 131-146 |
| ETC2/EAC | Android, OpenGL ES 3.0+ | 147-158 |
| ASTC | Modern mobile, Apple Silicon | 159-184 |

```c3
import image::ktx;

fn void upload_to_vulkan() {
    KtxImage img = ktx::load_file("texture.ktx2")!!;
    defer img.free();

    // Get compression info
    CompressionType comp = img.compression_type();  // BC, ETC2, ASTC, or NONE
    uint[<2>] block_dim = img.block_dimensions();   // e.g., {4, 4}
    uint block_size = img.block_size();             // bytes per block

    // Calculate buffer size for Vulkan
    usz data_size = img.calculate_level_size(0);

    // The vk_format can be cast directly to VkFormat
    VkFormat format = (VkFormat)img.vk_format;

    // Upload each mip level
    for (uint i = 0; i < img.mip_levels; i++) {
        MipLevel* mip = img.get_level(i);
        // mip.data contains compressed blocks ready for GPU
    }
}
```

Load from memory

```c3
char[] ktx_data = /* ... */;
KtxImage tex = ktx::load_bytes(ktx_data)!!;
defer tex.free();
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

### KTX2
- No Basis Universal transcoding (BasisLZ supercompression)
- No Zstd supercompression
- Decode only (no encoding)
