package library

import "core:sync"

import "core:fmt"
import "core:os"

import elog "../event_log"
import "../vendor/sqlite"

State :: struct {
	library_path: string,
	data_store:   ^sqlite.DB,
	event_log:    ^elog.EventLog,
}

Image :: struct {
	id:           int,
	oid:          string,
	path:         string,
	ext:          string, // file extension without the dot; original is images/<id>.<ext>
	tags:         []string,
	width:        int,
	height:       int,
	name:         string,
	mtime:        string,
	added_at:     string,
	content_type: string,
}


// init_new_library creates an empty library skeleton under root.
// Idempotent: existing directories are fine; a conflicting file or a
// permission failure returns an error.
init_new_library :: proc(root: string) -> os.Error {
	subdirs := [?]string{"events", "images", "thumbnails", "thumbnails/64", "thumbnails/128"}

	if err := os.mkdir_all(root, os.Permissions_Default_Directory); err != nil {
		return err
	}
	for sub in subdirs {
		path := fmt.tprintf("%s/%s", root, sub)
		if err := os.mkdir_all(path, os.Permissions_Default_Directory); err != nil {
			return err
		}
	}
	return nil
}

@(private = "file")
Id_Giver: struct {
	i:  int,
	mu: sync.Mutex,
}
@(init)
@(private = "file")
init_Id_Giver :: proc "contextless" () {
	sync.guard(&Id_Giver.mu)
	Id_Giver.i = 1
}

// Only loaded images are considered; originals without event-log entries are
// invisible here after restart. Keep exclusive file creation to avoid overwrites.
// Call after loading the library, before accepting uploads. Never move backwards.
seed_ids_from_library :: proc(images: []Image) {
	sync.guard(&Id_Giver.mu)
	for img in images {
		if img.id >= Id_Giver.i {
			Id_Giver.i = img.id + 1
		}
	}
}

requestNewId :: proc() -> int {
	sync.guard(&Id_Giver.mu)
	id := Id_Giver.i
	Id_Giver.i += 1
	return id
}
