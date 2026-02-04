// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate::pkgmerge;
import std::sort, std::collections::list;

struct IndexMap @private (Printable)
{
	usz index;
	uint freq;
}
fn bool IndexMap.less(&self, IndexMap other) => self.freq < other.freq;

<*
 Compute length-limited prefix code lengths based on Larmore/Hirschberg's
 package-merge algorithm.

 Based on the C implementation by Stephan Brumme [1].

 [1] https://create.stephan-brumme.com/length-limited-prefix-codes/
*>
fn char[] codelen(Allocator allocator, uint[] freqs, uint max_bits) => @pool()
{
	List{IndexMap} map;
	map.tinit();

	// Use only non-zero frequencies.
	usz n;
	foreach (i, freq: freqs)
	{
		if (freq == 0) continue;
		map.push({i, freq});
		n++;
	}

	if (n == 0) return {};

	// Sort frequencies in ascending order.
	sort::quicksort(map.array_view());

	uint[] hist = mem::temp_array(uint, n);
	foreach (i, m: map) hist[i] = m.freq;


	// One or two codes are encoded with a single bit.
	// if (n <= 2)
	if (n <= 1)//  FIXME
	{
		char[] blen = allocator::new_array(allocator, char, freqs.len);
		foreach (m:map) blen[m.index] = 1;
		return blen;
	}

	// Require two scratch buffers to process iterations and some bitmasks.
	usz max_elements = 2 * n;
	uint[] current = mem::temp_array(uint, max_elements);
	uint[] previous = mem::temp_array(uint, max_elements);
	ulong[] is_merged = mem::temp_array(ulong, max_elements);

	// Initial value of "previous" is the histogram.
	previous[:n] = hist[:n];
	usz num_previous = n;

	// Keep track which packages are merged in a compact bit masks.
	// If package p was merged in iteration i,
	// then (is_merged[p] & (1<<i)) != 0
	is_merged[:max_elements] = 0;

	// Last 2 packages are irrelevant.
	usz num_relevant = 2 * n - 2;

	ulong mask = 1;
	uint bits;
	for (bits = max_bits - 1; bits > 0; bits--)
	{
		num_previous &= ~1;

		current[0] = hist[0];
		current[1] = hist[1];
		uint sum = current[0] + current[1];

		// Copy histogram and insert merged sums.
		usz num_current = 2;
		usz num_hist = num_current;
		usz num_merged = 0;

		while (true)
		{
			if (num_hist < n && hist[num_hist] <= sum)
			{
				current[num_current++] = hist[num_hist++];
				continue;
			}

			is_merged[num_current] |= mask;
			current[num_current] = sum;
			num_current++;

			num_merged++;
			if (num_merged * 2 >= num_previous) break;

			sum = previous[num_merged * 2] + previous[num_merged * 2 + 1];
		}

		while (num_hist < n) current[num_current++] = hist[num_hist++];

		mask <<= 1;

		if (num_previous >= num_relevant)
		{
			char keep_going = 0;
			for (usz i = num_relevant - 1; i > 0; i--)
			{
				if (previous[i] != current[i])
				{
					keep_going++;
					break;
				}
			}
			if (keep_going == 0) break;
		}

		// Swap previous and current arrays.
		@swap(previous, current);

		num_previous = num_current;
	}

	mask >>= 1;

	// Reuse hist array for code lengths.
	hist[..] = 0;

	usz num_analyze = num_relevant;
	while (mask != 0)
	{
		usz num_merged = 0;
		hist[0]++;
		hist[1]++;

		usz symbol = 2;
		for (usz i = symbol; i < num_analyze; i++)
		{
			if ((is_merged[i] & mask) == 0)
			{
				hist[symbol]++;
				symbol++;
			}
			else
			{
				num_merged++;
			}
		}

		num_analyze = 2 * num_merged;

		mask >>= 1;
	}

	// Last iterations can't have any merges.
	for (usz i = 0; i < num_analyze; i++) hist[i]++;

	// Remap to correct indices.
	char[] blen = allocator::new_array(allocator, char, freqs.len);
	foreach (i, m: map)
	{
		blen[m.index] = (char)hist[i];
	}

	return blen;
}

fn void test_pkgmerge_codelen() @test => @pool()
{
	uint[] freqs = {2,3,1,1};
	char[] blen = codelen(tmem, freqs, 3);
	assert(freqs.len == blen.len);
	assert(blen == {2,1,3,3});
}

