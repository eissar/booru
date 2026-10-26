package template

import "../vendor/tidy"
import "core:c"
import "core:strings"

// Keep these options unchanged; fixtures depend on them.
normalize_html :: proc(html: string) -> (normalized: string, ok: bool) {
	doc := tidy.Create()
	if doc == nil {return}
	defer tidy.Release(doc)
	options := [?][2]cstring {
		{"sort-attributes", "alpha"},
		{"wrap", "0"},
		{"indent", "no"},
		{"tidy-mark", "no"},
		{"merge-divs", "no"},
		{"merge-spans", "no"},
		{"newline", "LF"},
		{"quiet", "yes"},
		{"show-warnings", "no"},
	}
	for option in options {
		if tidy.OptParseValue(doc, option[0], option[1]) != .Yes {return}
	}
	input := strings.clone_to_cstring(html)
	defer delete(input)
	if tidy.ParseString(doc, input) < 0 {return}
	if tidy.CleanAndRepair(doc) < 0 {return}
	length: c.uint
	_ = tidy.SaveString(doc, nil, &length)
	if length == 0 {return "", true}
	buffer := make([]u8, int(length))
	if tidy.SaveString(doc, cstring(raw_data(buffer)), &length) < 0 {
		delete(buffer)
		return
	}
	return string(buffer[:int(length)]), true
}
