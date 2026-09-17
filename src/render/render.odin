package render

import "../template"

// Renderer_Version is stamped onto rendered gallery pages for cache/debugging.
Renderer_Version :: "default"

// Render_Image is the caller-facing image view model.
Render_Image :: template.Image

// render_toast renders a toast notification.
render_toast :: proc(message: string, variant: template.Toast_Variant) -> string {
	return template.render_toast(message, variant)
}

// Render_Card_Grid_Input is the input for render_card_grid.
Render_Card_Grid_Input :: struct {
	cards:    []Render_Image,
	offset:   int,
	has_more: bool,
}

// render_card_grid renders the photo grid fragment.
render_card_grid :: proc(input: Render_Card_Grid_Input) -> string {
	return template.render_photo_grid(input.cards, input.offset, input.has_more)
}

// render_item_card renders one image card.
render_item_card :: proc(image: Render_Image, render_order: int) -> string {
	return template.render_item_card(image, render_order)
}

// render_inspector renders the inspector fragment for one image.
render_inspector :: proc(image: Render_Image) -> string {
	return template.render_inspector(image)
}

// Gallery_Filter re-exports the template filter model.
Gallery_Filter :: template.Gallery_Filter

// render_gallery_content renders the replaceable gallery content region.
render_gallery_content :: proc(filter: Gallery_Filter, images: []Render_Image, has_more: bool) -> string {
	return template.render_gallery_content(filter, images, has_more)
}

// render_gallery_page renders the full initial gallery document.
render_gallery_page :: proc(title, version: string, filter: Gallery_Filter, images: []Render_Image, has_more: bool) -> string {
	return template.render_gallery_page(title, version, filter, images, has_more)
}