#!/usr/bin/env python3
"""RESULTS.md N4 and N5 (determinismo's jank analysis, §3.3, has the same).

Output capture swaps the process's own stdout (`dup`, `fflush`, `dup2` a temp
file over it, and back), and `println` writes to C's buffered stdout. Two
connections evaluating at once interleave those steps: an eval's `:out` gets
the other's print, or loses its own to the server's stdout (N4); and stdout
can be left pointing at a deleted temp file, so everything printed outside an
eval afterwards is lost (N5). Nondeterministic: 20 rounds of two concurrent
evals that print, then a future that prints after its eval.

    python3 nrepl-concurrent-output-swap.py
"""
import threading
import time
from _setup import Server, scratch_dir

srv = Server(scratch_dir("repro-n4-"))
try:
    setup = srv.connect()
    setup.eval('(cpp/raw "#include <unistd.h>")', timeout=120)
    conns = [srv.connect(), srv.connect()]
    swapped = 0
    for rnd in range(20):
        outs = [None, None]

        def run(i):
            code = f'(do (cpp/usleep 50000) (println "MARK-{rnd}-{i}") (cpp/usleep 50000) {i})'
            outs[i] = conns[i].eval(code, timeout=60)["out"]

        ts = [threading.Thread(target=run, args=(i,)) for i in range(2)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        if any((outs[i] or "").strip() != f"MARK-{rnd}-{i}" for i in range(2)):
            swapped += 1
    print("expected 0, rounds where an eval's :out wasn't exactly its own print, of 20:", swapped)
    late = srv.connect()
    late.eval('(do (future (cpp/usleep 300000) (println "LATE-MARK")) nil)', timeout=60)
    time.sleep(1.0)
    late.eval("nil", timeout=60)  # its capture flushes stdio's buffer
    time.sleep(0.5)
    print("expected visible, a future's print after the rounds, on the server's stdout:",
          "visible" if "LATE-MARK" in "".join(srv.output) else "lost")
finally:
    srv.stop()
