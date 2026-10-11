# Performance Audit TODO

- Build a Lighthouse-like resource audit for representative Odin workloads:
  - Use AST search to identify semantic operations (allocation, buffer touch, cleanup, image decode, indexing, request handling) and generate debugger breakpoints with meaningful labels.
  - Capture timestamped events, call stacks, relevant variables, and resource samples at operation boundaries; distinguish before/after execution rather than treating a breakpoint on a call as its completion.
  - Sample cgroup memory and CPU externally, keeping the debugger and sampler outside the measured cgroup. Track `memory.current`, `memory.peak`, `memory.stat` components, and `cpu.stat`.
  - Combine samples and semantic events into annotated timelines and per-operation reports: elapsed/CPU time, memory growth, peak footprint, and memory retained after cleanup, for identical work across runs.
  - Use two passes: a debugger-assisted diagnostic pass for attribution, and an unpaused performance pass for realistic timing and peaks. Record debugger pause durations and avoid presenting instrumented timing as normal execution time.
  - Start with the existing benchmark's allocate → touch → free stages. Account for batched kernel counters and peaks missed by polling; AST matches identify candidate events, not proof of resource attribution.


# LOD 0 Micro-Atlas TODO

1. Vendor libwebp into a new `src/img-slop/` package with Odin foreign imports and a decode/encode smoke test.
2. Port the Go atlas builder: decode every thumbnail → 48px micro thumb → pack 2048² sheets → PNG-encode to a content-keyed disk cache, and add `micro_page/x/y/w/h` fields to `library.Image` plus an immutable-cached `/api/atlas/:key/page_N.png` handler.
3. Swap the card renderer to a CSS-sprite div using the atlas as LOD 0 with the existing webp thumbs lazy-loaded as LOD 1, then update the render fixture tests.
4. Harden the provisional mipmap handler: replace sequential sends with writev, right-size the arena, use configured thumbnail paths/cache, and assert response correctness in tests.
