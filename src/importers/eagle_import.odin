package importers

import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

import "core:crypto/sha2"

import "core:encoding/json"

import elog "../event_log"
import "../library"
import "../media"

Eagle_Import_Ctx :: struct {
	success:     int,
	missing:     int,
	read_errors: int,
}

METADATA_MAX_BYTES :: 2 * 1024 * 1024

Palette :: struct {
	color: [3]int,
	ratio: f64,
}

// the full available data is here.
EagleItem :: struct {
	annotation:        string,
	btime:             i64,
	comments:          []json.Value, // shape unknown
	customThumbnail:   bool,
	deletedTime:       i64,
	duration:          f64,
	ext:               string,
	folders:           []string,
	height:            int,
	id:                string,
	isDeleted:         bool,
	lastModified:      i64,
	modificationTime:  i64,
	mtime:             i64,
	name:              string,
	noThumbnail:       bool,
	palettes:          []Palette,
	processingPalette: bool,
	resolutionHeight:  int,
	resolutionWidth:   int,
	size:              i64,
	star:              int,
	tags:              []string,
	url:               string,
	width:             int,
}

// transmutable into Event
EagleItem_Event :: struct {
	added_at:     Iso_Time `json:"btime"`,
	content_type: string `json:"-"`,
	ext:          string, // Eagle's "ext" key matches, no tag needed
	height:       int,
	id:           int `json:"-"`,
	mtime:        Iso_Time,
	name:         string,
	oid:          string `json:"-"`,
	op:           string `json:"-"`,
	path:         string `json:"-"`,
	tags:         []string,
	width:        int,
}

// WIP
eagle_import :: proc(
	src_images_dir: string,
	dest_root: string,
	ctx: ^Eagle_Import_Ctx,
	rootFd: linux.Fd,
	log: ^elog.EventLog,
) {
	data := make([]u8, METADATA_MAX_BYTES, context.allocator)
	defer delete(data, context.allocator)

	// Events must outlive the per-directory-batch temporary allocator resets.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	event_alloc := mem.dynamic_arena_allocator(&arena)
	events := make([dynamic]elog.Event, event_alloc)

	buf: [1024 * 4]u8
	for {
		defer free_all(context.temp_allocator)

		n, err := linux.getdents(rootFd, buf[:])
		if err != .NONE {
			ctx.read_errors += 1
			fmt.eprintfln("error: reading %s: %v", src_images_dir, err, flush = true)
			return
		}
		if n == 0 {break}


		offs := 0
		for {
			ent, cont := linux.dirent_iterate_buf(buf[:n], &offs)
			if !cont {break}

			// An item is <id>.info/
			// skip everything else (including . and ..).
			meta_dirname := linux.dirent_name(ent)

			// TODO: some filesystems report .UNKNOWN
			if ent.type != .DIR || !strings.has_suffix(meta_dirname, ".info") {continue}

			meta_path := fmt.tprintf("%s/%s/metadata.json", src_images_dir, meta_dirname)

			meta_Fd: ^os.File
			meta_err: os.Error
			meta_info: os.File_Info
			meta_Fd, meta_err = os.open(meta_path, {.Read}, os.Permissions_Default)
			defer os.close(meta_Fd)

			if meta_err == .Not_Exist {
				ctx.missing += 1
				continue
			}
			if meta_err != nil {
				ctx.read_errors += 1
				continue
			}

			i, read_err := os.read(meta_Fd, data)
			if read_err != nil {
				ctx.read_errors += 1
				continue
			}

			probe_eof := [1]u8{}
			// we do another read with the existing file handle.
			// with zero bytes remaining, it should return .EOF
			//
			// this is much faster than doing an fstat/file
			if _, eof := os.read(meta_Fd, probe_eof[:]); eof != .EOF {
				ctx.read_errors += 1
				continue
			}


			item: EagleItem_Event

			// this is usually unsafe but fine because
			// @(test) eagle_item_transmutable_into_event
			ev := cast(^elog.Event)&item
			library.new_add_event(ev)

			// we reuse the buffer so
			// need to bound to read bytes (i)
			json_err := json.unmarshal(data[:i], &item, json.DEFAULT_SPECIFICATION, event_alloc)

			if json_err != nil {
				// no unique error tracking
				ctx.read_errors += 1
				continue
			}

			from_leaf := fmt.aprintf("%v.%v", ev.name, ev.ext, allocator = context.temp_allocator)
			// name = name from dirent, like ID.info/
			from_path, _ := os.join_path(
				{src_images_dir, meta_dirname, from_leaf},
				context.temp_allocator,
			)

			// images are stored as images/id.ext
			to_leaf := fmt.aprintf("%v.%v", ev.id, ev.ext, allocator = context.temp_allocator)
			to_path, _ := os.join_path({dest_root, "images", to_leaf}, context.temp_allocator)

			oid, format, err := copy_and_hash_and_determine_content_type(to_path, from_path)
			// oid, err := copy_and_hash(to_path, from_path)
			if err != nil {
				// rename this or st
				ctx.read_errors += 1
				continue
			}
			ev.oid = strings.clone(oid, event_alloc)
			ev.content_type = media.mime(format)
			append(&events, ev^)


			if ctx.success < 10 {fmt.println(meta_dirname)}
			ctx.success += 1
		}
	}
	// Originals have each been synced once. Persist their new filenames once
	// for the completed batch before syncing the event log.
	images_dir, images_dir_err := os.open(
		fmt.tprintf("%s/images", dest_root),
		{.Read},
		os.Permissions_Default,
	)
	if images_dir_err != nil {fmt.panicf("import: open images directory: %v", images_dir_err)}
	defer os.close(images_dir)
	if err := os.sync(images_dir); err != nil {
		fmt.panicf("import: sync images directory: %v", err)
	}
	if err := elog.events_append(log, events[:]); err != "" {
		fmt.panicf("import: event log append failed: %s", err)
	}
	// TODO: apply events to the store after events_append (play_batch: append + store.apply in one tx);
	// currently imported items only appear after the next replay.
}

@(test)
eagle_import_test :: proc(t: ^testing.T) {
	// synthetic fixture; paths are relative to the repo root (where tests run)
	root := "test/fixture/eagle/fixture.library/images"

	fd, err := os.open(root, {.Read}, os.Permissions_Default)
	if !testing.expectf(t, err == nil, "open fixture %v: %v", root, err) {return}
	defer os.close(fd)

	// import into a fresh scratch library so reruns don't collide
	dest_root, temp_err := os.make_directory_temp("", "booru-eagle-import-*", context.allocator)
	if !testing.expect(t, temp_err == nil) {return}
	defer delete(dest_root)
	defer os.remove_all(dest_root)
	init_err := library.init_new_library(dest_root)
	if !testing.expectf(t, init_err == nil, "init library: %v", init_err) {return}

	ctx := Eagle_Import_Ctx{}
	e := elog.EventLog {
		root = dest_root,
	}
	eagle_import(root, dest_root, &ctx, linux.Fd(os.fd(fd)), &e)

	testing.expect_value(t, ctx.success, 3)
	testing.expect_value(t, ctx.missing, 1)
	testing.expect_value(t, ctx.read_errors, 0)
}

copy_and_hash :: proc(dst_path: string, src_path: string) -> (sha: string, err: os.Error) {
	src := os.open(src_path, {.Read}, os.Permissions_Read_All) or_return
	defer os.close(src)

	dst := os.open(dst_path, {.Read, .Write, .Create, .Trunc}, os.Permissions_All) or_return
	defer os.close(dst)

	// I have no idea what size is appropriate
	buf: [64 * 1024]u8

	ctx: sha2.Context_256
	sha2.init_256(&ctx)

	// ref: _copy_buffer
	for {
		nr, er := os.read(src, buf[:])
		if nr > 0 {

			// only read up to bytes written
			sha2.update(&ctx, buf[:nr])
			nw, we := os.write(dst, buf[:nr])

			if we != nil {
				err = we
				break
			}
			if nr != nw {
				err = .Short_Write
				break
			}
		}
		if er != nil {break} 	// .EOF ends the loop
	}

	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&ctx, digest[:], finalize_clone = false)
	hex_str := string(hex.encode(digest[:], context.temp_allocator))

	return hex_str, err
}

// nice function name
copy_and_hash_and_determine_content_type :: proc(
	dst_path: string,
	src_path: string,
) -> (
	sha: string,
	fmt: media.Format,
	err: os.Error,
) {
	src := os.open(src_path, {.Read}, os.Permissions_Read_All) or_return
	defer os.close(src)

	dst := os.open(dst_path, {.Read, .Write, .Create, .Trunc}, os.Permissions_All) or_return
	defer os.close(dst)

	// I have no idea what size is appropriate
	buf: [64 * 1024]u8

	ctx: sha2.Context_256
	sha2.init_256(&ctx)

	first_chunk := true
	// ref: _copy_buffer
	for {
		nr, er := os.read(src, buf[:])
		if nr > 0 {

			if first_chunk {
				fmt = media.detect_format(buf[:min(nr, 32)])
				first_chunk = false
			}

			// only read up to bytes written
			sha2.update(&ctx, buf[:nr])
			nw, we := os.write(dst, buf[:nr])

			if we != nil {
				err = we
				break
			}
			if nr != nw {
				err = .Short_Write
				break
			}
		}
		if er != nil {break} 	// .EOF ends the loop
	}

	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&ctx, digest[:], finalize_clone = false)
	hex_str := string(hex.encode(digest[:], context.temp_allocator))

	if err == nil {
		if sync_err := os.sync(dst); sync_err != nil {
			panic("import: original sync failed")
		}
	}
	return hex_str, fmt, err
}
