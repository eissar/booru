package template

import "../library"
import "core:fmt"
import "core:strings"
import "core:time"

Duplicate_Group_View :: struct {
	gid:       int,
	items:     []library.Image,
	max_dist:  int,
	identical: bool,
}

// render_duplicates_page renders the duplicate comparison and merge page.
render_duplicates_page :: proc(
	groups: []Duplicate_Group_View,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)

	wr(
		&b,
		"<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"/><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/><title>Duplicates</title>",
	)
	wr(
		&b,
		"<link href=\"/static/gallery.css\" rel=\"stylesheet\"/><script src=\"/static/gallery.js\"></script>",
	)
	wr(
		&b,
		"<style>" +
		".dup-header{position:sticky;top:0;z-index:20;background:var(--bg-surface);border-bottom:1px solid var(--border-color-light);padding:.75rem 1.25rem}" +
		".dup-bar{display:flex;align-items:center;justify-content:space-between;gap:1rem;flex-wrap:wrap}" +
		".dup-bar-left{display:flex;align-items:baseline;gap:.75rem}" +
		".dup-bar-left h1{margin:0;font-size:1rem;font-weight:600}" +
		".dup-bar-right{display:flex;align-items:center;gap:.5rem}" +
		".dup-btn{font:inherit;font-size:.8125rem;padding:.35rem .75rem;border-radius:.375rem;border:1px solid var(--border-color);background:transparent;color:var(--text-primary);cursor:pointer;text-decoration:none}" +
		".dup-btn:hover:not(:disabled){background:var(--bg-surface-hover)}" +
		".dup-btn-primary{background:var(--accent-indigo);border-color:var(--accent-indigo);color:#fff}" +
		".dup-btn-primary:hover:not(:disabled){opacity:.9;background:var(--accent-indigo)}" +
		".dup-btn:disabled{opacity:.4;cursor:default}" +
		".dup-settings{display:flex;flex-wrap:wrap;gap:1rem 2.5rem;margin-top:.75rem;padding-top:.75rem;border-top:1px solid var(--border-color-light);font-size:.8125rem}" +
		".dup-settings-col{display:flex;flex-direction:column;gap:.25rem}" +
		".dup-settings-label{font-size:.75rem;color:var(--text-muted);margin-bottom:.125rem}" +
		".dup-opt{display:flex;align-items:center;gap:.45rem}" +
		".dup-main{max-width:1440px;margin:0 auto;padding:1.5rem 1.25rem 4rem;display:flex;flex-direction:column;gap:2rem}" +
		".dup-group+.dup-group{border-top:1px solid var(--border-color-light);padding-top:2rem}" +
		".dup-group-meta{display:flex;align-items:baseline;gap:.75rem;font-size:.875rem;margin-bottom:.75rem}" +
		".dup-group-error{color:#ef4444;font-size:.8125rem;margin:0 0 .5rem}" +
		".dup-group-actions{display:flex;justify-content:center;gap:.5rem;margin-top:.75rem}" +
		".dup-strip{display:flex;gap:1.5rem;overflow-x:auto;padding:2px 2px .75rem;scroll-snap-type:x proximity}" +
		".dup-card{flex:0 0 280px;scroll-snap-align:start;background:var(--bg-surface);padding:.875rem;border-radius:.5rem;outline:1px solid var(--border-color-light);display:flex;flex-direction:column;gap:.75rem}" +
		".dup-card:has(input[name=\"into\"]:checked){outline:2px solid var(--accent-indigo)}" +
		".dup-preview{display:block;width:100%;aspect-ratio:1/1;object-fit:cover;border-radius:.5rem}" +
		".dup-keep{display:flex;align-items:center;gap:.5rem;font-weight:600;font-size:.875rem;cursor:pointer}" +
		".dup-card .inspector-fields{list-style:none;margin:0;padding:0;gap:0 .75rem}" +
		".dup-tags{display:flex;flex-wrap:wrap;gap:.25rem}" +
		".dup-tag-unique{outline:1px solid var(--accent-indigo)}" +
		"</style></head><body>",
	)

	wr(
		&b,
		"<header class=\"dup-header\">" +
		"<div class=\"dup-bar\">" +
		"<div class=\"dup-bar-left\"><a href=\"/gallery\" class=\"dup-btn\">\u2190 Gallery</a><h1>Duplicates</h1></div>" +
		"<div class=\"dup-bar-right\">" +
		"<button type=\"button\" id=\"dup-reset\" class=\"dup-btn\">Reset</button>" +
		"<button type=\"button\" id=\"dup-apply-all\" class=\"dup-btn dup-btn-primary\" disabled>Apply all (0)</button>" +
		"</div></div>" +
		"<div class=\"dup-settings\" role=\"region\" aria-label=\"Merge settings\">" +
		"<div class=\"dup-settings-col\"><span class=\"dup-settings-label\">Non-mergeable (LWW) fields</span>" +
		"<label class=\"dup-opt\"><input type=\"radio\" name=\"lww_mode\" value=\"merge_comment\" checked/><span>Merge default &amp; comment non-mergeable fields</span></label>" +
		"<label class=\"dup-opt text-muted\"><input type=\"radio\" name=\"lww_mode\" value=\"drop_nonmergeable\" disabled/><span>Drop non-mergeable fields (unimplemented)</span></label>" +
		"<label class=\"dup-opt text-muted\"><input type=\"radio\" name=\"lww_mode\" value=\"target_only\" disabled/><span>Only take target &amp; drop changes (unimplemented)</span></label></div>" +
		"<div class=\"dup-settings-col\"><span class=\"dup-settings-label\">Other settings</span>" +
		"<label class=\"dup-opt text-muted\"><input type=\"checkbox\" disabled/><span>Smart suggest merge target (unimplemented)</span></label>" +
		"<label class=\"dup-opt text-muted\"><input type=\"checkbox\" disabled/><span>Per-field settings (unimplemented)</span></label></div>" +
		"</div></header>",
	)

	wr(&b, "<main id=\"dup-groups\" class=\"dup-main\">")
	wr(
		&b,
		len(groups) == 0 ? "<p id=\"dup-empty\" class=\"text-muted\">No duplicate groups found.</p>" : "<p id=\"dup-empty\" class=\"text-muted\" hidden>No duplicate groups found.</p>",
	)

	for g in groups {
		write_duplicate_group(&b, g)
	}

	wr(&b, "</main><div id=\"toasts-log\"></div>")
	write_toast_template(&b)
	write_duplicates_script(&b)
	wr(&b, "</body></html>")
	return strings.to_string(b)
}

@(private = "file")
write_duplicate_group :: proc(b: ^strings.Builder, g: Duplicate_Group_View) {
	// Count tag occurrences across the group so tags absent from some members
	// can be highlighted as unique.
	tag_counts := make(map[string]int, len(g.items) * 4, context.temp_allocator)
	for item in g.items {
		for t in item.tags {
			tag_counts[t] += 1
		}
	}

	gid_buf: [24]u8
	gid := fmt.bprintf(gid_buf[:], "g%d", g.gid)

	wr(b, "<form class=\"dup-group\"")
	attrf(b, "id", "group-%s", gid)
	attr(b, "data-gid", gid)
	if g.identical {
		wr(b, " data-identical=\"1\"")
	}
	wr(b, "><div class=\"dup-group-meta\"><strong>#")
	escape_text(b, gid)
	wr(b, "</strong><span class=\"text-muted\">")
	textf(b, "%d items \u00b7 max dist %d", len(g.items), g.max_dist)
	if g.identical {
		wr(b, " \u00b7 identical metadata")
	}
	wr(
		b,
		"</span></div><p class=\"dup-group-error\" role=\"alert\" hidden></p><div class=\"dup-strip\" tabindex=\"0\"",
	)
	attrf(b, "aria-label", "Group %s", gid)
	wr(b, ">")

	for item in g.items {
		id_buf: [20]u8
		id := fmt.bprintf(id_buf[:], "%d", item.id)

		wr(b, "<section class=\"dup-card\">")
		if strings.has_prefix(item.content_type, "video/") {
			wr(b, "<video class=\"dup-preview\"")
			attrf(b, "src", "/image/%s", item.oid)
			wr(b, " controls preload=\"none\"></video>")
		} else {
			wr(b, "<img class=\"dup-preview\"")
			if item.content_type == "application/pdf" {
				attr(b, "src", "/static/unsupported_filetype_128.webp")
			} else {
				attrf(b, "src", "/image/%s", item.oid)
			}
			attr(b, "alt", item.name)
			wr(b, " loading=\"lazy\"/>")
		}

		wr(b, "<div class=\"text-muted\">")
		textf(b, "#%s \u00b7 %d \u00d7 %d | %s", id, item.width, item.height, item.content_type)
		wr(b, "</div><label class=\"dup-keep\"><input type=\"radio\" name=\"into\"")
		attr(b, "value", id)
		wr(b, "/> Keep #")
		escape_text(b, id)
		wr(b, "</label><ul class=\"inspector-fields\">")

		write_detail_row(b, "Name", item.name, true)
		write_detail_row(b, "Comment", item.comment, false)

		wr(
			b,
			"<li class=\"inspector-detail-row\"><span class=\"font-medium\">Tags</span><span class=\"dup-tags\">",
		)
		for t in item.tags {
			wr(b, "<span class=\"tag-badge")
			if tag_counts[t] < len(g.items) {
				wr(b, " dup-tag-unique")
			}
			wr(b, "\">")
			escape_text(b, t)
			wr(b, "</span>")
		}
		wr(b, "</span></li>")

		added := ""
		if item.added_at > 0 {
			dt, _ := time.time_to_datetime(time.Time{_nsec = item.added_at * 1_000_000})
			added = fmt.tprintf(
				"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
				dt.year,
				dt.month,
				dt.day,
				dt.hour,
				dt.minute,
				dt.second,
				item.added_at % 1000,
			)
		}
		write_detail_row(b, "Added", added, false)

		wr(b, "</ul></section>")
	}

	wr(
		b,
		"</div><div class=\"dup-group-actions\"><button type=\"reset\" class=\"dup-btn\">Reset</button><button type=\"submit\" class=\"dup-btn dup-btn-primary dup-group-apply\" disabled>Apply</button></div></form>",
	)
}

@(private = "file")
write_duplicates_script :: proc(b: ^strings.Builder) {
	wr(
		b,
		"<script>(function(){\n" +
		"var groupsEl=document.getElementById('dup-groups');\n" +
		"var emptyEl=document.getElementById('dup-empty');\n" +
		"var applyAll=document.getElementById('dup-apply-all');\n" +
		"var resetBtn=document.getElementById('dup-reset');\n" +
		"var busy=false;\n" +
		"function groups(){return Array.from(groupsEl.querySelectorAll('.dup-group'));}\n" +
		"function survivor(g){var r=g.querySelector('input[name=\"into\"]:checked');return r?r.value:'';}\n" +
		"function plan(g){\n" +
		"  var into=survivor(g);\n" +
		"  var from=Array.from(g.querySelectorAll('input[name=\"into\"]')).map(function(r){return r.value;}).filter(function(v){return v!==into;});\n" +
		"  return {gid:g.dataset.gid,into:into,from:from};\n" +
		"}\n" +
		"function setError(g,msg){var e=g.querySelector('.dup-group-error');e.textContent=msg;e.hidden=!msg;}\n" +
		"function fail(g,msg){setError(g,msg);if(window.booruShowLocalToast)booruShowLocalToast(msg,'error');}\n" +
		"function post(url,params){\n" +
		"  return fetch(url,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:params});\n" +
		"}\n" +
		"function sync(){\n" +
		"  var gs=groups(),ready=0;\n" +
		"  gs.forEach(function(g){\n" +
		"    var p=plan(g);\n" +
		"    if(p.into)ready++;\n" +
		"    g.querySelector('.dup-group-apply').disabled=busy||!p.into;\n" +
		"  });\n" +
		"  applyAll.disabled=busy||ready===0;\n" +
		"  applyAll.textContent='Apply all ('+ready+')';\n" +
		"  resetBtn.disabled=busy||gs.length===0;\n" +
		"  emptyEl.hidden=gs.length>0;\n" +
		"  groupsEl.toggleAttribute('inert',busy);\n" +
		"}\n" +
		"groupsEl.addEventListener('change',function(e){\n" +
		"  var g=e.target.closest('.dup-group');if(g)setError(g,'');sync();\n" +
		"});\n" +
		"groupsEl.addEventListener('reset',function(e){\n" +
		"  var g=e.target.closest('.dup-group');if(g)setError(g,'');queueMicrotask(sync);\n" +
		"});\n" +
		"resetBtn.addEventListener('click',function(){\n" +
		"  groups().forEach(function(g){\n" +
		"    g.querySelectorAll('input[name=\"into\"]').forEach(function(r){r.checked=false;});\n" +
		"    setError(g,'');\n" +
		"  });\n" +
		"  sync();\n" +
		"});\n" +
		"groupsEl.addEventListener('submit',async function(e){\n" +
		"  e.preventDefault();\n" +
		"  var g=e.target,p=plan(g);\n" +
		"  if(busy||!p.into)return;\n" +
		"  busy=true;sync();\n" +
		"  try{\n" +
		"    var res=await post('/merge',new URLSearchParams({into:p.into,from:p.from.join(',')}));\n" +
		"    if(res.ok)g.remove();else fail(g,(await res.text())||res.statusText);\n" +
		"  }catch(err){fail(g,String(err));}\n" +
		"  busy=false;sync();\n" +
		"});\n" +
		"applyAll.addEventListener('click',async function(){\n" +
		"  var ready=groups().filter(survivor);\n" +
		"  if(busy||!ready.length)return;\n" +
		"  busy=true;sync();\n" +
		"  for(var i=0;i<ready.length;i++){\n" +
		"    var g=ready[i],p=plan(g);\n" +
		"    try{\n" +
		"      var res=await post('/merge',new URLSearchParams({into:p.into,from:p.from.join(',')}));\n" +
		"      if(res.ok){g.remove();}else{fail(g,(await res.text())||res.statusText);break;}\n" +
		"    }catch(err){fail(g,String(err));break;}\n" +
		"  }\n" +
		"  busy=false;sync();\n" +
		"});\n" +
		"sync();\n" +
		"})();</script>",
	)
}
