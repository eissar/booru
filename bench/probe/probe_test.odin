package probe_bench

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import "../../src/media"
import libwebp "../../src/vendor/libwebp"

@(test)
probe_dimensions_by_format :: proc(t: ^testing.T) {
	root, tmp_err := os.make_directory_temp("", "booru-probe-bench-*", context.allocator)
	if !testing.expect(t, tmp_err == nil, "create temp dir") {return}
	defer delete(root)
	defer os.remove_all(root)

	Row :: struct {
		format:        string,
		ext:           string,
		file_bytes:    i64,
		width:         c.int,
		height:        c.int,
		iters:         int,
		files_per_sec: f64,
		us_per_op:     f64,
		bytes_per_sec: f64,
	}
	rows := make([dynamic]Row)
	defer delete(rows)

	sink: int
	item_id := 1
	for format in media.Format {
		ext := media.extension(format)
		src_path := fmt.tprintf("%s/%d.%s", root, item_id, ext)
		ok := false

		switch format {
		case .Unknown:
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

		data, read_err := os.read_entire_file(src_path, context.temp_allocator)
		if !testing.expect(t, read_err == nil && len(data) > 0, "read sample bytes") {
			item_id += 1
			continue
		}

		// Warmup
		w, h: c.int
		for _ in 0 ..< 2 {
			probe_ok: bool
			w, h, probe_ok = media.probe_dimensions(data, format, src_path)
			if !testing.expect(
				t,
				probe_ok && w > 0 && h > 0,
				fmt.tprintf("warmup probe %v: ok=%v %dx%d", format, probe_ok, w, h),
			) {
				break
			}
			intrinsics.volatile_store(&sink, int(w) * 10000 + int(h))
		}

		min_iters :: 5
		max_iters :: 5000
		target_ns :: 250 * time.Millisecond

		iters := 0
		start := time.tick_now()
		for iters < max_iters {
			pw, ph, probe_ok := media.probe_dimensions(data, format, src_path)
			if !probe_ok || pw <= 0 || ph <= 0 {
				testing.expect(
					t,
					false,
					fmt.tprintf("bench probe %v: ok=%v %dx%d", format, probe_ok, pw, ph),
				)
				break
			}
			intrinsics.volatile_store(&sink, int(pw) * 10000 + int(ph))
			iters += 1
			if iters >= min_iters && time.tick_since(start) >= target_ns {
				break
			}
		}
		elapsed := time.tick_since(start)
		secs := time.duration_seconds(elapsed)
		if secs <= 0 {secs = 1e-9}

		files_per_sec := f64(iters) / secs
		append(
			&rows,
			Row {
				format = fmt.tprint(format),
				ext = ext,
				file_bytes = i64(len(data)),
				width = w,
				height = h,
				iters = iters,
				files_per_sec = files_per_sec,
				us_per_op = secs * 1e6 / f64(iters),
				bytes_per_sec = f64(i64(iters) * i64(len(data))) / secs,
			},
		)
		item_id += 1
	}

	fmt.println()
	fmt.printfln(
		"%-8s  %-5s  %10s  %4s  %4s  %6s  %12s  %10s  %14s",
		"FORMAT",
		"EXT",
		"SIZE(B)",
		"W",
		"H",
		"ITERS",
		"FILES/S",
		"us/OP",
		"BYTES/S",
	)
	fmt.printfln(
		"%-8s  %-5s  %10s  %4s  %4s  %6s  %12s  %10s  %14s",
		"--------",
		"-----",
		"----------",
		"----",
		"----",
		"------",
		"------------",
		"----------",
		"--------------",
	)
	for r in rows {
		fmt.printfln(
			"%-8s  %-5s  %10d  %4d  %4d  %6d  %12.2f  %10.2f  %14.0f",
			r.format,
			r.ext,
			r.file_bytes,
			r.width,
			r.height,
			r.iters,
			r.files_per_sec,
			r.us_per_op,
			r.bytes_per_sec,
		)
	}
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
