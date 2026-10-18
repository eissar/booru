package importers

import "core:bufio"
import "core:encoding/hex"
import "core:fmt"
import "core:io"
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

	buf: [1024 * 4]u8
	for {
		defer free_all(context.temp_allocator) // technically optional

		n, err := linux.getdents(rootFd, buf[:])
		if err != .NONE {
			ctx.read_errors += 1
			fmt.eprintfln("error: reading %s: %v", src_images_dir, err, flush = true)
			return
		}
		if n == 0 {break}


		shard := elog.get_current_event_shard(context.temp_allocator)
		path, join_err := os.join_path({log.root, "events", shard}, context.temp_allocator)
		if join_err != nil {
			panic("err during import finding event shard path")
		}


		ev_opts := os.File_Flags{.Write, .Create, .Append}
		ev_handle, ev_open_err := os.open(path, ev_opts, os.Permissions_Default_File)
		if ev_open_err != nil {
			// retryable?
			panic("could not open event log for writing")
		}

		opt := json.Marshal_Options {
			spec   = .JSON,
			pretty = false,
		}

		input_stream := os.to_writer(ev_handle)

		bw: bufio.Writer
		bufio.writer_init(&bw, input_stream, size = 1024, allocator = context.temp_allocator)
		// the writer auto flushes when the buf is full, but we need to
		// do this once to flush any remaining
		defer bufio.writer_flush(&bw)

		buffered_stream := bufio.writer_to_stream(&bw)


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
			ev := cast(^library.Event)&item
			library.new_add_event(ev)

			// we reuse the buffer so
			// need to bound to read bytes (i)
			json_err := json.unmarshal(
				data[:i],
				&item,
				json.DEFAULT_SPECIFICATION,
				context.temp_allocator,
			)

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
			ev.oid = oid
			ev.content_type = media.mime(format)

			if err := json.marshal_to_writer(buffered_stream, ev^, &opt); err != nil {
				ctx.read_errors += 1
				continue
			}
			io.write_byte(buffered_stream, '\n')


			if ctx.success < 10 {fmt.println(meta_dirname)}
			ctx.success += 1
		}
	}
}

// _ :: proc() {
//
// 	// bufio.Writer
// 	bufio.fl
//
// }


@(test) // just for convenience, ignore
eagle_import_test :: proc(t: ^testing.T) {
	root, join_err := os.join_path({"/home/eissar/Memes.library", "images"}, context.allocator)
	defer delete(root, context.allocator)

	if join_err != nil {
		fmt.eprintfln("error: building library root: %v", join_err)
		return
	}

	ctx := Eagle_Import_Ctx{}

	fd, err := os.open(root, {.Read}, os.Permissions_Default)
	if err != nil {
		fmt.panicf("error opening lib dir %v ; err=%v", root, err)
	}

	// never write into the source library; import into a scratch library
	dest_root := "/tmp/booru_eagle_import_test"
	if init_err := library.init_new_library(dest_root); init_err != nil {
		fmt.panicf("error creating dest library %v ; err=%v", dest_root, init_err)
	}

	e := elog.EventLog {
		root = dest_root,
	}
	eagle_import(root, dest_root, &ctx, linux.Fd(os.fd(fd)), &e)

	fmt.println(ctx)
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

	return hex_str, fmt, err
}
