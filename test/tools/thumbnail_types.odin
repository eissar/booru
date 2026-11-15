// Prints a table of thumbnail-supported media types derived from src/media and src/thumbnail.
// Run: odin run test/tools/thumbnail_types.odin -file
package main

import "../../src/media"
import "../../src/thumbnail"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:strings"

Decoder_Info :: struct {
	supported: bool,
	decoder:   string,
}

main :: proc() {
	joined_path, join_err := filepath.join({#directory, "../../src/media/media.odin"})
	if join_err != nil {
		fmt.eprintfln("error: join path: %v", join_err)
		os.exit(1)
	}
	defer delete(joined_path)
	media_path, clean_err := filepath.clean(joined_path)
	if clean_err != nil {
		fmt.eprintfln("error: clean path: %v", clean_err)
		os.exit(1)
	}
	defer delete(media_path)

	src, read_err := os.read_entire_file(media_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("error: read %s: %v", media_path, read_err)
		os.exit(1)
	}
	defer delete(src)

	file := ast.File {
		fullpath = media_path,
		src      = string(src),
	}
	p := parser.default_parser()
	if !parser.parse_file(&p, &file) {
		fmt.eprintfln("error: parse %s failed", media_path)
		os.exit(1)
	}

	info_by_name := make(map[string]Decoder_Info)
	defer delete(info_by_name)
	extract_decode_frame_support(&file, &info_by_name)

	probe_formats := make(map[string]bool)
	defer delete(probe_formats)
	extract_switch_formats(&file, "probe_dimensions", &probe_formats)

	shrink_formats := make(map[string]bool)
	defer delete(shrink_formats)
	extract_shrink_on_load(&file, &shrink_formats)

	res_builder := strings.builder_make()
	defer strings.builder_destroy(&res_builder)
	for r in thumbnail.LOD_RESOLUTION {
		name := thumbnail.name_for_r[r]
		if name == "" {continue}
		if strings.builder_len(res_builder) > 0 {
			strings.write_string(&res_builder, ", ")
		}
		fmt.sbprintf(&res_builder, "%spx", name)
	}
	resolutions := strings.to_string(res_builder)

	Row :: struct {
		format:   string,
		ext:      string,
		mime:     string,
		decoder:  string,
		features: string,
	}
	rows := make([dynamic]Row)
	defer delete(rows)

	w_fmt := len("FORMAT")
	w_ext := len("EXT")
	w_mime := len("MIME")
	w_dec := len("DECODER")
	w_feat := len("FEATURES")

	for f in media.Format {
		name := fmt.tprint(f)
		info, ok := info_by_name[name]
		if !ok || !info.supported {continue}

		ext := media.extension(f)
		mime := media.mime(f)
		features := format_features(name, info.decoder, probe_formats[name], shrink_formats[name])
		append(
			&rows,
			Row {
				format = name,
				ext = ext,
				mime = mime,
				decoder = info.decoder,
				features = features,
			},
		)

		w_fmt = max(w_fmt, len(name))
		w_ext = max(w_ext, len(ext))
		w_mime = max(w_mime, len(mime))
		w_dec = max(w_dec, len(info.decoder))
		w_feat = max(w_feat, len(features))
	}

	fmt.printfln(
		"Thumbnail output: WebP (%s), max source pixels: %d",
		resolutions,
		thumbnail.MAX_THUMBNAIL_SOURCE_PIXELS,
	)
	fmt.println()

	print_row :: proc(c1, c2, c3, c4, c5: string, w1, w2, w3, w4, w5: int) {
		fmt.printfln("%-*s  %-*s  %-*s  %-*s  %-*s", w1, c1, w2, c2, w3, c3, w4, c4, w5, c5)
	}

	print_row("FORMAT", "EXT", "MIME", "DECODER", "FEATURES", w_fmt, w_ext, w_mime, w_dec, w_feat)
	fmt.printfln(
		"%s  %s  %s  %s  %s",
		strings.repeat("-", w_fmt, context.temp_allocator),
		strings.repeat("-", w_ext, context.temp_allocator),
		strings.repeat("-", w_mime, context.temp_allocator),
		strings.repeat("-", w_dec, context.temp_allocator),
		strings.repeat("-", w_feat, context.temp_allocator),
	)
	for row in rows {
		print_row(
			row.format,
			row.ext,
			row.mime,
			row.decoder,
			row.features,
			w_fmt,
			w_ext,
			w_mime,
			w_dec,
			w_feat,
		)
	}
	fmt.printfln("\nTotal supported thumbnail types: %d", len(rows))
}

format_features :: proc(name, decoder: string, has_probe, has_shrink: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	add :: proc(b: ^strings.Builder, s: string) {
		if strings.builder_len(b^) > 0 {strings.write_string(b, ", ")}
		strings.write_string(b, s)
	}
	if has_probe {add(&b, "dimensions")}
	if decoder == "libwebp / stb_image" || decoder == "dav1d" {
		add(&b, "alpha")
	}
	if has_shrink {add(&b, "shrink-on-load")}
	if strings.builder_len(b) == 0 {return "-"}
	return strings.to_string(b)
}

extract_switch_formats :: proc(file: ^ast.File, proc_name: string, out: ^map[string]bool) {
	for decl in file.decls {
		vd, ok := decl.derived.(^ast.Value_Decl)
		if !ok {continue}
		for name, i in vd.names {
			ident, id_ok := name.derived.(^ast.Ident)
			if !id_ok || ident.name != proc_name || i >= len(vd.values) {continue}
			pl, pl_ok := vd.values[i].derived.(^ast.Proc_Lit)
			if !pl_ok || pl.body == nil {continue}
			block, b_ok := pl.body.derived.(^ast.Block_Stmt)
			if !b_ok {continue}
			for stmt in block.stmts {
				sw, sw_ok := stmt.derived.(^ast.Switch_Stmt)
				if !sw_ok || sw.cond == nil {continue}
				cond_id, cid_ok := sw.cond.derived.(^ast.Ident)
				if !cid_ok || cond_id.name != "format" {continue}
				sw_body, sb_ok := sw.body.derived.(^ast.Block_Stmt)
				if !sb_ok {continue}
				for c_stmt in sw_body.stmts {
					cc, cc_ok := c_stmt.derived.(^ast.Case_Clause)
					if !cc_ok || len(cc.body) == 0 {continue}
					for expr in cc.list {
						imp, imp_ok := expr.derived.(^ast.Implicit_Selector_Expr)
						if !imp_ok {continue}
						out[imp.field.name] = true
					}
				}
			}
		}
	}
}

extract_shrink_on_load :: proc(file: ^ast.File, out: ^map[string]bool) {
	for decl in file.decls {
		vd, ok := decl.derived.(^ast.Value_Decl)
		if !ok {continue}
		for name, i in vd.names {
			ident, id_ok := name.derived.(^ast.Ident)
			if !id_ok || ident.name != "decode_rgba" || i >= len(vd.values) {continue}
			pl, pl_ok := vd.values[i].derived.(^ast.Proc_Lit)
			if !pl_ok || pl.body == nil {continue}
			block, b_ok := pl.body.derived.(^ast.Block_Stmt)
			if !b_ok {continue}
			for stmt in block.stmts {
				sw, sw_ok := stmt.derived.(^ast.Switch_Stmt)
				if !sw_ok || sw.cond == nil {continue}
				cond_id, cid_ok := sw.cond.derived.(^ast.Ident)
				if !cid_ok || cond_id.name != "format" {continue}
				sw_body, sb_ok := sw.body.derived.(^ast.Block_Stmt)
				if !sb_ok {continue}
				for c_stmt in sw_body.stmts {
					cc, cc_ok := c_stmt.derived.(^ast.Case_Clause)
					if !cc_ok || len(cc.body) == 0 {continue}
					src := file.src[cc.body[0].pos.offset:cc.body[len(cc.body) - 1].end.offset]
					if !strings.contains(src, "use_scaling") {continue}
					for expr in cc.list {
						imp, imp_ok := expr.derived.(^ast.Implicit_Selector_Expr)
						if !imp_ok {continue}
						out[imp.field.name] = true
					}
				}
			}
		}
	}
}

extract_decode_frame_support :: proc(file: ^ast.File, out: ^map[string]Decoder_Info) {
	for decl in file.decls {
		vd, ok := decl.derived.(^ast.Value_Decl)
		if !ok {continue}
		for name, i in vd.names {
			ident, id_ok := name.derived.(^ast.Ident)
			if !id_ok || ident.name != "decode_frame" || i >= len(vd.values) {continue}
			pl, pl_ok := vd.values[i].derived.(^ast.Proc_Lit)
			if !pl_ok || pl.body == nil {continue}
			block, b_ok := pl.body.derived.(^ast.Block_Stmt)
			if !b_ok {continue}
			for stmt in block.stmts {
				sw, sw_ok := stmt.derived.(^ast.Switch_Stmt)
				if !sw_ok || sw.cond == nil {continue}
				cond_id, cid_ok := sw.cond.derived.(^ast.Ident)
				if !cid_ok || cond_id.name != "format" {continue}
				sw_body, sb_ok := sw.body.derived.(^ast.Block_Stmt)
				if !sb_ok {continue}
				for c_stmt in sw_body.stmts {
					cc, cc_ok := c_stmt.derived.(^ast.Case_Clause)
					if !cc_ok || len(cc.body) == 0 {continue}
					info := classify_case_body(file.src, cc.body)
					for expr in cc.list {
						imp, imp_ok := expr.derived.(^ast.Implicit_Selector_Expr)
						if !imp_ok {continue}
						out[imp.field.name] = info
					}
				}
			}
		}
	}
}

classify_case_body :: proc(file_src: string, stmts: []^ast.Stmt) -> Decoder_Info {
	// Check if the sole/final action is returning .Unsupported.
	if len(stmts) == 1 {
		if ret, ok := stmts[0].derived.(^ast.Return_Stmt); ok {
			for res in ret.results {
				if imp, imp_ok := res.derived.(^ast.Implicit_Selector_Expr);
				   imp_ok && imp.field.name == "Unsupported" {
					return {supported = false}
				}
			}
		}
	}
	src := file_src[stmts[0].pos.offset:stmts[len(stmts) - 1].end.offset]
	switch {
	case strings.contains(src, "decode_video_first_frame"):
		return {supported = true, decoder = "ffmpeg (video first frame)"}
	case strings.contains(src, "ffmpeg.first_frame"):
		return {supported = true, decoder = "ffmpeg (first frame)"}
	case strings.contains(src, "decode_yuv_dav1d"):
		return {supported = true, decoder = "dav1d"}
	case strings.contains(src, "decode_rgba"):
		return {supported = true, decoder = "libwebp / stb_image"}
	}
	return {supported = true, decoder = "supported"}
}
