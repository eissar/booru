package thumbnail

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"
import win "core:sys/windows"

import "../dirlist"
import "../jobs"
import "../library"
import "../progress"
import "../store"
import "../vendor/sqlite"


// Generate only missing resolutions; failures are logged and do not prevent startup.
// Set all = true (with ids == nil) to scan all live items, or pass specific item IDs.
generate_missing_thumbnails :: proc(
	s: library.State,
	ids: []int = nil,
	all: bool = false,
	flag: ^jobs.Abort_Flag = nil,
) -> (
	generated, failed: int,
) {
	if all {assert(ids == nil)}
	if !all && len(ids) == 0 {return 0, 0}

	progress.update("startup.thumbnails.discovery", 0)

	images: []library.Image
	missing := make(map[string]bit_set[LOD_RESOLUTION])
	defer delete(missing)

	if !all {
		selected := make([dynamic]library.Image, 0, len(ids), context.temp_allocator)
		for id in ids {
			img, found, rc := store.read_image_by_id(s.data_store, id, context.temp_allocator)
			if rc != sqlite.OK {
				when ODIN_TEST {
					log.errorf("thumbnail: read item %d: sqlite rc=%d", id, rc)
				} else {
					fmt.eprintfln("thumbnail: read item %d: sqlite rc=%d", id, rc)
				}
				return
			}
			if !found {continue}
			append(&selected, img)
			need: bit_set[LOD_RESOLUTION]
			for size in expected_resolutions(img.content_type) {
				p := fmt.tprintf(
					"%s/thumbnails/%s/%s.webp",
					s.library_path,
					name_for_r[size],
					img.oid,
				)
				if !os.exists(p) {need += {size}}
			}
			if need != {} {missing[img.oid] = need}
		}
		images = selected[:]
	} else {
		var_images, rc := store.read_images(s.data_store, context.temp_allocator)
		if rc != sqlite.OK {
			when ODIN_TEST {
				log.errorf("thumbnail: read items: sqlite rc=%d", rc)
			} else {
				fmt.eprintfln("thumbnail: read items: sqlite rc=%d", rc)
			}
			return
		}
		images = var_images
		find_missing_thumbnails(s, images, &missing)
	}

	progress.finish("startup.thumbnails.discovery")

	when ODIN_TEST {
		log.debug("thumbnails: generate missing start")
	} else {
		fmt.eprintln("thumbnails: generate missing start")
	}

	finished, total: u64
	for img in images {
		if sizes, exists := missing[img.oid]; exists && sizes != {} {total += 1}
	}
	progress.update("startup.thumbnails", 0, total)
	defer progress.finish("startup.thumbnails")

	for img in images {
		if jobs.is_aborted(flag) {break}
		sizes, exists := missing[img.oid]
		if !exists || sizes == {} {continue}
		n, f := generate_image_thumbnails(s, img, sizes)
		generated += n
		failed += f
		finished += 1
		progress.update("startup.thumbnails", finished, total)
	}
	return
}

LOD_RESOLUTION :: enum {
	x1024 = 0,
	x512  = 1,
	x256  = 2,
	x128  = 3,
	x64   = 4,
	max   = 5,
}

resolution_pixels :: proc(size: LOD_RESOLUTION) -> int {
	switch size {
	case .x1024:
		return 1024
	case .x512:
		return 512
	case .x256:
		return 256
	case .x128:
		return 128
	case .x64:
		return 64
	case .max:
		return 0
	}
	return 0
}

// Returns the largest resolution; ok is false for an empty set.
largest_resolution :: proc(sizes: bit_set[LOD_RESOLUTION]) -> (largest: LOD_RESOLUTION, ok: bool) {
	for size in sizes {
		if !ok || resolution_pixels(size) > resolution_pixels(largest) {
			largest = size
			ok = true
		}
	}
	return
}

name_for_r := #partial [LOD_RESOLUTION]string {
	.x64  = "64",
	.x128 = "128",
	.max  = "max",
}

expected_resolutions :: proc(content_type: string) -> bit_set[LOD_RESOLUTION] {
	if content_type == "application/pdf" {
		return {.x64, .x128, .max}
	}
	return {.x64, .x128}
}

find_missing_thumbnails :: proc(
	s: library.State,
	images: []library.Image,
	check: ^map[string]bit_set[LOD_RESOLUTION],
	resolutions: bit_set[LOD_RESOLUTION] = {.x64, .x128, .max},
) {
	for img in images {
		check[img.oid] = expected_resolutions(img.content_type)
	}
	exclude_existing_thumbnails(s, check, resolutions)
}

// Subtracts sizes found on disk from caller-seeded OIDs in check.
// Does not add OIDs to check.
exclude_existing_thumbnails :: proc(
	s: library.State,
	check: ^map[string]bit_set[LOD_RESOLUTION],
	resolutions: bit_set[LOD_RESOLUTION] = {.x64, .x128, .max},
) {
	// scan
	for res in resolutions {
		res_name := name_for_r[res]

		// open directory for a resolution
		// to check what oids are present
		pth := fmt.aprintf(
			"%v/thumbnails/%v",
			s.library_path,
			res_name,
			allocator = context.temp_allocator,
		)
		osf_for_r, open_err := os.open(pth, {.Read}, os.Permissions_Default_Directory)
		if open_err != nil {
			// if we can't open the directory for reading,
			// consider them all missing ?
			continue
		}
		defer os.close(osf_for_r)


		if ODIN_OS != .Windows && ODIN_OS != .Linux {
			panic("unsupported os")
		}
		when ODIN_OS == .Linux {
			dents_buf: [32 * 1024]u8 = ---
			for {
				n, err := linux.getdents(linux.Fd(os.fd(osf_for_r)), dents_buf[:])
				if err != nil {return}
				if n == 0 {break} 	// end of directory
				offset := 0
				for entry in linux.dirent_iterate_buf(dents_buf[:n], &offset) {
					name := linux.dirent_name(entry)
					if !strings.has_suffix(name, ".webp") {continue}
					oid := name[:len(name) - len(".webp")]
					if oid in check {
						check[oid] -= {res}
					}
				}
			}
		} else when ODIN_OS == .Windows {
			nt_buf: [4 * 1024]u64 = ---
			names := make([dynamic]string, 0, 1024)
			defer delete(names)
			for {
				clear(&names)
				n, ok := dirlist.read_batch(win.HANDLE(os.fd(osf_for_r)), nt_buf[:], &names, false)
				if !ok {return}
				if n == 0 {break} 	// end of directory
				for name in names {
					if !strings.has_suffix(name, ".webp") {continue}
					oid := name[:len(name) - len(".webp")]
					if oid in check {
						check[oid] -= {res}
					}
				}
			}
		}

	}
}
