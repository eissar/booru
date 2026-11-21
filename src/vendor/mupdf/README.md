# Vendored MuPDF (minimal PDF thumbnailer build)

- **License:** AGPLv3 (`ArtifexSoftware/mupdf`)
- **Enabled third-party libs (`libmupdf-third.a`):** `zlib`, `freetype`, `libjpeg`, `jbig2dec`
- **Disabled:** `harfbuzz`, `openjpeg` (`FZ_ENABLE_JPX=0`), `lcms2` (`FZ_ENABLE_ICC=0`), `mujs` (`FZ_ENABLE_JS=0`), `brotli` (`FZ_ENABLE_BROTLI=0`), `html`/`xps`/`svg`/`extract`/`barcode`/`tofu` Noto & CJK fallback fonts (`tofu=yes tofu_cjk=yes`).

## Build flags used for `linux-amd64`

```sh
make -j$(nproc) libs \
  build=release \
  html=no mujs=no brotli=no xps=no svg=no extract=no barcode=no tofu=yes tofu_cjk=yes \
  USE_SYSTEM_LCMS2=yes SYS_LCMS2_CFLAGS="" SYS_LCMS2_LIBS="" \
  USE_SYSTEM_OPENJPEG=yes SYS_OPENJPEG_CFLAGS="" SYS_OPENJPEG_LIBS="" \
  XCFLAGS="-DFZ_ENABLE_JPX=0 -DFZ_ENABLE_ICC=0 -DFZ_ENABLE_CBZ=0 -DFZ_ENABLE_IMG=0 -DFZ_ENABLE_OCR_OUTPUT=0 -DFZ_ENABLE_ODT_OUTPUT=0"
```

`shim.c` is compiled into `libmupdf-shim.a` and linked before `libmupdf.a` so `fz_load_jpx` / `fz_load_jpx_info` override `load-jpx.o` with a visible 64×64 placeholder instead of aborting the page.
