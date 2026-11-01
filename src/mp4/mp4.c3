<*
 MP4 (and QuickTime .mov) video: the first video track's samples, read from
 the file as they are needed and decoded with image::h264.
*>
module image::mp4;
import image;
import image::h264;
import std::io;
import std::io::file;
import std::math;

excuse NOT_MP4, NO_VIDEO, NOT_H264, CORRUPT, NO_FRAME;

struct Video
{
	uint width;
	uint height;
	usz frames;
	float fps;
	char[4] codec;  // the sample entry's type, e.g. "avc1", "hvc1"

	Allocator allocator;
	File file;
	ulong[] offsets;
	uint[] sizes;
	usz[] syncs;     // sync sample indices, ascending; empty = every sample
	h264::Decoder decoder;
	char[] sample;   // read buffer, sized for the largest sample
	sz decoded;      // the last sample decoded; -1 none
	h264::Picture* current;
}

fn uint be32(char[] d, usz at) @inline @private => bitorder::read(d[at:4], UIntBE);
fn ulong be64(char[] d, usz at) @inline @private => bitorder::read(d[at:8], ULongBE);

// The child box `type` of the box body `data`; empty when it isn't there.
fn char[] child(char[] data, String type) @private
{
	usz at = 0;
	while (at + 8 <= data.len)
	{
		ulong size = be32(data, at);
		usz head = 8;
		if (size == 1)
		{
			if (at + 16 > data.len) return {};
			size = be64(data, at + 8);
			head = 16;
		}
		else if (size == 0)
		{
			size = data.len - at;
		}
		if (size < head || size > data.len - at) return {};
		if ((String)data[at + 4:4] == type) return data[at + head:(usz)size - head];
		at += (usz)size;
	}
	return {};
}

<*
 Open a video file and read its first H.264 video track's sample tables.

 @return "The open video; release it with Video.close"
 @return? NOT_MP4, NO_VIDEO, NOT_H264, CORRUPT, h264::Decoder.configure!
*>
fn Video? open(String path, Allocator allocator = mem)
{
	File f = file::open(path, "rb") ?? NOT_MP4~!;
	Video v = { .allocator = allocator, .file = f, .decoded = -1 };
	if (catch err = v.read_moov(allocator))
	{
		v.close();
		return err~;
	}
	return v;
}

fn void? Video.read_moov(&self, Allocator allocator)
{
	long size = self.file.size()!;
	long at = 0;
	char[16] head;
	char[] moov;
	defer if (moov.len > 0) alloc::free(allocator, moov);
	while (at + 8 <= size)
	{
		self.file.seek(at)!;
		sz got = self.file.read(head[:16])!;
		if (got < 8) break;
		ulong box = be32(head[..], 0);
		long body = 8;
		if (box == 1)
		{
			if (got < 16) return NOT_MP4~;
			box = be64(head[..], 8);
			body = 16;
		}
		else if (box == 0)
		{
			box = (ulong)(size - at);
		}
		String type = (String)head[4:4];
		if (at == 0 && type != "ftyp" && type != "moov" && type != "wide" && type != "mdat" && type != "free") return NOT_MP4~;
		if (box < (ulong)body || (long)box > size - at) return CORRUPT~;
		if (type == "moov")
		{
			if (box > 256 * 1024 * 1024) return CORRUPT~;
			moov = alloc::new_array(allocator, char, (sz)box - (sz)body);
			self.file.seek(at + body)!;
			if ((usz)self.file.read(moov)! != moov.len) return CORRUPT~;
			break;
		}
		at += (long)box;
	}
	if (moov.len == 0) return NOT_MP4~;

	// The first track whose handler is 'vide'.
	usz pos = 0;
	while (pos + 8 <= moov.len)
	{
		usz box = be32(moov, pos);
		if (box < 8 || box > moov.len - pos) return CORRUPT~;
		if ((String)moov[pos + 4:4] == "trak")
		{
			char[] mdia = child(moov[pos + 8:box - 8], "mdia");
			char[] hdlr = child(mdia, "hdlr");
			if (hdlr.len >= 12 && (String)hdlr[8:4] == "vide") return self.read_track(mdia);
		}
		pos += box;
	}
	return NO_VIDEO~;
}

fn void? Video.read_track(&self, char[] mdia)
{
	char[] mdhd = child(mdia, "mdhd");
	if (mdhd.len < 24) return CORRUPT~;
	uint timescale = mdhd[0] == 1 ? be32(mdhd, 20) : be32(mdhd, 12);
	char[] stbl = child(child(mdia, "minf"), "stbl");
	char[] stsd = child(stbl, "stsd");
	if (stsd.len < 16 + 78) return CORRUPT~;
	char[] entry = stsd[8..];
	usz entry_size = be32(entry, 0);
	if (entry_size < 86 || entry_size > entry.len) return CORRUPT~;
	self.codec[..] = entry[4:4];
	String codec = (String)entry[4:4];
	if (codec != "avc1" && codec != "avc3") return NOT_H264~;
	self.width = (uint)entry[32] << 8 | entry[33];
	self.height = (uint)entry[34] << 8 | entry[35];
	char[] avcc = child(entry[86:entry_size - 86], "avcC");
	if (avcc.len == 0) return NOT_H264~;

	char[] stsz = child(stbl, "stsz");
	if (stsz.len < 12) return CORRUPT~;
	uint fixed = be32(stsz, 4);
	usz count = be32(stsz, 8);
	if (fixed == 0 && stsz.len < 12 + count * 4) return CORRUPT~;
	if (count == 0) return NO_VIDEO~;
	self.frames = count;
	self.sizes = alloc::new_array(self.allocator, uint, (sz)count);
	uint largest;
	foreach (i, &size : self.sizes)
	{
		*size = fixed != 0 ? fixed : be32(stsz, 12 + (usz)i * 4);
		largest = math::max(largest, *size);
	}

	// Chunk offsets, and how many samples each chunk holds (stsc runs).
	char[] stco = child(stbl, "stco");
	char[] co64 = child(stbl, "co64");
	bool wide = stco.len == 0;
	char[] table = wide ? co64 : stco;
	if (table.len < 8) return CORRUPT~;
	usz chunks = be32(table, 4);
	if (table.len < 8 + chunks * (usz)(wide ? 8 : 4)) return CORRUPT~;
	char[] stsc = child(stbl, "stsc");
	if (stsc.len < 8) return CORRUPT~;
	usz runs = be32(stsc, 4);
	if (stsc.len < 8 + runs * 12 || runs == 0) return CORRUPT~;
	self.offsets = alloc::new_array(self.allocator, ulong, (sz)count);
	usz sample;
	for (usz run = 0; run < runs; run++)
	{
		usz first = (usz)be32(stsc, 8 + run * 12) - 1;
		usz last = run + 1 < runs ? (usz)be32(stsc, 8 + (run + 1) * 12) - 1 : chunks;
		uint per = be32(stsc, 8 + run * 12 + 4);
		for (usz c = first; c < last && c < chunks; c++)
		{
			ulong at = wide ? be64(table, 8 + c * 8) : be32(table, 8 + c * 4);
			for (uint k = 0; k < per && sample < count; k++)
			{
				self.offsets[sample] = at;
				at += self.sizes[sample];
				sample++;
			}
		}
	}
	if (sample < count) return CORRUPT~;

	char[] stss = child(stbl, "stss");
	if (stss.len >= 8)
	{
		usz n = be32(stss, 4);
		if (stss.len < 8 + n * 4) return CORRUPT~;
		self.syncs = alloc::new_array(self.allocator, usz, (sz)n);
		for (usz i = 0; i < n; i++) self.syncs[i] = (usz)be32(stss, 8 + i * 4) - 1;
	}

	// The commonest frame duration gives the rate.
	char[] stts = child(stbl, "stts");
	if (stts.len >= 8 && timescale > 0)
	{
		usz n = be32(stts, 4);
		uint most;
		uint delta;
		for (usz i = 0; i < n && 16 + i * 8 <= stts.len; i++)
		{
			uint c = be32(stts, 8 + i * 8);
			if (c > most)
			{
				most = c;
				delta = be32(stts, 12 + i * 8);
			}
		}
		if (delta > 0) self.fps = (float)timescale / (float)delta;
	}

	// Reordered frames (B-frames) show up as varying composition offsets.
	char[] ctts = child(stbl, "ctts");
	if (ctts.len >= 8)
	{
		usz n = be32(ctts, 4);
		for (usz i = 1; i < n && 16 + i * 8 <= ctts.len; i++)
		{
			if (be32(ctts, 12 + i * 8) != be32(ctts, 12)) return h264::B_SLICES~;
		}
	}

	self.sample = alloc::new_array(self.allocator, char, largest);
	self.decoder.init(self.allocator);
	self.decoder.configure(avcc)!;
}

<*
 Close the file and free everything the video owns; safe on a partly opened video.
*>
fn void Video.close(&self)
{
	(void)self.file.close();
	if (self.offsets.len > 0) alloc::free(self.allocator, self.offsets);
	if (self.sizes.len > 0) alloc::free(self.allocator, self.sizes);
	if (self.syncs.len > 0) alloc::free(self.allocator, self.syncs);
	if (self.sample.len > 0) alloc::free(self.allocator, self.sample);
	if (self.decoder.allocator) self.decoder.free();
	*self = {};
}

// The last sync sample at or before `k`.
fn usz Video.sync_before(&self, usz k)
{
	if (self.syncs.len == 0) return k;
	usz best = 0;
	foreach (s : self.syncs)
	{
		if (s > k) break;
		best = s;
	}
	return best;
}

<*
 Frame `k` (in file order) as decoded planes, valid until the next call.
 Decodes forward from the last frame, or from the sync frame before `k`.

 @return? NO_FRAME, CORRUPT, h264::Decoder.decode!
*>
fn h264::Picture*? Video.picture(&self, usz k)
{
	if (k >= self.frames) return NO_FRAME~;
	if (self.decoded == (sz)k && self.current) return self.current;
	usz start = (usz)(self.decoded + 1);
	usz sync = self.sync_before(k);
	if (self.decoded < 0 || (sz)k < self.decoded || sync > start)
	{
		self.decoder.reset();
		self.current = null;
		start = sync;
	}
	for (usz i = start; i <= k; i++)
	{
		char[] data = self.sample[:self.sizes[i]];
		self.file.seek((long)self.offsets[i])!;
		if ((usz)self.file.read(data)! != data.len) return CORRUPT~;
		self.decoded = -1;
		h264::Picture* p = self.decoder.decode(data)!;
		if (p) self.current = p;
		self.decoded = (sz)i;
	}
	if (!self.current) return CORRUPT~;
	return self.current;
}

<*
 Frame `k` as an RGB image owned by `allocator`.

 @return? Video.picture!
*>
fn Image? Video.frame(&self, usz k, Allocator allocator = mem) => self.picture(k).to_image(allocator);
