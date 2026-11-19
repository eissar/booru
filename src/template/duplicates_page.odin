package template

import "../library"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

Duplicate_Pair_View :: struct {
	a:    library.Image,
	b:    library.Image,
	dist: int,
}

// render_duplicates_page renders the v1 pairwise duplicate comparison page.
render_duplicates_page :: proc(
	pairs: []Duplicate_Pair_View,
	is_sample := false,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)

	wr(
		&b,
		"<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"/><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/><title>booru / Compare</title>",
	)
	wr(
		&b,
		"<script src=\"/static/htmx.min.js\"></script><script src=\"/static/htmx-response-targets.js\"></script><link href=\"/static/gallery.css\" rel=\"stylesheet\"/><script src=\"/static/gallery.js\"></script>",
	)
	wr(
		&b,
		"<style>" +
		"body{margin:0;background:var(--bg-primary);color:var(--text-primary);font-size:14px;line-height:1.25rem}" +
		".dup-header{background:var(--bg-surface);border-bottom:1px solid var(--border-color-light);min-height:4rem;padding:0.75rem 1rem;display:flex;flex-wrap:wrap;align-items:center;gap:1rem}" +
		".dup-btn{background:var(--bg-surface);color:var(--text-secondary);border:1px solid var(--border-color);padding:0.5rem 0.75rem;font-size:0.75rem;font-weight:500;cursor:pointer}" +
		".dup-btn-sm{background:var(--bg-surface);color:var(--text-secondary);border:1px solid var(--border-color);padding:0.25rem 0.5rem;font-size:0.75rem;font-weight:500;cursor:pointer;margin-left:auto;flex:none}" +
		".dup-apply{border:0;padding:0.5rem 1rem;font-size:0.75rem;font-weight:500;color:#fff;background:var(--accent-indigo);cursor:pointer}" +
		".dup-apply:disabled{opacity:0.45;cursor:not-allowed}" +
		".dup-pair{background:var(--bg-surface);border:1px solid var(--border-color-light)}" +
		".dup-grid{display:grid;grid-template-columns:140px minmax(0,1fr) minmax(0,1fr);border-bottom:1px solid var(--border-color-light)}" +
		".dup-col-head{border-left:1px solid var(--border-color-light);padding:0.75rem 1rem;display:flex;gap:0.75rem;align-items:center;min-width:0}" +
		".dup-cell{font:inherit;text-align:left;cursor:pointer;border:0;border-left:1px solid var(--border-color-light);border-radius:0;padding:0.625rem 1rem;display:flex;flex-direction:column;justify-content:center;min-height:44px;background:transparent;color:var(--text-primary)}" +
		".dup-cell:focus-visible{outline:2px solid var(--accent-indigo);outline-offset:-2px}" +
		".dup-cell[disabled]{cursor:default}" +
		".dup-cell.is-out{background:var(--bg-primary)}" +
		".dup-cell.is-out .dup-val{text-decoration:line-through;font-weight:400}" +
		".dup-cell.is-hi .dup-val{text-decoration:underline;font-weight:500}" +
		".dup-val{font-size:0.875rem;font-weight:500;overflow-wrap:anywhere}" +
		".dup-tag{font-size:0.75rem;line-height:1rem;font-weight:500;padding:0.25rem 0.375rem}" +
		".dup-tag.is-shared{color:var(--text-secondary);background:var(--bg-surface-hover)}" +
		".dup-tag.is-unique{color:var(--accent-indigo);background:color-mix(in srgb,var(--accent-indigo) 12%,transparent)}" +
		".dup-cell.is-out .dup-tag{color:var(--text-secondary);background:transparent;text-decoration:line-through}" +
		".dup-cell.is-hi .dup-tag{text-decoration:underline}" +
		".dup-row.is-same.is-hidden{display:none}" +
		"</style></head><body hx-ext=\"response-targets\">",
	)

	wr(&b, "<header class=\"dup-header\">")
	wr(&b, "<div style=\"flex:1 1 260px;min-width:0\"></div>")
	if len(pairs) > 0 {
		wr(&b, "<div style=\"display:flex;flex-wrap:wrap;gap:0.5rem;align-items:center\">")
		wr(&b, "<button type=\"button\" id=\"dup-reset-all\" class=\"dup-btn\">Reset all</button>")
		wr(
			&b,
			"<button type=\"button\" id=\"dup-apply-all\" class=\"dup-apply\" disabled>Apply all</button>",
		)
		wr(&b, "</div>")
	}
	wr(&b, "</header>")

	wr(
		&b,
		"<main style=\"max-width:1120px;margin:0 auto;padding:1.5rem 1rem 3rem;display:flex;flex-direction:column;gap:2.5rem\">",
	)
	if len(pairs) == 0 {
		wr(
			&b,
			"<div class=\"dup-pair\" style=\"padding:2rem;text-align:center;color:var(--text-muted)\">No duplicate pairs found. <a href=\"/gallery\" style=\"color:var(--accent-indigo)\">Back to gallery</a></div>",
		)
	}

	for pair, pi in pairs {
		write_duplicate_pair_section(&b, pair, pi, is_sample)
	}

	wr(&b, "</main><div id=\"toasts-log\"></div>")
	if len(pairs) > 0 {
		write_duplicates_script(&b, is_sample)
	}
	wr(&b, "</body></html>")
	return strings.to_string(b)
}

@(private = "file")
write_duplicate_pair_section :: proc(
	b: ^strings.Builder,
	pair: Duplicate_Pair_View,
	idx: int,
	is_sample: bool,
) {
	a_date := format_unix_ms_date(pair.a.added_at, context.temp_allocator)
	b_date := format_unix_ms_date(pair.b.added_at, context.temp_allocator)
	a_tags := join_tags_sorted(pair.a.tags, context.temp_allocator)
	b_tags := join_tags_sorted(pair.b.tags, context.temp_allocator)

	Field_Def :: struct {
		key:   string,
		label: string,
		a_val: string,
		b_val: string,
		same:  bool,
	}

	fields := [4]Field_Def {
		{
			key = "name",
			label = "name",
			a_val = pair.a.name,
			b_val = pair.b.name,
			same = pair.a.name == pair.b.name,
		},
		{key = "date", label = "date", a_val = a_date, b_val = b_date, same = a_date == b_date},
		{
			key = "comment",
			label = "comment",
			a_val = pair.a.comment,
			b_val = pair.b.comment,
			same = pair.a.comment == pair.b.comment,
		},
		{key = "tags", label = "tags", a_val = a_tags, b_val = b_tags, same = a_tags == b_tags},
	}

	diff_count := 0
	same_count := 0
	for f in fields {
		if f.same {same_count += 1} else {diff_count += 1}
	}

	wr(b, "<section class=\"dup-section\"")
	attrf(b, "id", "pair-%d", idx + 1)
	attrf(b, "data-pair-id", "p%d", idx + 1)
	ia(b, "data-a-id", pair.a.id)
	ia(b, "data-b-id", pair.b.id)
	ia(b, "data-diff-count", diff_count)
	if is_sample {wr(b, " data-sample=\"1\"")}
	wr(b, " style=\"display:flex;flex-direction:column;gap:0.5rem\">")

	wr(b, "<div class=\"dup-pair\">")
	// Column header row
	wr(b, "<div class=\"dup-grid\"><div></div>")
	write_pair_col_header(b, pair.a, "a", idx)
	write_pair_col_header(b, pair.b, "b", idx)
	wr(b, "</div>")

	// Field rows
	for f in fields {
		wr(b, "<div class=\"dup-grid dup-row")
		if f.same {wr(b, " is-same is-hidden")}
		wr(b, "\"")
		attr(b, "data-field", f.key)
		wr(b, ">")
		wr(
			b,
			"<div style=\"padding:0.625rem 1rem;display:flex;flex-direction:column;justify-content:center\"><span style=\"font-weight:500\">",
		)
		escape_text(b, f.label)
		wr(b, "</span></div>")

		write_field_cell(b, f.key, "a", f.same, pair.a.tags, pair.b.tags, f.a_val)
		write_field_cell(b, f.key, "b", f.same, pair.b.tags, pair.a.tags, f.b_val)
		wr(b, "</div>")
	}

	wr(b, "</div>")

	if same_count > 0 {
		noun := same_count == 1 ? "field" : "fields"
		wr(
			b,
			"<div class=\"dup-same-bar\" style=\"font-size:0.75rem;color:var(--text-secondary)\">",
		)
		wrf(b, "<span class=\"dup-same-note\">%d identical %s hidden · </span>", same_count, noun)
		wr(
			b,
			"<button type=\"button\" class=\"dup-same-toggle\" style=\"background:none;border:0;padding:0;font:inherit;color:inherit;text-decoration:underline;cursor:pointer\" data-count=\"",
		)
		wrf(b, "%d\" data-noun=\"%s\">Show</button></div>", same_count, noun)
	}

	wr(b, "</section>")
}

@(private = "file")
write_pair_col_header :: proc(b: ^strings.Builder, img: library.Image, side: string, idx: int) {
	wr(b, "<div class=\"dup-col-head\">")
	if img.oid != "" {
		wr(
			b,
			"<img loading=\"lazy\" style=\"width:48px;height:36px;object-fit:cover;flex:none;background:var(--border-color)\"",
		)
		attrf(b, "src", "/mipmap/64?ids=%d", img.id)
		attr(b, "alt", img.name)
		wr(b, "/>")
	} else {
		bg := side == "a" ? "#cbd5e1" : "#94a3b8"
		w :=
			img.width > 0 && img.height > 0 ? (img.width == img.height ? 36 : (img.width > img.height ? 48 : 27)) : 48
		wrf(
			b,
			"<div aria-hidden=\"true\" style=\"width:%dpx;height:36px;background:%s;flex:none\"></div>",
			w,
			bg,
		)
	}
	wr(b, "<div style=\"min-width:0;display:flex;flex-direction:column\">")
	wrf(b, "<span style=\"font-size:0.75rem;color:var(--text-muted)\">#%d</span>", img.id)
	wr(
		b,
		"<span style=\"font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap\">",
	)
	escape_text(b, img.name)
	wr(b, "</span></div>")
	wr(b, "<button type=\"button\" class=\"dup-btn-sm dup-keep-all\"")
	attr(b, "data-side", side)
	attrf(b, "data-pair", "p%d", idx + 1)
	wr(b, ">Keep all</button></div>")
}

@(private = "file")
write_field_cell :: proc(
	b: ^strings.Builder,
	field_key, side: string,
	same: bool,
	mine_tags, theirs_tags: []string,
	text_val: string,
) {
	wr(b, "<button type=\"button\" class=\"dup-cell\"")
	attr(b, "data-side", side)
	attr(b, "data-field", field_key)
	if field_key != "tags" {
		attr(b, "data-val", text_val)
	} else {
		joined := strings.join(mine_tags, ",", context.temp_allocator)
		attr(b, "data-val", joined)
	}
	if same {wr(b, " disabled")}
	wr(b, " aria-pressed=\"false\">")

	if field_key == "tags" {
		wr(b, "<span style=\"display:flex;flex-wrap:wrap;gap:0.5rem\">")
		for t in mine_tags {
			unique := !slice.contains(theirs_tags, t)
			wr(b, "<span class=\"dup-tag ")
			wr(b, unique ? "is-unique" : "is-shared")
			wr(b, "\">#")
			escape_text(b, t)
			wr(b, "</span>")
		}
		wr(b, "</span>")
	} else {
		wr(b, "<span class=\"dup-val\">")
		escape_text(b, text_val)
		wr(b, "</span>")
	}

	wr(b, "</button>")
}

@(private = "file")
write_duplicates_script :: proc(b: ^strings.Builder, is_sample: bool) {
	wr(b, "<script>(function(){\n")
	wr(b, "var applyBtn=document.getElementById('dup-apply-all');\n")
	wr(b, "var resetBtn=document.getElementById('dup-reset-all');\n")
	wr(b, "function sections(){return Array.from(document.querySelectorAll('.dup-section'));}\n")
	wr(b, "function updateSection(sec){\n")
	wr(b, "  var rows=Array.from(sec.querySelectorAll('.dup-row:not(.is-same)'));\n")
	wr(b, "  var resolved=0;\n")
	wr(b, "  rows.forEach(function(r){\n")
	wr(b, "    var pick=r.getAttribute('data-pick')||'';\n")
	wr(b, "    if(pick)resolved++;\n")
	wr(b, "    r.querySelectorAll('.dup-cell').forEach(function(c){\n")
	wr(b, "      var s=c.getAttribute('data-side');\n")
	wr(b, "      c.setAttribute('aria-pressed',pick===s?'true':'false');\n")
	wr(b, "      c.classList.toggle('is-out',!!(pick&&pick!==s));\n")
	wr(b, "    });\n")
	wr(b, "  });\n")
	wr(b, "  sec.setAttribute('data-resolved',resolved===rows.length?'1':'0');\n")
	wr(b, "}\n")
	wr(b, "function updateGlobal(){\n")
	wr(b, "  var secs=sections();\n")
	wr(
		b,
		"  var all=secs.length>0&&secs.every(function(s){return s.getAttribute('data-resolved')==='1';});\n",
	)
	wr(
		b,
		"  if(applyBtn){applyBtn.disabled=!all;if(applyBtn.textContent!=='\u2713 Applied')applyBtn.textContent='Apply all';}\n",
	)
	wr(b, "}\n")
	wr(b, "document.addEventListener('click',function(e){\n")
	wr(b, "  var cell=e.target.closest('.dup-cell');\n")
	wr(b, "  if(cell&&!cell.disabled){\n")
	wr(b, "    var row=cell.closest('.dup-row');\n")
	wr(b, "    var side=cell.getAttribute('data-side');\n")
	wr(b, "    row.setAttribute('data-pick',row.getAttribute('data-pick')===side?'':side);\n")
	wr(b, "    updateSection(cell.closest('.dup-section'));\n")
	wr(b, "    if(applyBtn)applyBtn.textContent='Apply all';\n")
	wr(b, "    updateGlobal();return;\n")
	wr(b, "  }\n")
	wr(b, "  var ka=e.target.closest('.dup-keep-all');\n")
	wr(b, "  if(ka){\n")
	wr(b, "    var sec=ka.closest('.dup-section');\n")
	wr(b, "    var side=ka.getAttribute('data-side');\n")
	wr(
		b,
		"    sec.querySelectorAll('.dup-row:not(.is-same)').forEach(function(r){r.setAttribute('data-pick',side);});\n",
	)
	wr(
		b,
		"    updateSection(sec);if(applyBtn)applyBtn.textContent='Apply all';updateGlobal();return;\n",
	)
	wr(b, "  }\n")
	wr(b, "  var st=e.target.closest('.dup-same-toggle');\n")
	wr(b, "  if(st){\n")
	wr(b, "    var sec=st.closest('.dup-section');\n")
	wr(b, "    var open=st.textContent==='Hide';\n")
	wr(
		b,
		"    sec.querySelectorAll('.dup-row.is-same').forEach(function(r){r.classList.toggle('is-hidden',open);});\n",
	)
	wr(b, "    st.textContent=open?'Show':'Hide';\n")
	wr(b, "    var n=st.getAttribute('data-count'),noun=st.getAttribute('data-noun');\n")
	wr(
		b,
		"    sec.querySelector('.dup-same-note').textContent=open?(n+' identical '+noun+' hidden \u00b7 '):('Showing '+n+' identical '+noun+' \u00b7 ');\n",
	)
	wr(b, "  }\n")
	wr(b, "});\n")
	wr(b, "document.addEventListener('mouseover',function(e){\n")
	wr(b, "  var ka=e.target.closest('.dup-keep-all');if(!ka)return;\n")
	wr(b, "  var side=ka.getAttribute('data-side');\n")
	wr(
		b,
		"  ka.closest('.dup-section').querySelectorAll('.dup-row:not(.is-same) .dup-cell[data-side=\"'+side+'\"]').forEach(function(c){c.classList.add('is-hi');});\n",
	)
	wr(b, "});\n")
	wr(b, "document.addEventListener('mouseout',function(e){\n")
	wr(b, "  var ka=e.target.closest('.dup-keep-all');if(!ka)return;\n")
	wr(
		b,
		"  ka.closest('.dup-section').querySelectorAll('.dup-cell.is-hi').forEach(function(c){c.classList.remove('is-hi');});\n",
	)
	wr(b, "});\n")
	wr(b, "if(resetBtn)resetBtn.addEventListener('click',function(){\n")
	wr(
		b,
		"  sections().forEach(function(s){s.querySelectorAll('.dup-row').forEach(function(r){r.removeAttribute('data-pick');});updateSection(s);});\n",
	)
	wr(b, "  if(applyBtn)applyBtn.textContent='Apply all';updateGlobal();\n")
	wr(b, "});\n")
	wr(b, "if(applyBtn)applyBtn.addEventListener('click',async function(){\n")
	wr(b, "  if(applyBtn.disabled)return;\n")
	wr(b, "  applyBtn.disabled=true;\n")
	wr(b, "  for(var sec of sections()){\n")
	wr(b, "    var aId=sec.getAttribute('data-a-id'),bId=sec.getAttribute('data-b-id');\n")
	wr(b, "    var votesA=0,votesB=0,vals={};\n")
	wr(b, "    sec.querySelectorAll('.dup-row').forEach(function(r){\n")
	wr(b, "      var k=r.getAttribute('data-field'),p=r.getAttribute('data-pick')||'a';\n")
	wr(b, "      if(!r.classList.contains('is-same')){if(p==='a')votesA++;else votesB++;}\n")
	wr(b, "      var c=r.querySelector('.dup-cell[data-side=\"'+p+'\"]');\n")
	wr(b, "      if(c)vals[k]=c.getAttribute('data-val')||'';\n")
	wr(b, "    });\n")
	wr(b, "    var keepId=votesB>votesA?bId:aId,dropId=keepId===aId?bId:aId;\n")
	wr(
		b,
		"    var params=new URLSearchParams({keep_id:keepId,drop_id:dropId,name:vals.name||'',comment:vals.comment||'',tags:vals.tags||''});\n",
	)
	if is_sample {
		wr(b, "    params.set('sample','1');\n")
	}
	wr(
		b,
		"    var res=await fetch('/duplicates/resolve',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:params});\n",
	)
	wr(b, "    if(!res.ok){applyBtn.disabled=false;return;}\n")
	wr(b, "  }\n")
	wr(b, "  applyBtn.textContent='\u2713 Applied';\n")
	wr(b, "});\n")
	wr(b, "sections().forEach(updateSection);updateGlobal();\n")
	wr(b, "})();</script>\n")
}

@(private = "file")
format_unix_ms_date :: proc(ms: i64, alloc := context.allocator) -> string {
	if ms <= 0 {return ""}
	t := time.unix(0, ms * 1_000_000)
	y, m, d := time.date(t)
	return fmt.aprintf("%04d-%02d-%02d", y, int(m), d, allocator = alloc)
}

@(private = "file")
join_tags_sorted :: proc(tags: []string, alloc := context.allocator) -> string {
	if len(tags) == 0 {return ""}
	cp := slice.clone(tags, context.temp_allocator)
	slice.sort(cp)
	return strings.join(cp, ",", alloc)
}
