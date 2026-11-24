#include <mupdf/fitz.h>
#include <stdlib.h>
#include <string.h>

#define JPX_PH_SIZE 64

/* Link-time override for load-jpx.o in libmupdf.a when FZ_ENABLE_JPX=0.
 * Draws a visible placeholder so JPX images are not silently hidden. */
fz_pixmap *
fz_load_jpx(fz_context *ctx, const unsigned char *data, size_t size, fz_colorspace *defcs)
{
	(void)data;
	(void)size;
	(void)defcs;

	fz_pixmap *pix = fz_new_pixmap(ctx, fz_device_rgb(ctx), JPX_PH_SIZE, JPX_PH_SIZE, NULL, 0);
	unsigned char *s = pix->samples;
	int stride = pix->stride;

	for (int y = 0; y < JPX_PH_SIZE; y++) {
		for (int x = 0; x < JPX_PH_SIZE; x++) {
			unsigned char *p = s + y * stride + x * 3;
			int is_border = (x < 2 || x >= JPX_PH_SIZE - 2 || y < 2 || y >= JPX_PH_SIZE - 2);
			int d1 = x - y;
			int d2 = x - (JPX_PH_SIZE - 1 - y);
			int is_cross = (d1 >= -1 && d1 <= 1) || (d2 >= -1 && d2 <= 1);
			if (is_border || is_cross) {
				p[0] = 180;
				p[1] = 83;
				p[2] = 9;
			} else {
				p[0] = 243;
				p[1] = 244;
				p[2] = 246;
			}
		}
	}
	return pix;
}

void
fz_load_jpx_info(
	fz_context *ctx,
	const unsigned char *data,
	size_t size,
	int *wp,
	int *hp,
	int *xresp,
	int *yresp,
	fz_colorspace **cspacep,
	fz_colorspace *defcs)
{
	(void)data;
	(void)size;
	(void)defcs;
	*cspacep = fz_keep_colorspace(ctx, fz_device_rgb(ctx));
	*wp = JPX_PH_SIZE;
	*hp = JPX_PH_SIZE;
	*xresp = 72;
	*yresp = 72;
}

int
mupdf_probe_dimensions(const char *path, int *out_w, int *out_h)
{
	if (!path || !out_w || !out_h) return 0;

	fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
	if (!ctx) return 0;

	fz_document *doc = NULL;
	fz_page *page = NULL;
	int ok = 0;

	fz_var(doc);
	fz_var(page);

	fz_try(ctx) {
		fz_register_document_handlers(ctx);
		doc = fz_open_document(ctx, path);
		if (fz_count_pages(ctx, doc) > 0) {
			page = fz_load_page(ctx, doc, 0);
			fz_rect bounds = fz_bound_page(ctx, page);
			int w = (int)(bounds.x1 - bounds.x0 + 0.5f);
			int h = (int)(bounds.y1 - bounds.y0 + 0.5f);
			if (w > 0 && h > 0) {
				*out_w = w;
				*out_h = h;
				ok = 1;
			}
		}
	}
	fz_always(ctx) {
		fz_drop_page(ctx, page);
		fz_drop_document(ctx, doc);
	}
	fz_catch(ctx) {
		ok = 0;
	}

	fz_drop_context(ctx);
	return ok;
}

/* Caller-supplied positional reader: fills up to n bytes at offset and returns
 * the byte count (0 at end of input) or -1 on error. */
typedef int64_t(mupdf_read_at_fn)(void *opaque, unsigned char *buf, size_t n, int64_t offset);

typedef struct {
	void *opaque;
	mupdf_read_at_fn *read_at;
	int64_t size;
	unsigned char buf[64 * 1024];
} read_at_state;

static int
next_read_at(fz_context *ctx, fz_stream *stm, size_t max)
{
	/* Like fz_open_file, fill the whole buffer regardless of max: mupdf passes
	 * max = 1 from fz_read_byte, and honouring it costs one read per byte. */
	(void)max;
	read_at_state *st = stm->state;
	int64_t got = st->read_at(st->opaque, st->buf, sizeof st->buf, stm->pos);
	if (got < 0) fz_throw(ctx, FZ_ERROR_SYSTEM, "read_at failed");
	stm->rp = st->buf;
	stm->wp = st->buf + got;
	stm->pos += got;
	if (got == 0) return EOF;
	return *stm->rp++;
}

static void
seek_read_at(fz_context *ctx, fz_stream *stm, int64_t offset, int whence)
{
	read_at_state *st = stm->state;
	int64_t pos = offset;
	if (whence == SEEK_END) pos = st->size + offset;
	if (whence == SEEK_CUR) pos = stm->pos + offset;
	if (pos < 0 || pos > st->size) fz_throw(ctx, FZ_ERROR_ARGUMENT, "seek out of range");
	/* stm->pos is the offset of wp; reuse the buffer when pos is already in it. */
	int64_t start = stm->pos - (stm->wp - st->buf);
	if (stm->wp > st->buf && pos >= start && pos <= stm->pos) {
		stm->rp = st->buf + (pos - start);
		return;
	}
	stm->pos = pos;
	stm->rp = stm->wp = st->buf;
}

static void
drop_read_at(fz_context *ctx, void *state)
{
	fz_free(ctx, state);
}

/* Renders the first page of a document read through read_at (size bytes long). */
int
mupdf_render_first_page_rgba(
	void *opaque,
	mupdf_read_at_fn *read_at,
	int64_t size,
	int max_edge,
	int *out_w,
	int *out_h,
	unsigned char **out_pixels)
{
	if (!read_at || size < 0 || max_edge <= 0 || !out_w || !out_h || !out_pixels) return 0;

	fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
	if (!ctx) return 0;

	fz_document *doc = NULL;
	fz_page *page = NULL;
	fz_pixmap *pix = NULL;
	fz_device *dev = NULL;
	unsigned char *buf = NULL;
	fz_stream *stm = NULL;
	int ok = 0;

	fz_var(doc);
	fz_var(page);
	fz_var(pix);
	fz_var(dev);
	fz_var(buf);
	fz_var(stm);

	fz_try(ctx) {
		fz_register_document_handlers(ctx);
		read_at_state *st = fz_malloc_struct(ctx, read_at_state);
		st->opaque = opaque;
		st->read_at = read_at;
		st->size = size;
		stm = fz_new_stream(ctx, st, next_read_at, drop_read_at);
		stm->seek = seek_read_at;
		doc = fz_open_document_with_stream(ctx, "application/pdf", stm);
		if (fz_count_pages(ctx, doc) <= 0) {
			fz_throw(ctx, FZ_ERROR_GENERIC, "document has no pages");
		}
		page = fz_load_page(ctx, doc, 0);
		fz_rect bounds = fz_bound_page(ctx, page);
		float pw = bounds.x1 - bounds.x0;
		float ph = bounds.y1 - bounds.y0;
		if (pw <= 0 || ph <= 0) {
			fz_throw(ctx, FZ_ERROR_GENERIC, "invalid page bounds");
		}

		float scale = (float)max_edge / (pw > ph ? pw : ph);
		fz_matrix ctm = fz_scale(scale, scale);
		fz_irect bbox = fz_round_rect(fz_transform_rect(bounds, ctm));
		if (bbox.x1 <= bbox.x0) bbox.x1 = bbox.x0 + 1;
		if (bbox.y1 <= bbox.y0) bbox.y1 = bbox.y0 + 1;
		int w = bbox.x1 - bbox.x0;
		int h = bbox.y1 - bbox.y0;
		if (w <= 0 || h <= 0) {
			fz_throw(ctx, FZ_ERROR_GENERIC, "invalid rasterized bounds");
		}

		pix = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), bbox, NULL, 1);
		fz_clear_pixmap_with_value(ctx, pix, 255);

		dev = fz_new_draw_device(ctx, fz_identity, pix);
		fz_run_page(ctx, page, dev, ctm, NULL);
		fz_close_device(ctx, dev);
		fz_drop_device(ctx, dev);
		dev = NULL;

		size_t row_bytes = (size_t)w * 4;
		buf = (unsigned char *)malloc(row_bytes * (size_t)h);
		if (!buf) {
			fz_throw(ctx, FZ_ERROR_GENERIC, "out of memory");
		}
		for (int y = 0; y < h; y++) {
			memcpy(buf + (size_t)y * row_bytes, pix->samples + (size_t)y * (size_t)pix->stride, row_bytes);
		}

		*out_w = w;
		*out_h = h;
		*out_pixels = buf;
		buf = NULL;
		ok = 1;
	}
	fz_always(ctx) {
		free(buf);
		fz_drop_device(ctx, dev);
		fz_drop_pixmap(ctx, pix);
		fz_drop_page(ctx, page);
		fz_drop_document(ctx, doc);
		fz_drop_stream(ctx, stm);
	}
	fz_catch(ctx) {
		ok = 0;
	}

	fz_drop_context(ctx);
	return ok;
}

void
mupdf_free_pixels(void *p)
{
	free(p);
}
