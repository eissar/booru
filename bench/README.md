Benchmarks live here so expensive timing loops stay out of the normal test
suite. There is no task for them yet; run a package by hand, serially, so
benchmarks don't compete for CPU:

    odin test bench -o:speed -define:ODIN_TEST_THREADS=1
    odin test bench/handlers -o:speed -define:ODIN_TEST_THREADS=1
    odin test bench/replay -o:speed -define:ODIN_TEST_THREADS=1
    odin test bench/gallery_zoom -define:ODIN_TEST_THREADS=1

- `bench/` (package `bench`): thumbnail and HTML escape benchmarks. Its `main`
  in `bench.odin` is a memory probe that the test runner does not execute.
- `bench/handlers`: in-process handler throughput, no sockets.
- `bench/replay`: replay of a generated 100k-event log (`.test-data/`).
- `bench/gallery_zoom`: masonry column transitions in headless Chromium over
  CDP (needs chromium and libcurl; `-define:CARDS=n -define:RUNS=n`).

Each `@(test)` measurement must manage its own warm-up, repetition, and result
consumption; the optimized runner supplies neither timing methodology nor
protection against dead-code elimination. Report throughput in bytes (e.g. MiB/s)
alongside event or request rates.

Whole-server throughput is measured separately by `test/tools/bench.sh` (oha).
