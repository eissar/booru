package bench

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

BUFFER_BYTES :: 16 * 1024 * 1024
Fields :: map[string]string
File_Value :: union {
	string,
	Fields,
}
Snapshot :: struct {
	cgroup:  map[string]File_Value,
	process: map[string]Fields,
}
Report :: struct {
	cgroup_path:  string,
	buffer_bytes: string,
	phases:       map[string]Snapshot,
}
FILES := [?]string {
	"memory.current",
	"memory.peak",
	"memory.stat",
	"memory.events",
	"memory.events.local",
	"memory.swap.current",
	"memory.swap.peak",
	"memory.swap.events",
	"memory.max",
	"memory.high",
	"memory.low",
	"memory.min",
}

read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return string(data), err == nil
}

// Split kernel field lines without interpreting their values or units.
parse_fields :: proc(text: string, separator: u8) -> Fields {
	fields := make(Fields, context.temp_allocator)
	content := text
	for line in strings.split_lines_iterator(&content) {
		for c, i in line {
			if c == rune(separator) {
				fields[strings.trim_space(line[:i])] = strings.trim_space(line[i + 1:])
				break
			}
		}
	}
	return fields
}

snapshot :: proc(dir: string) -> Snapshot {
	s := Snapshot {
		cgroup  = make(map[string]File_Value, context.temp_allocator),
		process = make(map[string]Fields, context.temp_allocator),
	}
	if dir != "" {
		for file in FILES {
			text, ok := read_text(fmt.tprintf("%s/%s", dir, file))
			if !ok {continue}
			if file == "memory.stat" || strings.contains(file, "events") {
				s.cgroup[file] = parse_fields(text, ' ')
			} else {
				s.cgroup[file] = strings.trim_space(text)
			}
		}
	}
	proc_files := [?]string{"status", "smaps_rollup"}
	for file in proc_files {
		if text, ok := read_text(fmt.tprintf("/proc/self/%s", file)); ok {
			s.process[file] = parse_fields(text, ':')
		}
	}
	return s
}

main :: proc() {
	// Probe data lives until exit; values remain strings as supplied by Linux.
	report := Report {
		phases = make(map[string]Snapshot, context.temp_allocator),
	}
	membership, _ := read_text("/proc/self/cgroup")
	for line in strings.split_lines_iterator(&membership) {
		if strings.has_prefix(line, "0::") {
			report.cgroup_path = fmt.tprintf(
				"/sys/fs/cgroup/%s",
				strings.trim_prefix(line[3:], "/"),
			)
			break
		}
	}
	report.buffer_bytes = fmt.tprintf("%d", BUFFER_BYTES)
	report.phases["baseline"] = snapshot(report.cgroup_path)
	buffer, err := mem.alloc_bytes(BUFFER_BYTES)
	if err != nil {
		fmt.eprintfln("Benchmark allocation failed: %v", err)
		os.exit(1)
	}
	for i := 0; i < len(buffer); i += 4096 {buffer[i] = 1}
	report.phases["touched"] = snapshot(report.cgroup_path)
	mem.free_bytes(buffer)
	report.phases["freed"] = snapshot(report.cgroup_path)

	data, json_err := json.marshal(report)
	if json_err != nil {
		fmt.eprintfln("JSON encoding failed: %v", json_err)
		os.exit(1)
	}
	defer delete(data)
	fmt.println(string(data))
}
