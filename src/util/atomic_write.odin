package util

import "core:os"
import "core:path/filepath"
import "core:strings"

// atomic_write atomically publishes complete contents using a sibling temporary file.
// With replace_existing=false, publication fails if the destination already exists.
// This guarantees atomic visibility, not crash durability. The caller owns file
// and parent-directory syncing, allowing it to order or batch those operations.
atomic_write :: proc(path: string, data: []u8, replace_existing := true) -> os.Error {
	dir_path := filepath.dir(path)
	file, err := os.create_temp_file(dir_path, ".atomic-write-*")
	if err != nil {return err}
	temp_path := strings.clone(os.name(file))
	defer delete(temp_path)
	defer os.remove(temp_path)
	closed := false
	defer {
		if !closed {os.close(file)}
	}

	written, write_err := os.write(file, data)
	if write_err != nil {return write_err}
	if written != len(data) {return .Short_Write}
	close_err := os.close(file)
	closed = true
	if close_err != nil {return close_err}

	if replace_existing {
		if rename_err := os.rename(temp_path, path); rename_err != nil {return rename_err}
	} else {
		// Hard-link publication is atomic and never replaces an existing name.
		if link_err := os.link(temp_path, path); link_err != nil {return link_err}
		if remove_err := os.remove(temp_path); remove_err != nil {return remove_err}
	}

	return nil
}
