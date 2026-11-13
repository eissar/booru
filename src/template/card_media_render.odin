package template

import "../library"
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
		ia(b, "width", image.width)
		ia(b, "height", image.height)
		attr(b, "style", aspect_ratio)
		wr(b, " class=\"gallery-card-image order-1\"></video>")
	case:
		wr(b, "<img")
		attrf(b, "src", "/image/%s", image.oid)
		wr(b, " loading=\"lazy\"")
		wr(
			b,
			render_order >= 0 && render_order < 6 ? " fetchpriority=\"high\"" : " fetchpriority=\"low\"",
		)
		ia(b, "width", image.width)
		ia(b, "height", image.height)
		attr(b, "style", aspect_ratio)
		wr(b, " class=\"gallery-card-image order-1\"/>")
	}
}
