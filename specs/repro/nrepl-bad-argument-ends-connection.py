#!/usr/bin/env python3
"""RESULTS.md N1.

An eval request whose arguments don't convert (here `"line": "bad"`) throws
outside `safe-eval`, which ends the connection's loop: that request and every
later one on the same connection get no response, and the client waits
forever. Other connections keep working.

    python3 nrepl-bad-argument-ends-connection.py
"""
from _setup import Server, scratch_dir

srv = Server(scratch_dir("repro-n1-"))
try:
    c, other = srv.connect(), srv.connect()
    msg_id = c.send({"op": "eval", "code": "(+ 1 2)", "line": "bad"})
    bad, done = c.until_done(msg_id, timeout=20)
    print("expected a response (an error), to the request with a bad line:", bad if bad else "none in 20 s")
    r = c.eval("(+ 1 2)", timeout=20)
    print("expected [3], a good request on the same connection after it:", r["value"] or "no response in 20 s")
    print("expected [3], the same on another connection:", other.eval("(+ 1 2)", timeout=60)["value"])
finally:
    srv.stop()
