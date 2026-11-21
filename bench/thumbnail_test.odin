package bench

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import "../src/library"
import "../src/media"
import "../src/thumbnail"
import libwebp "../src/vendor/libwebp"

MINIMAL_PDF :: `%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 400] >> endobj
xref
0 4
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
trailer << /Size 4 /Root 1 0 R >>
startxref
186
%%EOF
`

@(test)
thumbnail_throughput_by_format :: proc(t: ^testing.T) {
	root, tmp_err := os.make_directory_temp("", "booru-thumb-bench-*", context.allocator)
	if !testing.expect(t, tmp_err == nil, "create temp dir") {return}
	defer delete(root)
	defer os.remove_all(root)

	images_dir := fmt.tprintf("%s/images", root)
	if !testing.expect(
		t,
		os.mkdir_all(images_dir, os.Permissions_Default_Directory) == nil,
		"create images dir",
	) {return}

	state := library.State {
		library_path = root,
	}

	Row :: struct {
		format:        string,
		ext:           string,
		file_bytes:    i64,
		pixels:        i64,
		iters:         int,
		imgs_per_sec:  f64,
		bytes_per_sec: f64,
		mpix_per_sec:  f64,
	}
	rows := make([dynamic]Row)
	defer delete(rows)

	sink: int
	item_id := 1
	for format in media.Format {
		ext := media.extension(format)
		src_path := fmt.tprintf("%s/%d.%s", images_dir, item_id, ext)
		ok := false

		switch format {
		case .Unknown, .WINURL:
			continue
		case .PNG:
			ok = gen_ffmpeg_image(src_path, "png")
		case .JPEG:
			ok = gen_ffmpeg_image(src_path, "mjpeg")
		case .GIF:
			ok = gen_ffmpeg_image(src_path, "gif")
		case .WebP:
			ok = gen_webp_image(src_path)
		case .AVIF:
			ok = copy_fixture("test/fixture/media/thumbnail.avif", src_path)
		case .JXL:
			ok = copy_fixture("test/fixture/media/thumbnail.jxl", src_path)
		case .PDF:
			ok = os.write_entire_file(src_path, transmute([]u8)string(MINIMAL_PDF)) == nil
		case .AVI:
			ok = gen_ffmpeg_video(src_path, {"-f", "avi", "-c:v", "mpeg4"})
		case .FLV:
			ok = gen_ffmpeg_video(src_path, {"-f", "flv", "-c:v", "flv"})
		case .OGV:
			ok = gen_ffmpeg_video(src_path, {"-f", "ogv", "-c:v", "libtheora"})
		case .MPG:
			ok = gen_ffmpeg_video(src_path, {"-f", "mpeg", "-c:v", "mpeg1video"})
		case .MPV:
			ok = gen_ffmpeg_video(src_path, {"-f", "mpeg1video", "-c:v", "mpeg1video"})
		case .WMV:
			ok = gen_ffmpeg_video(src_path, {"-f", "asf", "-c:v", "wmv2"})
		case .MOV:
			ok = gen_ffmpeg_video(src_path, {"-f", "mov", "-c:v", "mpeg4"})
		case .ThreeGP:
			ok = gen_ffmpeg_video(src_path, {"-f", "3gp", "-c:v", "mpeg4", "-s", "176x144"})
		case .M4V:
			ok = gen_ffmpeg_video(src_path, {"-f", "ipod", "-c:v", "mpeg4"})
		case .MP4:
			ok = gen_ffmpeg_video(src_path, {"-f", "mp4", "-c:v", "libx264"})
		case .WebM:
			ok = gen_ffmpeg_video(src_path, {"-f", "webm", "-c:v", "libvpx"})
		case .MKV:
			ok = gen_ffmpeg_video(src_path, {"-f", "matroska", "-c:v", "mpeg4"})
		}

		if !testing.expect(
			t,
			ok,
			fmt.tprintf("prepare benchmark sample for %v (%s)", format, ext),
		) {
			item_id += 1
			continue
		}

		detected, sniff_err := media.hack_sniff_first_32_bytes(src_path)
		if !testing.expect(
			t,
			sniff_err == nil && detected == format,
			fmt.tprintf("sniff %v: got %v (%v)", format, detected, sniff_err),
		) {
			item_id += 1
			continue
		}

		fi, size_err := os.stat(src_path, context.temp_allocator)
		file_size := fi.size
		if !testing.expect(t, size_err == nil && file_size > 0, "read sample size") {
			item_id += 1
			continue
		}

		sample_frame, decode_err := media.decode_frame(
			src_path,
			thumbnail.MAX_THUMBNAIL_SOURCE_PIXELS,
		)
		pixels := frame_pixels(sample_frame)
		media.free_decoded(&sample_frame)
		if !testing.expect(
			t,
			decode_err == .None && pixels > 0,
			fmt.tprintf("probe pixels %v: %v", format, decode_err),
		) {
			item_id += 1
			continue
		}

		img := library.Image {
			id  = item_id,
			oid = fmt.tprintf("bench-%s", ext),
			ext = ext,
		}
		sizes := bit_set[thumbnail.LOD_RESOLUTION]{.x64, .x128}

		// Warmup
		for _ in 0 ..< 2 {
			gen, failed := thumbnail.force_generate_image_thumbnails(state, img, sizes)
			if !testing.expect(
				t,
				gen == 2 && failed == 0,
				fmt.tprintf("warmup %v: gen=%d failed=%d", format, gen, failed),
			) {
				break
			}
			intrinsics.volatile_store(&sink, gen)
		}

		min_iters :: 5
		max_iters :: 500
		target_ns :: 250 * time.Millisecond

		iters := 0
		start := time.tick_now()
		for iters < max_iters {
			gen, failed := thumbnail.force_generate_image_thumbnails(state, img, sizes)
			if failed != 0 || gen != 2 {
				testing.expect(
					t,
					false,
					fmt.tprintf("bench %v: gen=%d failed=%d", format, gen, failed),
				)
				break
			}
			intrinsics.volatile_store(&sink, gen)
			iters += 1
			if iters >= min_iters && time.tick_since(start) >= target_ns {
				break
			}
		}
		elapsed := time.tick_since(start)
		secs := time.duration_seconds(elapsed)
		if secs <= 0 {secs = 1e-9}

		imgs_per_sec := f64(iters) / secs
		append(
			&rows,
			Row {
				format = fmt.tprint(format),
				ext = ext,
				file_bytes = file_size,
				pixels = pixels,
				iters = iters,
				imgs_per_sec = imgs_per_sec,
				bytes_per_sec = f64(i64(iters) * file_size) / secs,
				mpix_per_sec = imgs_per_sec * f64(pixels) / 1e6,
			},
		)
		item_id += 1
	}

	fmt.println()
	fmt.printfln(
		"%-8s  %-5s  %10s  %6s  %10s  %14s  %10s",
		"FORMAT",
		"EXT",
		"SIZE(B)",
		"ITERS",
		"IMG/S",
		"BYTES/S",
		"MPix/S",
	)
	fmt.printfln(
		"%-8s  %-5s  %10s  %6s  %10s  %14s  %10s",
		"--------",
		"-----",
		"----------",
		"------",
		"----------",
		"--------------",
		"----------",
	)
	for r in rows {
		fmt.printfln(
			"%-8s  %-5s  %10d  %6d  %10.2f  %14.0f  %10.2f",
			r.format,
			r.ext,
			r.file_bytes,
			r.iters,
			r.imgs_per_sec,
			r.bytes_per_sec,
			r.mpix_per_sec,
		)
	}
}

@(private = "file")
frame_pixels :: proc(frame: media.Decoded_Frame) -> i64 {
	switch f in frame {
	case media.Decoded_ARGB:
		return i64(f.width) * i64(f.height)
	case media.Decoded_YUV:
		return i64(f.width) * i64(f.height)
	case media.Decoded_RGB24:
		return i64(f.width) * i64(f.height)
	}
	return 0
}

@(private = "file")
copy_fixture :: proc(src, dst: string) -> bool {
	data, err := os.read_entire_file(src, context.temp_allocator)
	if err != nil {return false}
	return os.write_entire_file(dst, data) == nil
}

@(private = "file")
gen_webp_image :: proc(dst: string) -> bool {
	w, h :: 256, 256
	pixels := make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := (y * w + x) * 4
			pixels[i + 0] = u8(x)
			pixels[i + 1] = u8(y)
			pixels[i + 2] = u8((x + y) / 2)
			pixels[i + 3] = 255
		}
	}
	file, open_err := os.open(dst, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_err != nil {return false}
	defer os.close(file)

	pic: libwebp.WebPPicture
	if libwebp.WebPPictureInitInternal(&pic, 0x0210) == 0 {return false}
	defer libwebp.WebPPictureFree(&pic)
	pic.width, pic.height = w, h
	pic.use_argb = 1
	if libwebp.WebPPictureImportRGBA(&pic, raw_data(pixels), w * 4) == 0 {return false}
	return libwebp.rescale(&pic, file, w)
}

@(private = "file")
gen_ffmpeg_image :: proc(dst: string, vcodec: string) -> bool {
	cmd := [?]string {
		"ffmpeg",
		"-loglevel",
		"error",
		"-y",
		"-f",
		"lavfi",
		"-i",
		"testsrc=size=256x256:rate=1",
		"-frames:v",
		"1",
		"-c:v",
		vcodec,
		dst,
	}
	return run_cmd(cmd[:])
}

@(private = "file")
gen_ffmpeg_video :: proc(dst: string, extra: []string) -> bool {
	args := make([dynamic]string, 0, 16 + len(extra), context.temp_allocator)
	append(
		&args,
		"ffmpeg",
		"-loglevel",
		"error",
		"-y",
		"-f",
		"lavfi",
		"-i",
		"testsrc=size=256x256:rate=25",
		"-t",
		"0.2",
		"-pix_fmt",
		"yuv420p",
	)
	append(&args, ..extra)
	append(&args, dst)
	return run_cmd(args[:])
}

@(private = "file")
run_cmd :: proc(cmd: []string) -> bool {
	state, _, _, err := os.process_exec({command = cmd}, context.temp_allocator)
	return err == nil && state.exit_code == 0
}
