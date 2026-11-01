module image::mp4::check;
import image;
import image::mp4;
import image::h264;
import std::io;
import std::io::file;

// How many samples differ from ffmpeg's yuv420p dump `raw`, frame by frame in order.
fn usz differences(mp4::Video* v, char[] raw, usz k)
{
	h264::Picture* p = v.picture(k)!!;
	uint w = p.shown_width();
	uint h = p.shown_height();
	uint cw = (w + 1) / 2;
	uint ch = (h + 1) / 2;
	usz size = (usz)w * h + 2 * (usz)cw * ch;
	char[] want = raw[k * size:size];
	usz bad;
	for (uint y = 0; y < h; y++)
	{
		for (uint x = 0; x < w; x++)
		{
			char got = p.y[(usz)(y + p.crop_top) * p.width + x + p.crop_left];
			if (got != want[(usz)y * w + x])
			{
				if (bad == 0) io::printfn("frame %d: Y differs first at %d,%d (%d, want %d)", k, x, y, got, want[(usz)y * w + x]);
				bad++;
			}
		}
	}
	for (uint c = 0; c < 2; c++)
	{
		char[] plane = c == 0 ? p.u : p.v;
		usz base = (usz)w * h + c * (usz)cw * ch;
		for (uint y = 0; y < ch; y++)
		{
			for (uint x = 0; x < cw; x++)
			{
				char got = plane[(usz)(y + p.crop_top / 2) * (p.width / 2) + x + p.crop_left / 2];
				if (got != want[base + (usz)y * cw + x])
				{
					if (bad == 0) io::printfn("frame %d: %s differs first at %d,%d", k, c == 0 ? "U" : "V", x, y);
					bad++;
				}
			}
		}
	}
	return bad;
}

fn void matches(String video, String dump, uint width, uint height, usz frames)
{
	char[] raw = file::load(mem, dump)!!;
	defer alloc::free(mem, raw);
	mp4::Video v = mp4::open(video)!!;
	defer v.close();
	assert(v.width == width && v.height == height, "size %dx%d", v.width, v.height);
	assert(v.frames == frames, "%d frames", v.frames);
	assert(v.fps > 23.9 && v.fps < 24.1, "fps %f", v.fps);
	for (usz k = 0; k < frames; k++)
	{
		usz bad = differences(&v, raw, k);
		assert(bad == 0, "%s frame %d: %d samples differ", video, k, bad);
	}
	// Back to the start, and a jump past a sync frame, decode the same.
	assert(differences(&v, raw, 0) == 0);
	assert(differences(&v, raw, frames - 1) == 0);
}

module image::mp4::test @test;
import image;
import image::mp4;
import image::h264;
import image::mp4::check;

fn void mp4_baseline_matches_ffmpeg()
{
	check::matches("test/baseline_96x64.mp4", "test/baseline_96x64.yuv", 96, 64, 12);
}

fn void mp4_cropped_constrained_intra_matches_ffmpeg()
{
	check::matches("test/crop_70x46.mp4", "test/crop_70x46.yuv", 70, 46, 8);
}

fn void mp4_frame_is_rgb()
{
	mp4::Video v = mp4::open("test/crop_70x46.mp4")!!;
	defer v.close();
	Image img = v.frame(3)!!;
	defer img.free();
	assert(img.width == 70 && img.height == 46 && img.format == RGB && img.pixels.len == 70 * 46 * 3);
}

fn void mp4_high_profile_is_refused()
{
	if (catch err = mp4::open("test/high_64x48.mp4"))
	{
		assert(err == h264::CABAC || err == h264::B_SLICES || err == h264::TRANSFORM_8X8, "refused with %s", err);
		assert(mp4::reason(err).starts_with("High-profile"));
		return;
	}
	assert(false, "a High-profile stream opened");
}

fn void mp4_not_a_video_is_refused()
{
	assert(@catch(mp4::open("test/test_rgb.png")) == mp4::NOT_MP4);
}
