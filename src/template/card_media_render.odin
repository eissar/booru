package template

import "../library"
import "../thumbnail"
import "core:strings"

// write_card_media emits the card's media element, dispatching on image.content_type.
write_card_media :: proc(
	b: ^strings.Builder,
	image: library.Image,
	render_order: int,
	aspect_ratio: string,
) {
	switch {
	case strings.has_prefix(image.content_type, "video/"):
		wr(b, "<video")
		attrf(b, "src", "/image/%s", image.oid)
		wr(
			b,
			" preload=\"none\" muted loop playsinline onpointerenter=\"this.play()\" onpointerleave=\"this.pause()\"",
		)
		if image.width > 0 && image.height > 0 {
			ia(b, "width", image.width)
			ia(b, "height", image.height)
		}
		attr(b, "style", aspect_ratio)
		wr(b, " class=\"gallery-card-media order-1\"></video>")
	case strings.has_prefix(image.content_type, "image/"):
		wr(b, "<img")
		attrf(b, "src", "/image/%s", image.oid)
		wr(b, " loading=\"lazy\" decoding=\"async\"")
		if render_order >= 0 && render_order < 6 {
			wr(b, " fetchpriority=\"high\"")
		} else {
			wr(b, " fetchpriority=\"low\"")
		}
		if image.width > 0 && image.height > 0 {
			ia(b, "width", image.width)
			ia(b, "height", image.height)
		}
		attr(b, "style", aspect_ratio)
		wr(b, " class=\"gallery-card-media order-1\"/>")
	case .max in thumbnail.expected_resolutions(image.content_type):
		wr(b, "<img")
		attrf(b, "src", "/thumbnails/max/%s.webp", image.oid)
		wr(b, " loading=\"lazy\" decoding=\"async\"")
		if render_order >= 0 && render_order < 6 {
			wr(b, " fetchpriority=\"high\"")
		} else {
			wr(b, " fetchpriority=\"low\"")
		}
		if image.width > 0 && image.height > 0 {
			ia(b, "width", image.width)
			ia(b, "height", image.height)
		}
		attr(b, "style", aspect_ratio)
		wr(b, " class=\"gallery-card-media order-1\"/>")
	case:
		wr(b, "<img")
		attr(b, "src", "/static/unsupported_filetype_128.webp")
		wr(b, " loading=\"lazy\" decoding=\"async\"")
		if render_order >= 0 && render_order < 6 {
			wr(b, " fetchpriority=\"high\"")
		} else {
			wr(b, " fetchpriority=\"low\"")
		}
		if image.width > 0 && image.height > 0 {
			ia(b, "width", image.width)
			ia(b, "height", image.height)
		}
		attr(b, "style", aspect_ratio)
		wr(b, " class=\"gallery-card-media order-1\"/>")
	}
}
