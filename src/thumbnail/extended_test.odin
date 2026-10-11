package thumbnail

import "core:bytes"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"

import "../cli"
import "../library"

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
vectorized_webp_extended_validates :: proc(t: ^testing.T) {
	pixel := [3]u8{255, 0, 0}
	encoded: ^u8
	size := WebPEncodeRGB(&pixel[0], 1, 1, 3, 75, &encoded)
	if !testing.expect(t, size > 0 && encoded != nil, "encode input thumbnail") {return}
	defer WebPFree(encoded)

	thumbs := [1]Thumb{{bytes = (cast([^]u8)encoded)[:int(size)], width = 1, height = 1}}
	segments := Thumbnail_MipMap(thumbs[:], context.temp_allocator)
	defer delete(segments, context.temp_allocator)
	data := bytes.join(segments, nil, context.temp_allocator)
	defer delete(data, context.temp_allocator)

	path :: ".test-data/extended.webp"
	// mkdir_all reports Exist when the directory is already there, which is the
	// normal case on a second run.
	if err := os.mkdir_all(".test-data"); err != nil && err != os.General_Error.Exist {
		if !testing.expect(t, false, "create output directory") {return}
	}
	if !testing.expect(t, os.write_entire_file(path, data) == nil, "write WebP") {return}
	state, stdout, stderr, err := os.process_exec(
		{command = {"webpinfo", "-diag", "-bitstream_info", path}},
		context.temp_allocator,
	)
	if !testing.expect(
		t,
		err == nil && state.success && state.exit_code == 0,
		"webpinfo accepts generated animation",
	) {
		fmt.printf("%s%s", stdout, stderr)
	}
}

@(test)
vectorized_webp_extended_length :: proc(t: ^testing.T) {
	cfg := cli.getFlags()
	root := cfg.library // alias


	backing := make([]u8, 512 * mem.Megabyte)
	defer delete(backing)

	arena: mem.Arena
	mem.arena_init(&arena, backing)

	alloc := mem.arena_allocator(&arena)

	imgs := make([dynamic]library.Image, alloc)
	defer delete(imgs)

	library.load_library(cfg.library, &imgs, alloc)
	defer free_all(alloc)

	input_streams := make([]Thumb, 1, alloc)
	defer delete(input_streams, alloc)

	p := fmt.aprintf(
		"%v/thumbnails/%v.webp",
		root,
		imgs[0].oid,
		allocator = context.temp_allocator,
	)

	t_bytes, _ := os.read_entire_file(p, alloc)


	input_streams[0] = Thumb{t_bytes, u16le(imgs[0].height), u16le(imgs[0].width)}

	vec_dat := Thumbnail_MipMap(input_streams, context.allocator)
	vec_dat_len := 0
	for v in vec_dat {vec_dat_len += len(v)}

	// fmt.println(vec_dat[0][4:8])
	// fmt.printf("vec_dat_len %v\n", vec_dat_len)

}
