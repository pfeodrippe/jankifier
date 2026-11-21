"""Shared by the reproduction scripts: the conformance harness's jank runner
and nREPL client, and scratch directories (under conformance/out/, ignored by
git; a `jank repl` writes `.nrepl-port` in its directory)."""

import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "conformance", "lib"))
from jank_harness import Server, jank_args, run_jank, scratch_dir  # noqa: E402,F401


def write(path, text):
    with open(path, "w") as f:
        f.write(text)
    # Later writes must get a later mtime than the object files compiled before them.
    time.sleep(1.1)


def lines(out, prefix="expected"):
    return "\n".join(l for l in out.splitlines() if l.startswith(prefix))
