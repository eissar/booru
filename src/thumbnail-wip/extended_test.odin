package thumbnail

import "core:bytes"
import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"

WEBP_TEST_DATA_DIR :: ".test-data/libwebp"

clone_webp_test_data :: proc() {
	if os.exists(WEBP_TEST_DATA_DIR + "/.git") {return}
	state, stdout, stderr, err := os.process_exec(
		{
			command = {
				"git",
				"clone",
				"https://github.com/webmproject/libwebp-test-data",
				WEBP_TEST_DATA_DIR,
			},
		},
		context.temp_allocator,
	)
	if err != nil || !state.success || state.exit_code != 0 {
		panic(fmt.tprintf("git clone failed: %v\n%s\n%s", err, stdout, stderr))
	}
}

// Requires libwebp (input encoding) and webpinfo (output validation).
foreign import webp "system:webp"

foreign webp {
	WebPEncodeRGB :: proc(rgb: ^u8, width, height, stride: c.int, quality: c.float, output: ^^u8) -> c.size_t ---
	WebPFree :: proc(p: rawptr) ---
}

@(test)
vectorized_webp_extended_riff_size :: proc(t: ^testing.T) {
	// Complete 1x1 red, lossy WebP.
	sample := []u8 {
		82,
		73,
		70,
		70,
		60,
		0,
		0,
		0,
		87,
		69,
		66,
		80,
		86,
		80,
		56,
		32,
		48,
		0,
		0,
		0,
		208,
		1,
		0,
		157,
		1,
		42,
		1,
		0,
		1,
		0,
		2,
		0,
		52,
		37,
		160,
		2,
		116,
		186,
		1,
		248,
		0,
		3,
		176,
		0,
		254,
		240,
		196,
		11,
		255,
		32,
		185,
		97,
		117,
		200,
		215,
		255,
		32,
		63,
		228,
		7,
		252,
		128,
		255,
		248,
		242,
		0,
		0,
		0,
	}
	thumbs := [1]Thumb{{bytes = sample, width = 1, height = 1}}
	storage: [12][]u8
	vec := storage[:]
	newThumbnailAtlas(thumbs[:], storage[:], context.temp_allocator)

	expected := []u8{116, 0, 0, 0}
	actual := vec[0][4:8]
	if !testing.expect(
		t,
		bytes.equal(actual, expected),
		"extended RIFF size matches expected bytes",
	) {
		when ODIN_DEBUG {
			dump_hex("expected RIFF size", expected)
			dump_hex("actual RIFF size", actual)
			dump_hex("webp section:", vec[0])
		}
	}
}

@(test)
vectorized_webp_extended_validates :: proc(t: ^testing.T) {
	pixel := [3]u8{255, 0, 0}
	encoded: ^u8
	size := WebPEncodeRGB(&pixel[0], 1, 1, 3, 75, &encoded)
	if !testing.expect(t, size > 0 && encoded != nil, "encode input thumbnail") {return}
	defer WebPFree(encoded)

	thumbs := [1]Thumb{{bytes = (cast([^]u8)encoded)[:int(size)], width = 1, height = 1}}
	storage: [12][]u8
	newThumbnailAtlas(thumbs[:], storage[:], context.temp_allocator)
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	for segment in storage {
		bytes.buffer_write(&buf, segment)
	}

	path :: ".test-data/extended.webp"
	// mkdir_all reports Exist when the directory is already there, which is the
	// normal case on a second run.
	if err := os.mkdir_all(".test-data"); err != nil && err != os.General_Error.Exist {
		if !testing.expect(t, false, "create output directory") {return}
	}
	if !testing.expect(
		t,
		os.write_entire_file(path, bytes.buffer_to_bytes(&buf)) == nil,
		"write WebP",
	) {return}
	state, stdout, stderr, err := os.process_exec(
		{command = {"webpinfo", "-diag", "-bitstream_info", path}},
		context.temp_allocator,
	)
	fmt.printf("%s%s", stdout, stderr)
	testing.expect(
		t,
		err == nil && state.success && state.exit_code == 0,
		"webpinfo accepts generated animation",
	)
}
