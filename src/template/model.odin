package template

// Shared view models for the HTML templates.

Image :: struct {
	id:            int,
	oid:           string,
	thumbnail_oid: string,
	path:          string,
	tags:          []string,
	width:         int,
	height:        int,
	name:          string,
	mtime:         string,
	added_at:      string,
	content_type:  string,
}
