package util

import "core:os"
import "core:strings"

expand_home :: proc(path, home: string) -> string {
	if path == "~" {return home}
	if strings.has_prefix(path, "~/") || strings.has_prefix(path, `~\`) {
		expanded, _ := os.join_path({home, path[2:]}, context.temp_allocator)
		return expanded
	}
	return path
}
