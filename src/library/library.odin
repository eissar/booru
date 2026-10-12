package library

import libwebp "../vendor/libwebp"
import "core:c"

import "core:mem"
import "core:sys/linux"
import "core:testing"
// Library loading: replay NDJSON add-events into an in-memory image list.
// Prototype only -- no derived index, no DB.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"


State :: struct {
	library_path:   string,
	library_images: []Image,
}

Image :: struct {
	id:           int,
	oid:          string,
	path:         string,
	tags:         []string,
	width:        int,
	height:       int,
	name:         string,
	mtime:        string,
	added_at:     string,
	content_type: string,
}

Event :: struct {
	op:          string,
	id:          int,
	oid:         string,
	path:        string,
	tags:        []string,
	width:       int,
	height:      int,
	name:        string,
	mtime:       string,
	addedAt:     string,
	contentType: string,
}


// load library at path root into v
load_library :: proc(root: string, images: ^[dynamic]Image, alloc: mem.Allocator) {
	events_dir := fmt.tprintf("%s/events", root)
	dir_fi, _ := os.stat(events_dir, alloc)
	if dir_fi.type != .Directory {fmt.eprintln("library: cannot open events dir", events_dir)}
	os.file_info_delete(dir_fi, alloc)

	w := os.walker_create(events_dir)
	defer os.walker_destroy(&w)

	for entry in os.walker_walk(&w) {
		if _, err := os.walker_error(&w); err != nil {
			continue
		}

		if !strings.has_suffix(entry.name, ".ndjson") {
			continue
		}

		data, err := os.read_entire_file(entry.fullpath, alloc)
		defer delete(data, alloc)

		if err != nil {
			fmt.eprintln("library: cannot read", entry.fullpath)
			continue
		}
		load_ndjson(images, string(data), alloc)
	}
}

load_ndjson :: proc(images: ^[dynamic]Image, data: string, alloc: mem.Allocator) {
	lines := strings.split(data, "\n", alloc)

	for line in lines {
		if strings.trim_space(line) == "" {continue}
		ev: Event

		if err := json.unmarshal(transmute([]u8)line, &ev, json.DEFAULT_SPECIFICATION, alloc);
		   err != nil {
			fmt.eprintln("library: bad event ", err)
			continue
		}

		if ev.op != "add" {continue}
		append(
			images,
			Image {
				id = ev.id,
				oid = ev.oid,
				path = ev.path,
				tags = ev.tags,
				width = ev.width,
				height = ev.height,
				name = ev.name,
				mtime = ev.mtime,
				added_at = ev.addedAt,
				content_type = ev.contentType,
			},
		)
	}
}

filter_missing_thumbnails :: proc(
	dfd: ^os.File,
	list: ^map[string]bit_set[LOD_RESOLUTION],
	resolution: LOD_RESOLUTION,
) {
	dents_buf: [32 * 1024]u8

	fd := linux.Fd(os.fd(dfd))

	for {
		n, err := linux.getdents(fd, dents_buf[:])
		if err != nil {return}
		if n == 0 {break} 	// end of directory

		offset := 0
		for entry in linux.dirent_iterate_buf(dents_buf[:n], &offset) {
			name := linux.dirent_name(entry)
			if name[0] == '.' {continue} 	// ignore ./../.*

			if !strings.has_suffix(name, ".webp") {continue}
			oid := name[:len(name) - len(".webp")]
			remaining, exists := list^[oid]
			if !exists {continue}
			remaining -= bit_set[LOD_RESOLUTION]{resolution}
			if remaining == {} {
				delete_key(list, oid)
			} else {
				value := &list^[oid]
				value^ = remaining
			}
		}
	}
}

LOD_RESOLUTION :: enum {
	x1024 = 0,
	x512  = 1,
	x256  = 2,
	x128  = 3,
	x64   = 4,
}

find_missing_thumbnails :: proc(s: State, missing: ^map[string]bit_set[LOD_RESOLUTION]) {
	resolutions := make(map[string]LOD_RESOLUTION, allocator = context.temp_allocator)
	defer delete(resolutions)
	resolutions["64"] = .x64
	resolutions["128"] = .x128

	for img in s.library_images {
		missing^[img.oid] = {.x64, .x128}
	}

	for n, r in resolutions {
		pth := fmt.aprintf(
			"%v/thumbnails/%v",
			s.library_path,
			n, // e.g. 64
			allocator = context.temp_allocator,
		)
		fmt.printfln(pth)
		osf, err := os.open(pth, {.Read}, {})
		if err != nil {
			fmt.printfln("err=%v", err)
			continue
		}
		filter_missing_thumbnails(osf, missing, r)
		os.close(osf)
	}

	for n, r in resolutions {
		count := 0
		for _, sizes in missing^ {
			if r in sizes {count += 1}
		}
		fmt.printfln("missing %spx thumbnails: %d", n, count)
	}
}


generate_missing_thumbnails :: proc(t: ^testing.T) {
	lib_path := "/home/eissar/libraries/vp8-benchmark-library"

	imgs := make([dynamic]Image, context.temp_allocator)
	load_library(lib_path, &imgs, context.temp_allocator)

	m := make(map[string]bit_set[LOD_RESOLUTION])
	defer delete(m)
	s := State{lib_path, imgs[:]}
	find_missing_thumbnails(s, &m)

	for oid, sizes in m {
		data, err := os.read_entire_file(
			fmt.tprintf("%s/images/%s", lib_path, oid),
			context.temp_allocator,
		)
		if !testing.expectf(t, err == nil, "read %s", oid) {continue}

		w, h, stride, uv_stride: c.int
		u, v: ^u8
		y := libwebp.WebPDecodeYUV(
			raw_data(data),
			c.size_t(len(data)),
			&w,
			&h,
			&u,
			&v,
			&stride,
			&uv_stride,
		)
		if !testing.expectf(t, y != nil, "decode %s", oid) {continue}
		defer libwebp.WebPFree(y)

		for size in sizes {
			edge: c.int

			#partial switch size {
			case .x64:
				edge = 64
			case .x128:
				edge = 128
			case:
				continue
			}

			dir := fmt.tprintf("%s/thumbnails/%d", lib_path, edge)
			if err := os.mkdir_all(dir, os.Permissions_Default_Directory);
			   err != nil && err != .Exist {
				testing.expectf(t, false, "mkdir %s: %v", dir, err)
				continue
			}
			pic := libwebp.WebPPicture {
				width     = w,
				height    = h,
				y         = y,
				u         = u,
				v         = v,
				y_stride  = stride,
				uv_stride = uv_stride,
			}
			defer libwebp.WebPPictureFree(&pic)
			path := fmt.tprintf("%s/%s.webp", dir, oid)
			file, open_err := os.open(
				path,
				{.Write, .Create, .Trunc},
				os.Permissions_Default_Directory,
			)
			if !testing.expectf(t, open_err == nil, "open %s", path) {continue}
			defer os.close(file)
			testing.expectf(t, libwebp.rescale(&pic, file, edge), "generate %s", path)
		}
	}
}
