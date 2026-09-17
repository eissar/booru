package template

import "core:strings"

// Toast_Variant selects the CSS modifier class for a toast.
Toast_Variant :: enum {
	Default,
	Success,
	Error,
}

// render_toast renders a dismissible toast notification.
render_toast :: proc(message: string, variant: Toast_Variant) -> string {
	b := strings.builder_make()
	wr(&b, "<div class=\"booru-toast ")
	switch variant {
	case .Success: wr(&b, "booru-toast-success")
	case .Error:   wr(&b, "booru-toast-error")
	case .Default:
	}
	wr(&b, "\" role=\"alert\"><span>")
	escape_text(&b, message)
	wr(&b, "</span><button type=\"button\" class=\"booru-toast-dismiss\" hx-on-click=\"this.closest('.booru-toast').remove()\">Dismiss</button></div>")
	return strings.to_string(b)
}