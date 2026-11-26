"""Sums up a run of the reproductions (run_all.py) and of the Lean replica's tests
(run_replica_tests.py) on one platform, per repros.md item, and compares it with the run
recorded for that platform in baseline/PLATFORM.json.

    python3 check_runs.py --platform macos-arm64 --repro R.json --replica T.json
    python3 check_runs.py ... --write-baseline        # record this run as the platform's

It prints Markdown (for a CI job's summary): the build, the items that look fixed here (every
check got Clojure's result, or every test passes), and what changed since the recorded run.
It exits 1 when something changed, so a scheduled job fails and says so; with no recorded run
it only reports.

What counts as a change: for a reproduction, what any of its checks got (temporary paths
aside), or for the ones whose counts vary from run to run or that show only sometimes (VARIES),
its verdict; for a replica test, its outcome (pass, fail, exit N, timeout). --changed-out lists
what changed, for the CI job to run it a second time before it compares again.
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Reproductions that count races or dispatch orders: their numbers differ from run to run.
VARIES = {
    "binding-frames-never-freed.jank", "binding-leaks-across-futures.cljc",
    "compare-and-set-spurious-failure.cljc", "defonce-race.cljc",
    "multimethod-dispatch-depends-on-hash-order.cljc", "nrepl-concurrent-output-swap.py",
    "require-race.cljc", "with-redefs-race.cljc",
}


def norm_got(got):
    return re.sub(r"(/private)?/(var/folders|tmp)/\S*", "<tmp>", got)


def shape(repro):
    """{file: {what: got or same}} — what is compared between runs."""
    out = {}
    for name, r in repro.items():
        key = {}
        for i, c in enumerate(r.get("checks", [])):
            what = c["what"] or f"check {i + 1}"
            key[what] = norm_got(c["got"])
        key["(ended)"] = r["ended"] if not r["ended"].startswith("still running") else "still running"
        # Counts that vary from run to run, and findings that show only sometimes (N5): the
        # verdict alone.
        out[name] = {"verdict": r["verdict"]} if name in VARIES else key
    return out


def items(md):
    """[(id, repro files, test prefixes)] for each item of repros.md."""
    out = []
    tok = r"`([a-z]{1,3}[0-9]+[a-z]?)`"
    for line in open(md, encoding="utf-8"):
        m = re.match(r"^- \[[ x]\] \*\*([^*]+)\*\*(.*)", line)
        if not m:
            continue
        ident, text = m.group(1), m.group(2)
        files = re.findall(r"repro/([\w.-]+\.(?:cljc|jank|py))", text)
        refs = []
        for g in re.finditer(r"`[\w]+\.jank`:\s*((?:`[a-z]{1,3}[0-9]+[a-z]?`[^`;)]*)+)", text):
            refs += [r for r in re.findall(tok, g.group(1))]
        for g in re.finditer(r"\(((?:`[a-z]{1,3}[0-9]+[a-z]?`(?:\s*,\s*)?)+)[);]", text):
            refs += re.findall(tok, g.group(1))
        # A control test (named so in the item) passes by design: not the finding's.
        controls = re.findall(r"control `?([a-z]{1,3}[0-9]+[a-z]?)`? passes", text)
        refs = sorted(set(refs) - set(controls))
        out.append((ident, files, refs))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", required=True)
    ap.add_argument("--repro", required=True)
    ap.add_argument("--replica", required=True)
    ap.add_argument("--repros-md", default=os.path.join(HERE, "..", "repros.md"))
    ap.add_argument("--baseline", default=os.path.join(HERE, "baseline"))
    ap.add_argument("--build", default=os.environ.get("JANK_BUILD_INFO", ""))
    ap.add_argument("--write-baseline", action="store_true")
    ap.add_argument("--changed-out", help="write what changed here, to run it again: "
                    "a line `repro FILE` or `replica TEST-ID` each")
    a = ap.parse_args()

    repro = json.load(open(a.repro))
    replica_raw = json.load(open(a.replica))
    replica = {k.split("/", 1)[1]: v for k, v in replica_raw.items()}
    now = {"build": a.build, "repro": shape(repro), "replica": replica}

    p = print
    p(f"## jank repros on {a.platform}\n")
    if a.build:
        p(f"jank: {a.build}\n")
    counts = {}
    for v in replica.values():
        counts[v] = counts.get(v, 0) + 1
    still = sum(1 for r in repro.values() if r["verdict"] == "still there")
    p(f"Reproductions: {len(repro)} files, {still} still there. "
      f"Replica tests: {len(replica)}, " + ", ".join(f"{n} {k}" for k, n in sorted(counts.items())) + ".\n")

    fixed, partly = [], []
    for ident, files, refs in items(a.repros_md):
        tests = [t for t in replica if any(t.startswith(r + "-") for r in refs)]
        outs = [replica[t] for t in tests] + [repro[f]["verdict"] for f in files if f in repro]
        good = [o for o in outs if o in ("pass", "like Clojure")]
        if outs and len(good) == len(outs):
            fixed.append(ident)
        elif good:
            partly.append(f"{ident} ({len(good)} of {len(outs)})")
    p("### Items whose checks all get Clojure's result here (fixed, or not on this platform)\n")
    p(", ".join(fixed) if fixed else "None.")
    if partly:
        p(f"\nIn part: {', '.join(partly)}.")
    p("")

    path = os.path.join(a.baseline, a.platform + ".json")
    changed, again = [], []
    if os.path.exists(path):
        base = json.load(open(path))
        for name in sorted(set(base["repro"]) | set(now["repro"])):
            b, n = base["repro"].get(name), now["repro"].get(name)
            if b != n:
                diffs = [f"{w}: {b.get(w) if b else None!r} → {n.get(w) if n else None!r}"
                         for w in sorted(set(b or {}) | set(n or {}))
                         if (b or {}).get(w) != (n or {}).get(w)]
                changed.append(f"- `{name}`: " + "; ".join(diffs[:4]))
                again.append(f"repro {name}")
        for t in sorted(set(base["replica"]) | set(now["replica"])):
            b, n = base["replica"].get(t), now["replica"].get(t)
            if b != n:
                changed.append(f"- `{t}`: {b} → {n}")
                again.append(f"replica {t.split('-')[0]}")
        p(f"### Changes since the recorded run ({base.get('build') or 'build not recorded'})\n")
        p("\n".join(changed) if changed else "None.")
    else:
        p(f"### No recorded run for {a.platform}\n")
        p("This run can be recorded with `--write-baseline`.")
    if a.changed_out:
        with open(a.changed_out, "w") as f:
            f.write("".join(x + "\n" for x in again))
    if a.write_baseline:
        os.makedirs(a.baseline, exist_ok=True)
        json.dump(now, open(path, "w"), indent=1, sort_keys=True, ensure_ascii=False)
        p(f"\nRecorded as {os.path.normpath(path)}.")
    sys.exit(1 if changed else 0)


if __name__ == "__main__":
    main()
