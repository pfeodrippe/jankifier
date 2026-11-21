#!/usr/bin/env python3
"""RESULTS.md N3.

A failed eval answers `:ex` with `:status ["done" "eval-error"]` in one
message. nREPL sends `eval-error` and then `done` in a message of its own,
and CIDER 2.1 relies on that: on the combined message it leaks a pending
request (its spinner keeps turning). `jankifier.nrepl` works around it.

    python3 nrepl-done-with-eval-error.py
"""
from _setup import Server, scratch_dir

srv = Server(scratch_dir("repro-n3-"))
try:
    c = srv.connect()
    resps = c.request({"op": "eval", "code": '(throw (ex-info "boom" {}))'}, timeout=120)
    print('expected ["eval-error"] then ["done"], the statuses:', [r["status"] for r in resps if "status" in r])
finally:
    srv.stop()
