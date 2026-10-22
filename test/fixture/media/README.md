# AVIF thumbnail fixtures

`thumbnail.avif` is a generated 192×128, 8-bit YUV420 still image, not downloaded media.
Recreate with:

```sh
ffmpeg -f lavfi -i 'testsrc2=size=192x128:rate=1' -frames:v 1 \
  -c:v libaom-av1 -still-picture 1 -pix_fmt yuv420p thumbnail.avif
```

The thumbnail test extracts the primary AV1 item, decodes it through dav1d,
rescales/encodes with libwebp, then decodes the resulting WebP to check its
requested longest edge. Tests need only the fixture, not ffmpeg.

## Alpha fixture

`thumbnail-alpha.avif` is generated with Pillow 11.3.0: 192×128, 8-bit YUV420
color with monochrome alpha. Its three vertical bands have alpha 0, 128, and 255.
Recreate from the repository root with an AVIF-enabled Pillow installation:

```sh
python3 - <<'PY'
from PIL import Image

image = Image.new("RGBA", (192, 128))
for y in range(image.height):
    for x in range(image.width):
        alpha = 0 if x < 64 else 128 if x < 128 else 255
        image.putpixel((x, y), (220, 60, 30, alpha))
image.save("test/fixture/media/thumbnail-alpha.avif",
           quality=100, subsampling="4:2:0", speed=6)
PY
```

The alpha thumbnail test extracts and decodes both items, runs the thumbnail
encoder at 64px and 128px, and uses webpinfo to verify valid WebP with alpha.
Pillow is needed only to regenerate the fixture, not to run the test.
