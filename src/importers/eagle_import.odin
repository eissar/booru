package importers

import "core:c"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"
import win "core:sys/windows"

import "core:crypto/sha2"

import "core:encoding/json"

import "../dirlist"
import elog "../event_log"
import "../library"
import "../media"
import "../store"
import "../vendor/sqlite"

Import_Result :: struct {
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
	added_at:     i64 `json:"btime"`,
	content_type: string `json:"-"`,
	ext:          string, // Eagle's "ext" key matches, no tag needed
	height:       int,
	id:           int `json:"-"`,
	mtime:        i64,
	name:         string,
	oid:          string `json:"-"`,
	op:           string `json:"-"`,
	path:         string `json:"-"`,
	tags:         []string,
	width:        int,
}

eagle_import :: proc(
	src_images_dir: string,
	s: ^library.State,
	rootFd: linux.Fd,
) -> (
	res: Import_Result,
) {
	data := make([]u8, METADATA_MAX_BYTES, context.allocator)
	defer delete(data, context.allocator)

	// Events must outlive the per-directory-batch temporary allocator resets.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	event_alloc := mem.dynamic_arena_allocator(&arena)
	events := make([dynamic]elog.Event, event_alloc)

	// Directory names from the current batch (entries that are not directories are already dropped).
	dir_names := make([dynamic]string, 0, 256)
	defer delete(dir_names)

	for {
		defer free_all(context.temp_allocator)
		clear(&dir_names)

		when ODIN_OS == .Linux {
			buf: [1024 * 4]u8 = ---
			n, err := linux.getdents(rootFd, buf[:])
			if err != .NONE {
				res.read_errors += 1
				fmt.eprintfln("error: reading %s: %v", src_images_dir, err, flush = true)
				return
			}
			if n == 0 {break}

			offs := 0
			for {
				ent, cont := linux.dirent_iterate_buf(buf[:n], &offs)
				if !cont {break}
				// TODO: some filesystems report .UNKNOWN
				if ent.type != .DIR {continue}
				append(&dir_names, linux.dirent_name(ent))
			}
		} else when ODIN_OS == .Windows {
			nt_buf: [512]u64 = ---
			n, ok := dirlist.read_batch(win.HANDLE(uintptr(rootFd)), nt_buf[:], &dir_names, true)
			if !ok {
				res.read_errors += 1
				fmt.eprintfln("error: reading %s", src_images_dir, flush = true)
				return
			}
			if n == 0 {break}
		} else {
			#panic("eagle_import: unsupported OS")
		}

		for meta_dirname in dir_names {
			// An item is <id>.info/
			// skip everything else (including . and ..).
			if !strings.has_suffix(meta_dirname, ".info") {continue}

			meta_path := fmt.tprintf("%s/%s/metadata.json", src_images_dir, meta_dirname)

			meta_Fd, meta_err := os.open(meta_path, {.Read}, os.Permissions_Default)
			defer os.close(meta_Fd)

			if meta_err == .Not_Exist {
				res.missing += 1
				continue
			}
			if meta_err != nil {
				res.read_errors += 1
				continue
			}

			i, read_err := os.read(meta_Fd, data)
			if read_err != nil {
				res.read_errors += 1
				continue
			}

			probe_eof := [1]u8{}
			// we do another read with the existing file handle.
			// with zero bytes remaining, it should return .EOF
			//
			// this is much faster than doing an fstat/file
			if _, eof := os.read(meta_Fd, probe_eof[:]); eof != .EOF {
				res.read_errors += 1
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
				res.read_errors += 1
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
			to_path, _ := os.join_path({s.library_path, "images", to_leaf}, context.temp_allocator)

			oid, format, err := copy_and_hash_and_determine_content_type(to_path, from_path)
			// oid, err := copy_and_hash(to_path, from_path)
			if err != nil {
				// rename this or st
				res.read_errors += 1
				continue
			}
			ev.oid = strings.clone(oid, event_alloc)
			ev.content_type = media.mime(format)
			append(&events, ev^)

			res.success += 1
		}
	}
	// Originals have each been synced once. Persist their new filenames once
	// for the completed batch before syncing the event log.
	images_dir, images_dir_err := os.open(
		fmt.tprintf("%s/images", s.library_path),
		{.Read},
		os.Permissions_Default,
	)
	if images_dir_err != nil {fmt.panicf("import: open images directory: %v", images_dir_err)}
	defer os.close(images_dir)
	if err := os.sync(images_dir); err != nil {
		fmt.panicf("import: sync images directory: %v", err)
	}
	if err := elog.events_append(s.event_log, events[:]); err != "" {
		fmt.panicf("import: event log append failed: %s", err)
	}
	// Log first, then apply: a failed apply is recovered by the next replay.
	rc := sqlite.with_transaction(
		s.data_store,
		events[:],
		proc(tx: ^sqlite.Tx, events: []elog.Event) -> c.int {
			for ev in events {
				item := library.Image {
					id           = ev.id,
					oid          = ev.oid,
					path         = ev.path,
					ext          = ev.ext,
					tags         = ev.tags,
					width        = ev.width,
					height       = ev.height,
					name         = ev.name,
					mtime        = ev.mtime,
					added_at     = ev.added_at,
					content_type = ev.content_type,
				}
				if rc := store.insert_into_items(tx, item); rc != sqlite.OK {return rc}
			}
			return sqlite.OK
		},
	)
	if rc != sqlite.OK {fmt.panicf("import: apply events to store: rc=%v", rc)}
	return
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
