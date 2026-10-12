e2e tests go in here; unit tests (if we choose to implement such) will go
next to the defined code.

so package main with main.odin:
will have a main_test.odin with unit tests annotated with @(test)

Streaming client browser probe:

```sh
node test/streaming-client.mjs
```

Requires Chromium (`CHROMIUM` can override the executable) and a Node version
with built-in `WebSocket` support. No npm dependencies. Runs the actual
`static/benchmark.html` against a local, delayed animated WebP response built
from a thumbnail fixture. Checks decoding, uploading, and drawing before EOF,
130 frames across texture batches, a persistent GPU thumbnail cache, complete
100-slot redraws with a non-preserved drawing buffer, resize without fetch/upload,
temporary texture cleanup, byte counts, fresh benchmark fetches, and HTTP errors.
This is separate from `task test`; it does not start the Odin server.

