#!/usr/bin/env python3
"""Mutation-test the @(mutate) procs of one Odin test package with mull.

    test/tools/mutate.py src/cli [-- extra mull-runner args]

Odin has no clang driver, so mull's IR plugin is applied by hand:

  1. copy the tracked tree to a scratch dir and run mutate_annotate.odin on it,
     which wraps every non-@(mutate) region in mull-off/mull-on comments;
  2. `odin build -build-mode:test -show-system-calls` to learn the link line,
     then `odin test -build-mode:llvm-ir` to get one .ll per module;
  3. compile every .ll with clang -fpass-plugin=mull-ir-frontend;
  4. link with the captured flags and hand the binary to mull-runner.

The worktree is never written. Tools default to the /tmp install described
in test/tools/MUTATION.md; override with MULL_PLUGIN / MULL_RUNNER.
"""

import os
import shlex
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = os.environ.get("MULL_PLUGIN", "/tmp/mull-pkg/usr/lib/mull-ir-frontend-21")
RUNNER = os.environ.get("MULL_RUNNER", "/tmp/mull-deb13/usr/bin/mull-runner")
ODIN_FLAGS = ["-debug", "-custom-attribute:mutate"]


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def main():
    argv = sys.argv[1:]
    runner_args = []
    if "--" in argv:
        i = argv.index("--")
        argv, runner_args = argv[:i], argv[i + 1 :]
    if len(argv) != 1:
        sys.exit(__doc__)
    pkg = argv[0].rstrip("/")
    for tool in (PLUGIN, RUNNER):
        if not os.path.exists(tool):
            sys.exit(f"mutate: missing {tool}; see test/tools/MUTATION.md")

    work = Path(tempfile.mkdtemp(prefix="booru-mutate-"))
    tree = work / "tree"
    print(f"mutate: scratch dir {work}", file=sys.stderr)

    # 1. Scratch copy (tracked + untracked-but-not-ignored files) and annotate.
    files = run(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"],
        cwd=ROOT, capture_output=True,
    ).stdout
    run(["rsync", "-a", "--from0", "--files-from=-", ".", str(tree)], cwd=ROOT, input=files)
    odin_files = sorted(str(p) for p in (tree / "src").rglob("*.odin"))
    annotate = run(
        ["odin", "run", str(ROOT / "test/tools/mutate_annotate.odin"), "-file",
         f"-out:{work}/annotate", "--", *odin_files],
        capture_output=True, text=True,
    ).stdout.split()
    if not annotate:
        sys.exit("mutate: no @(mutate) procs under src/")
    print("mutate: annotated", *(os.path.relpath(f, tree) for f in annotate), file=sys.stderr)

    # 2a. Link line from a normal test build.
    exe = work / "test"
    out = run(
        ["odin", "build", pkg, "-build-mode:test", *ODIN_FLAGS, "-show-system-calls", f"-out:{exe}"],
        cwd=tree, capture_output=True, text=True,
    )
    lines = (out.stdout + out.stderr).splitlines()
    link = next(l.strip() for l in lines if l.strip().startswith("clang ") and f'-o "{exe}"' in l)
    link_args = shlex.split(link)[1:]
    tmp_obj = f"/{exe.name}-"
    keep, skip = [], False
    for a in link_args:
        if skip:
            skip = False
        elif a == "-o":
            skip = True
        elif not (a.endswith(".o") and tmp_obj in a):
            keep.append(a)

    # 2b. One .ll per module.
    ir = work / "ir"
    ir.mkdir()
    run(["odin", "test", pkg, *ODIN_FLAGS, "-build-mode:llvm-ir", f"-out:{ir}"], cwd=tree)

    # 3. Instrument. includePaths keeps mull to the annotated files.
    config = work / "mull.yml"
    config.write_text(
        "junkDetectionDisabled: true\n"
        "includePaths:\n" + "".join(f"  - '^{f}$'\n" for f in annotate)
    )
    env = dict(os.environ, MULL_CONFIG=str(config))
    obj = work / "obj"
    obj.mkdir()

    def compile_ll(ll):
        o = obj / (ll.stem + ".o")
        subprocess.run(
            ["clang", "-c", "-O0", "-Wno-override-module", f"-fpass-plugin={PLUGIN}", str(ll), "-o", str(o)],
            check=True, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return str(o)

    with ThreadPoolExecutor() as pool:
        objs = list(pool.map(compile_ll, sorted(ir.glob("*.ll"))))

    # 4. Link and run.
    mull_exe = work / "test.mull"
    run(["clang", *objs, "-o", str(mull_exe), *keep])
    res = subprocess.run(
        [RUNNER, "--include-not-covered", *runner_args, str(mull_exe)],
        env=env, cwd=tree, capture_output=True, text=True,
    )
    # Report against worktree paths, not the scratch copy.
    report = (res.stdout + res.stderr).replace(f"{tree}/", "")
    report = report.replace(" // mull-on", "").replace(" // mull-off", "")
    print(report, end="")
    sys.exit(res.returncode)


if __name__ == "__main__":
    main()
