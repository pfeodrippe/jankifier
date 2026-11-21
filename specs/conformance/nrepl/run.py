#!/usr/bin/env python3
"""Conformance of jank's nREPL server with JankSpecs/Nrepl.lean, by outcome
sets (see JankSpecs/Conformance/NreplOutcomes.lean).

    python3 conformance/nrepl/run.py [--random N] [--seed S] [--repeat K]

A scenario is four requests, each with its connection (0 or 1), kind and
session. For each, a fresh `jank repl` is started (outside the jankifier
directory: it writes `.nrepl-port` in its cwd); each connection sends its
requests back to back, both connections at once, and every response is
collected. Then a new connection evals a future which prints `LATE-MARK`
after its eval's capture has ended, and evals again to flush stdio's buffer:
whether the server's stdout shows it is whether stdout was restored. It also
records whether every response carried its request's `id` and `session` (N2),
and whether an unknown op was reported as one (N7). The outcome must be one
the model allows.

Kinds, as jank code:
- evalOk: `(do R)`, evalPrint: `(do (usleep) (println "PR") (usleep) R)`,
- evalThrow: `(throw (ex-info "ER" {}))`, evalStar1: `*1`,
- evalBad: `(do R)` with `"line": "bad"`,
- unknownOp: op `no-such-op`, otherOp: op `describe`.
"""

import argparse
import os
import random
import re
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SPECS = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from jank_harness import Server, dump, scratch_dir  # noqa: E402

KINDS = ["evalOk", "evalPrint", "evalThrow", "evalStar1", "evalBad", "unknownOp", "otherOp"]


def request(r, kind, session, rng):
    sid = f"session-{session}"
    if kind == "evalOk":
        return {"op": "eval", "code": f"(do {r})", "session": sid}
    if kind == "evalPrint":
        a, b = rng.choice([0, 50, 150]) * 1000, rng.choice([0, 50, 150]) * 1000
        return {"op": "eval", "session": sid,
                "code": f'(do (cpp/usleep {a}) (println "P{r}") (cpp/usleep {b}) {r})'}
    if kind == "evalThrow":
        return {"op": "eval", "code": f'(throw (ex-info "E{r}" {{}}))', "session": sid}
    if kind == "evalStar1":
        return {"op": "eval", "code": "*1", "session": sid}
    if kind == "evalBad":
        return {"op": "eval", "code": f"(do {r})", "line": "bad", "session": sid}
    if kind == "unknownOp":
        return {"op": "no-such-op", "session": sid}
    return {"op": "describe", "session": sid}


def observe(scenario, rng, work):
    srv = Server(work)
    try:
        setup = srv.connect()
        # `cpp/usleep` needs its header.
        setup.eval('(cpp/raw "#include <unistd.h>")', timeout=120)
        conns = {c: srv.connect() for c in (0, 1)}
        responses = {r: [] for r in range(4)}
        # Responses whose `id` or `session` isn't their request's (N2).
        untagged = []

        def drive(c):
            conn = conns[c]
            mine = [r for r, (rc, _, _) in enumerate(scenario) if rc == c]
            for r in mine:
                kind, session = scenario[r][1], scenario[r][2]
                msg = request(r, kind, session, rng)
                msg["id"] = str(r)
                conn.send(msg)
            pending = set(mine)
            while pending:
                resp = conn.read(timeout=8)
                if resp is None:
                    return
                rid = resp.get("id")
                rid = int(rid) if isinstance(rid, str) and rid.isdigit() else -1
                if rid not in mine or resp.get("session") != f"session-{scenario[rid][2]}":
                    untagged.append(resp)
                if rid in responses:
                    responses[rid].append(resp)
                    if "done" in (resp.get("status") or []):
                        pending.discard(rid)

        threads = [threading.Thread(target=drive, args=(c,)) for c in (0, 1)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        late = srv.connect()
        late.eval('(do (future (cpp/usleep 300000) (println "LATE-MARK")) nil)', timeout=60)
        time.sleep(1.0)
        # The print is in stdio's buffer; the next eval's capture flushes it
        # (`fflush(stdout)`) to wherever file descriptor 1 points.
        late.eval("nil", timeout=60)
        time.sleep(0.5)
        server_out = "".join(srv.output)
    finally:
        srv.stop()

    parts = []
    for r in range(4):
        resps = responses[r]
        if not any("done" in (x.get("status") or []) for x in resps):
            parts.append(f"r{r}:none")
        elif scenario[r][1] == "unknownOp":
            reported = any({"error", "unknown-op", "done"} <= set(x.get("status") or []) for x in resps)
            parts.append(f"r{r}:unknown-op" if reported else f"r{r}:ok")
        elif scenario[r][1] == "otherOp":
            parts.append(f"r{r}:ok")
        else:
            out = "".join(x.get("out", "") for x in resps)
            outs = sorted({int(x) for x in re.findall(r"P(\d)", out)})
            values = [x["value"] for x in resps if "value" in x]
            value = values[-1] if values else "nil"
            errdone = any({"done", "eval-error"} <= set(x.get("status") or []) for x in resps)
            parts.append(f"r{r}:out={outs},value={value},errdone={'true' if errdone else 'false'}")
    term = sorted({int(x) for x in re.findall(r"^P(\d)$", server_out, re.M)})
    late = "visible" if "LATE-MARK" in server_out else "hidden"
    tagged = "true" if not untagged else "false"
    return f"{' '.join(parts)} term={term} late={late} tagged={tagged}", responses, server_out


def targeted():
    return [
        ("bad-eval-ends-connection", [(0, "evalBad", 0), (0, "evalOk", 0), (1, "evalOk", 0), (1, "evalOk", 0)]),
        ("throw-done-with-error", [(0, "evalThrow", 0), (0, "evalOk", 0), (1, "unknownOp", 0), (1, "otherOp", 0)]),
        ("concurrent-prints", [(0, "evalPrint", 0), (0, "evalPrint", 0), (1, "evalPrint", 0), (1, "evalPrint", 0)]),
        ("sessions-share-star1", [(0, "evalOk", 0), (0, "evalStar1", 1), (1, "evalStar1", 0), (1, "evalOk", 1)]),
    ]


def random_scenario(rng):
    return [(rng.randrange(2), rng.choice(KINDS), rng.randrange(2)) for _ in range(4)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--random", type=int, default=10)
    ap.add_argument("--repeat", type=int, default=3, help="runs of each scenario")
    ap.add_argument("--seed", type=int, default=1)
    ns = ap.parse_args()
    rng = random.Random(ns.seed)
    scenarios = targeted() + [(f"random-{ns.seed}-{i}", random_scenario(rng)) for i in range(ns.random)]

    work = scratch_dir("nrepl-")
    checks = []
    for name, sc in scenarios:
        seen = []
        for k in range(ns.repeat):
            outcome, responses, server_out = observe(sc, rng, work)
            dump(os.path.join(work, f"{name}-{k}.json"),
                 {"scenario": sc, "outcome": outcome, "responses": responses, "server_out": server_out[-4000:]})
            if outcome not in seen:
                seen.append(outcome)
        print(f"== {name}: {sc}", flush=True)
        for o in seen:
            print(f"   {o}", flush=True)
        conns = [c for c, _, _ in sc]
        kinds = ", ".join("." + k for _, k, _ in sc)
        sessions = [s for _, _, s in sc]
        observed = "[" + ", ".join('"' + o + '"' for o in seen) + "]"
        checks.append(f'#eval check "{name}" (nreplOutcomes {conns} [{kinds}] {sessions}) {observed}\n')

    gen = os.path.join(SPECS, "JankSpecs", "Conformance", "NreplObserved.lean")
    with open(gen, "w") as f:
        f.write("-- Generated by conformance/nrepl/run.py: outcomes of the real jank.\n"
                "import JankSpecs.Conformance.NreplOutcomes\n\nopen Nrepl.Outcomes JankSpecs.Outcomes\n\n"
                + "\n".join(checks))
    p = subprocess.run(["lake", "build", "JankSpecs.Conformance.NreplObserved"], cwd=SPECS,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = re.findall(r"(?:info|error): JankSpecs/Conformance/NreplObserved\.lean:\d+:\d+: (.*)", p.stdout)
    print(f"\n== against the model ({work})")
    for l in lines:
        print("   " + l[:600])
    ok = p.returncode == 0 and len(lines) == len(checks) and all("conforms" in l for l in lines)
    if p.returncode != 0 and not lines:
        print(p.stdout[-3000:])
    print("\nOK" if ok else "\nFAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
