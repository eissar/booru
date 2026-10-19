package server

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../library"

@(test)
benchmark_gallery_filters_before_pagination :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "booru-benchmark-*", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	if !testing.expect(
		t,
		os.mkdir_all(fmt.tprintf("%s/thumbnails/64", root), os.Permissions_Default_Directory) ==
		nil,
	) {return}
	for oid in ([]string{"aa", "cc"}) {
		if !testing.expect(
			t,
			os.write_entire_file(fmt.tprintf("%s/thumbnails/64/%s.webp", root, oid), {1}) == nil,
		) {return}
	}
	images := [?]library.Image {
		{id = 1, oid = "aa", content_type = "image/png"},
		{id = 2, oid = "bb", content_type = "image/jpeg"}, // no thumbnail
		{id = 3, oid = "cc", content_type = "video/mp4"}, // exclude even with a file
	}
	filtered := filter_gallery_images(images[:], {thumbnails_only = true}, root)
	defer delete(filtered)
	testing.expect(t, len(filtered) == 1)
	if len(filtered) == 1 {testing.expect(t, filtered[0].id == 1)}
	testing.expect(t, len(images) == 3, "source remains unchanged")
	page, has_more := page_slice(filtered, 0, 10)
	testing.expect(t, len(page) == 1 && !has_more)
	ordinary := filter_gallery_images(images[:], {}, root)
	defer delete(ordinary)
	testing.expect(t, len(ordinary) == 3, "normal gallery remains unfiltered")
}

@(test)
benchmark_gallery_query_is_opt_in :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for query in ([]string{"", "thumbnails_only=0", "thumbnails_only=no"}) {
		q, ok := parse_gallery_query(query)
		testing.expect(t, ok && !q.thumbnails_only)
	}
	q, ok := parse_gallery_query("limit=100&thumbnails_only=1")
	testing.expect(t, ok && q.thumbnails_only)
	gallery_url, fragment_url := filter_urls(q)
	testing.expect(t, strings.contains(gallery_url, "thumbnails_only=1"))
	testing.expect(t, strings.contains(fragment_url, "thumbnails_only=1"))
}
