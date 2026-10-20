package thumbnail

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"
import win "core:sys/windows"

import "../dirlist"
import "../library"
import "../store"
import "../vendor/sqlite"


// Generate only missing resolutions; failures are logged and do not prevent startup.
generate_missing_thumbnails :: proc(s: library.State) -> (generated, failed: int) {
	missing := make(map[string]bit_set[LOD_RESOLUTION])
	defer delete(missing)
	find_missing_thumbnails(s, &missing)
	log.info("thumbnails: generate missing start")
	// Intentionally naive: SELECT everything and loop over the rows.
	images, rc := store.read_images(s.data_store, context.temp_allocator)
	if rc != sqlite.OK {
		fmt.eprintfln("thumbnail: read items: sqlite rc=%d", rc)
		return
	}
	for img in images {
		sizes, exists := missing[img.oid]
		if !exists {continue}
		n, f := generate_image_thumbnails(s, img, sizes)
		generated += n
		failed += f
	}
	return
}

LOD_RESOLUTION :: enum {
	x1024 = 0,
	x512  = 1,
	x256  = 2,
	x128  = 3,
	x64   = 4,
}

resolution_pixels :: proc(size: LOD_RESOLUTION) -> int {
	// Enum order: x1024, x512, x256, x128, x64.
	return 1024 >> uint(size)
}

// Returns the largest resolution; ok is false for an empty set.
largest_resolution :: proc(sizes: bit_set[LOD_RESOLUTION]) -> (largest: LOD_RESOLUTION, ok: bool) {
	for size in sizes {
		// Smaller enum values represent larger resolutions.
		if !ok || size < largest {
			largest = size
			ok = true
		}
	}
	return
}

name_for_r := #partial [LOD_RESOLUTION]string {
	.x64  = "64",
	.x128 = "128",
}

// Seeds candidate OIDs from the store, then excludes existing thumbnail sizes.
find_missing_thumbnails :: proc(
	s: library.State,
	check: ^map[string]bit_set[LOD_RESOLUTION],
	resolutions: bit_set[LOD_RESOLUTION] = {.x64, .x128},
) {
	images, rc := store.read_images(s.data_store, context.temp_allocator)
	if rc != sqlite.OK {
		fmt.eprintfln("thumbnail: read items: sqlite rc=%d", rc)
		return
	}
	for img in images {
		check[img.oid] = resolutions
	}
	exclude_existing_thumbnails(s, check, resolutions)
}

// Resets caller-seeded OIDs to resolutions, then subtracts sizes found on disk.
// Does not add OIDs to check.
exclude_existing_thumbnails :: proc(
	s: library.State,
	check: ^map[string]bit_set[LOD_RESOLUTION],
	resolutions: bit_set[LOD_RESOLUTION] = {.x64, .x128},
) {
	for _, &entry in check {
		// set the list of res to check.
		// when we scan, we will remove
		// any matches for this entry
		entry = resolutions
	}

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
