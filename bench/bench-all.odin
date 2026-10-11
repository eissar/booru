package bench

// Keep measurements in this package so expensive timing loops stay out of the
// normal test suite and imported packages' tests are not included. Each @(test)
// measurement must manage its own warm-up, repetition, and result consumption;
// the optimized runner supplies neither timing methodology nor protection
// against dead-code elimination. The existing memory-probe main is not executed
// by the test runner, so its process-level measurements remain separate.
