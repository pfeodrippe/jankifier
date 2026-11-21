#!/usr/bin/env python3
"""RESULTS.md N6 (determinismo's jank analysis, §3.4, has the same cause).

Sessions aren't tracked: `clone` returns a new id, and nothing keeps state by
it. `*1` is the connection thread's binding, so an eval of `*1` in one
session returns the last value of another session on the same connection.

    python3 nrepl-sessions-share-star1.py
"""
from _setup import Server, scratch_dir

srv = Server(scratch_dir("repro-n6-"))
try:
    c = srv.connect()
    s1 = next(r["new-session"] for r in c.request({"op": "clone"}) if "new-session" in r)
    s2 = next(r["new-session"] for r in c.request({"op": "clone"}) if "new-session" in r)
    c.eval("42", session=s1, timeout=120)
    print("expected [nil], *1 in a session that evaluated nothing:", c.eval("*1", session=s2, timeout=60)["value"])
finally:
    srv.stop()
