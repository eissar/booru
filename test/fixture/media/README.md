# AVIF thumbnail fixture

`thumbnail.avif` is a generated 192×128, 8-bit YUV420 still image, not downloaded media.
Recreate with:

```sh
ffmpeg -f lavfi -i 'testsrc2=size=192x128:rate=1' -frames:v 1 \
  -c:v libaom-av1 -still-picture 1 -pix_fmt yuv420p thumbnail.avif
```

The thumbnail test extracts the primary AV1 item, decodes it through dav1d,
rescales/encodes with libwebp, then decodes the resulting WebP to check its
requested longest edge. Tests need only the fixture, not ffmpeg.
