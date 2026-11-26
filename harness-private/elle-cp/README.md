# elle-cp: staging and grading for the closed-predicate trial

The agents translate Elle's `closed_predicate.clj` into Lean on top of the replica's base modules,
write a specification, and compare the two (the task text is `ELLE.md`). This directory holds what
they are given (`stage/`) and the private grader (`grader/`).


## Credit and license

The Lean base modules (`stage/lean/Elle/`, sanitized, and `grader/Elle/`, as they are) and the
human `ClosedPredicate.lean` the grader compares with are from the Lean replica of Elle in
[determinismo-workloads](https://github.com/determinismo-dst/determinismo-workloads)
(`workloads/elle/lean`), a translation of Elle's code. `closed_predicate.clj` is Elle's
([jepsen-io/elle](https://github.com/jepsen-io/elle), copyright Jepsen, LLC and Peter Alvaro).
Both are under the Eclipse Public License 2.0 (`stage/elle/LICENSE`).

## Layout

```
elle-cp/
  ELLE.md                        the agents' task text (was already here; not changed)
  README.md                      this file
  stage/                         given to the agents
    elle/closed_predicate.clj    upstream Elle 4e359e5, whole file, unmodified
    elle/LICENSE                 Elle's license (EPL-2.0)
    lean/lean-toolchain          leanprover/lean4:v4.35.0
    lean/lakefile.toml           lean_lib Elle (the 7 base modules), lean_lib ElleCP (globs ElleCP.+)
    lean/Elle/{Basic,Hash,Graph,Bfs,Model,Core,Txn}.lean   sanitized base modules
    lean/ElleCP/ClosedPredicate.lean                       placeholder for the translation
  grader/                        private
    lean-toolchain               leanprover/lean4:v4.35.0
    lakefile.toml                libs Elle, ElleCP, Grade; exes grade, cases
    Elle/{Basic,Hash,Graph,Bfs,Model,Core,Txn}.lean        original base modules (unsanitized)
    Elle/ClosedPredicate.lean    the human translation (the reference)
    ElleCP/ClosedPredicate.lean  slot for the agents' file (placeholder now)
    Grade/Gen.lean               random closed-predicate histories (no determinismo dependency)
    Grade/Show.lean              EDN printing of histories, printing and comparison keys of outcomes
    Grade/Main.lean              exe grade: ElleCP.check against Elle.ClosedPredicate.check
    Grade/Cases.lean             exe cases: the D9 and D10 histories, Elle as written and fixed
  oracle/                        the real Elle answering requests through files: one function's
                                 value or a whole check (oracle/README.md); the agents' elle tool
```

`lake-manifest.json` files are written by Lake on the first build. Sources: base modules and
`ClosedPredicate.lean` from `determinismo-workloads/workloads/elle/lean/Elle/` (commit 229c346,
working tree clean); `closed_predicate.clj` and `LICENSE` from `lean-work/elle/upstream` (4e359e5,
clean). The upstream `LICENSE` and the replica's `LICENSE` are the same file.

## Building and running

```sh
LAKE=~/.elan/toolchains/leanprover--lean4---v4.35.0/bin/lake

# the agents' project
cd stage/lean && $LAKE build

# the D9/D10 cases (builds without the agents' file)
cd grader && $LAKE build cases && ./.lake/build/bin/cases

# the grade: put the agents' file in the slot, then build and run
cp <agents' lean>/ElleCP/ClosedPredicate.lean grader/ElleCP/ClosedPredicate.lean
cd grader && $LAKE build grade && ./.lake/build/bin/grade 2000
```

With the placeholder in the slot, `lake build grade` fails (`Unknown identifier ElleCP.check`),
as intended. If the agents' `ClosedPredicate.lean` imports other `ElleCP.*` modules, copy those
into `grader/ElleCP/` too. The file must define `ElleCP.check : Elle.Opts → Elle.History →
Elle.Outcome` (extra defaulted parameters are fine; the grader calls `ElleCP.check {} h`). The
grader runs the agents' code with no time limit, so a non-terminating translation hangs it.

### What grade prints

For seeds 0 to N-1 (N is the first argument, default 2000) it runs `Elle.ClosedPredicate.check {} h`
(every fix flag off: Elle as written; default models, strict serializable) and `ElleCP.check {} h`
on `Grade.Gen.history seed`, and prints:

- the reference's results over the seeds (valid / invalid / threw) and the anomaly types seen;
- on how many seeds Elle as written and the fixed checker (`cpFixed := true`) differ in verdict:
  how many seeds a translation that corrected D9-D11 would be expected to fail on;
- verdicts agreed / disagreed: a verdict is `:valid?` plus the anomaly types, or "threw" (the
  exception's message is not compared);
- fully agreed: the anomaly maps (every case, cycles with their steps) are equal too;
- the first 5 seeds with different verdicts and the first 5 with the same verdict but different
  cases, each as an EDN history with both outcomes.

Exit code 0 when every verdict agrees, 1 otherwise.

### The generator (Grade/Gen.lean)

splitmix64 seeded by the seed number. 2-4 keys; an `:init` op (process 0) over about two keys in
three, values 0 or 1; 2-6 transactions of 1-3 mops each (`[:r k v]`, `[:rp pred {..}]`,
`[:w k v]`, `[:insert k v]`, `[:delete k]`; preds `:true`, `[:= n]` with n in 0-3, `[:mod m t]`
with m 2 or 3), completing `:ok` (8 in 10), `:fail` or `:info`; 1-3 threads, interleaved at
random, a thread coming back as a new process after `:info`. Written values are unique per key
(counter from 2); a repeated delete of a key by `:ok`/`:info` ops (which Elle throws on) is let
through about one time in 20. Reads come from an execution in completion order (`:info`
transactions take effect half the time): consistent reads (the state before the transaction's
completion plus its own writes), reads from a random cut (including before `:init`), and garbage
reads (nil, any value ever written, an unwritten value; predicate rows with one dropped or added);
about one history in ten is all garbage.

## Verification (2026-11-25)

- `stage/lean`: `lake build` succeeds, no warnings (11 jobs, about 2 s).
- Grader with a copy of the human file in the slot (namespace `ElleCP`), `grade 2000`:

  ```
  seeds: 2000 (0 to 1999)
  Elle as written on them: [(valid, 1457), (invalid, 534), (threw, 9)]
  anomaly types in its verdicts (seeds with each): [(G-nonadjacent, 4), (G-nonadjacent-item-realtime, 1), (G-nonadjacent-realtime, 3), (G-single, 49), (G-single-item, 179), (G-single-item-realtime, 113), (G-single-realtime, 34), (G0-realtime, 1), (G1c, 47), (G1c-realtime, 99), (G2, 16), (G2-item, 3), (G2-item-realtime, 1), (PL-2-cycle-exists, 4), (PL-2.99-cycle-exists, 9), (PL-3-cycle-exists, 1), (PL-SI-cycle-exists, 11), (predicate-read-miss, 104), (strong-PL-2-cycle-exists, 35), (strong-snapshot-isolation-cycle-exists, 30)]
  seeds where Elle as written and the fixed checker (cpFixed) differ in verdict: 170
  verdicts agreed: 2000, disagreed: 0
  fully agreed (cases and steps too): 2000, verdict agreed but cases differ: 0
  ```
- Compatibility check: the human file with every fix flag stripped (no `cpFixed`/`fixD*`, no
  `d20` argument to `cyclesE`) compiled against the sanitized `stage/lean` base, and the same file
  compiled against the original base in the grader: 2000/2000 and 10000/10000 seeds agree, fully.
- Negative control: the same file with the closed-predicate fixes forced on: 170 verdicts
  disagree (exit 1), 23 more differ only in their cases.
- The placeholder is back in both `stage/lean/ElleCP/` and `grader/ElleCP/`; `.lake/` build
  directories were removed.
- `cases` output (as written: all flags off; fixed: `cpFixed := true`):

  ```
  D9  default options (strict-serializable)
        as written: valid false, anomaly types [strong-snapshot-isolation-cycle-exists]  (scc [1, 3])
        fixed:      valid false, anomaly types [G-single-item]  cycle [5, 1, 3, 5] steps [rw/0 ww/1 wr/1]
      models [serializable]
        as written: valid true
        fixed:      valid false, anomaly types [G-single-item]  cycle [5, 1, 3, 5] steps [rw/0 ww/1 wr/1]
  D10 default options (strict-serializable)
        as written: valid false, anomaly types [predicate-read-miss]
        fixed:      valid false, anomaly types [G-single, predicate-read-miss]  cycle [5, 1, 3, 5] steps [rwp/0 ww/1 wr/1]
      models [snapshot-isolation]
        as written: valid true
        fixed:      valid false, anomaly types [G-single]
  ```

  Under the models REPORT.md uses (serializable for D9, snapshot isolation for D10) the verdicts
  are valid as written and G-single-item / G-single fixed, as REPORT.md says. Under the default
  options both histories are already invalid as written (D9 through a real-time cycle-exists
  anomaly, D10 through its predicate read miss), and only the anomaly types change.

## The team's runs (2026-11-25)

The team (`harness.replica`: a coordinator, a translator and a specifier) ran on Inkling 2 Mini,
the local model, from 13:21 to 18:55, in 12 attempts. Each attempt was stopped when its recording
showed a problem in the setup, and the problem was fixed before the next one. The fixes, in order:

1. `harness.replica` is loaded before the sandbox, which refuses the harness's sources afterwards.
2. The coordinator's own tools refuse until it has handed out the work; it had read Elle's code
   itself for fourteen steps while the workers waited.
3. `ELLE.md` says that only `closed_predicate.clj` is given, and where each function it calls from
   outside is in Lean; the translator had searched the machine for the rest of Elle.
4. `ELLE.md` says what `loopr`, transients and the explainers are.
5. The specifier's tools refuse the source and the translation; it reads `elle/DOCSTRING.md` (the
   namespace docstring) alone. It had read Elle's explainers.
6. The workers have 98,304 tokens of context; at 65,536 the translator was compacted twice in
   thirty steps.
7. A worker that has written nothing is reminded at steps 12, 24 and 36.
8. A worker's reading tools refuse after 20 reads without a write. A shell call counts as a write
   when a watched file (the translation, the specification, the report) changed. After three
   refused reads in a row, the worker's turn ends.
9. The workers think at `:high` with 4,096-token stretches; at `:max`, steps took up to six
   minutes.

No attempt produced a translation that builds, so nothing was graded and no `REPORT.md` was
written. The last attempts' recordings and drafts are in `trials-out/stopped-elle/`.

What the recordings show about the model:

- It notices the known bugs while reasoning. In attempt 10 the translator called the end of
  `version<` (the `loopr` returning `found-a?`, D11) "a bug — OR a deliberate decision", and noted
  the `:write` and `:w` keywords (D9). Attempt 11's translator said of the same function "that
  can't be right".
- What it writes varies. Attempt 9's translator wrote `versions-after` and `version<` with D10 and
  D11 corrected, and so did attempt 11's first write. Attempt 11's translator then reread the
  `loopr` rules and rewrote the file with both as Elle has them: `version<` returns `found-a?`
  when the versions run out, and `versions-after` discards the unborn branch's value (its comment
  says so). That last file (`trials-out/stopped-elle/r11-ClosedPredicate.lean`) is the first part
  only, 211 lines, and does not build: `let mut` outside a `do` block, functions used before they
  are defined, and names Lean 4.35 doesn't have (`Nat.toInt`, `List.get?`). A translation's
  faithfulness can't be read from one write; testing it against Elle settles it.
- It is slow for this size of work. With two workers at about 22 tokens a second each, a step
  took one to six minutes, and attempt 11's translator first wrote a part of the file 30 minutes
  after the start. A whole translation, a specification and a comparison would take many hours.

The oracle (`oracle/`) was added for the twelfth attempt, so that the translator could test each
function against Elle itself: `(version< {1 [0 :elle/dead]} 1 :elle/dead 0)` is true in Elle, and
a corrected translation says false. That attempt was stopped at step 11, before any call to it,
when the runs on the local model were stopped as too slow to be useful.

## Sanitization of the stage base modules

`Basic.lean`, `Hash.lean`, `Graph.lean`, `Bfs.lean`: unchanged copies.

`Model.lean`:
- `directProscribed`: removed `"fuzzy-read"` from `consistent-view` and `repeatable-read`,
  `"garbage-read"` from `PL-1`, and the two comments naming the D6 and D8 fixes. These were
  unconditional (no switch), so they changed Elle's lattice; the lists are now as
  consistency_model.clj:408-520 writes them (the replica's round 1 had them so). No effect on the
  closed-predicate checker: it never reports either anomaly, and nothing implies them.
- `prohibitedTable` doc comment: dropped the sentence naming `Theorems.tables_agree` (a replica
  file not in the stage).

`Core.lean`:
- `Step`: removed the doc comment on `unread` (it named D1's fix). The field itself is kept
  (`unread : Bool := false`, never set by the base modules) so that `Step`'s constructor is the
  original's and an anonymous-constructor `Step` compiles against both bases.
- `processGraph`: removed the optional `intoInfo` parameter and its branch (D3's fix).
- `realtimeGraph`: removed the optional `noInfo` parameter and its `else` branch (with its
  "round 3" comment); the body is the `noInfo = false` path.
- Removed `svcKeysOf`, `svcKeysOfFixed`, `realtimePerKeyGraph` (the Elle service's per-key
  real-time graph, as served and as deployed with D19's fix).

`Txn.lean`:
- `Opts`: removed `perKey`, `fixD3`, `fixD13`, `cpFixed`, `perKeyFixed`, `fixD1`, `fixD2`,
  `fixD4`-`fixD8`, `fixD12`, `fixD20`, `fixD21`, `fixD22` and their doc comments. Kept `models`,
  `anomalies`, `wfrKeys`, `sequentialKeys`, `linearizableKeys`, `txnOrder`, `cuts` (Elle's own
  options and timeout).
- `classify`: removed the optional `d20` parameter and its comment; G2 / G-nonadjacent are split
  on `predicate`, the `d20 = false` path.
- Removed `baseCycleSpecsFx` and `cycleSpecsFx`; `cycleSpecs` is computed from `baseCycleSpecs`
  directly (the value of `cycleSpecsFx false`).
- `Extra`: removed the constructors `realtimePerKey`, `processInfo`, `realtimeNoInfo`,
  `realtimePerKeyFixed`, `processRealtime` and their comments; kept `none`, `process`, `realtime`.
- Removed `needsProcessToo` (D2's fix).
- `additionalGraphs`: the all-switches-off path only (`.realtime`, `.process` or `.none`).
- `extraAnalysesOf`: the three remaining cases.
- `cycleInSccOfType`, `sccSearches`, `cycleCasesInSccE`, `cyclesE`: removed the optional `d20`
  parameter (and, in `sccSearches`, the D20 comment and the filter it guarded).
- `cycles` doc comment: dropped "(round 1's form)".

Nothing was renamed or added, and no remaining definition changed its signature.

### Compatibility limits

Code written against the stage base compiles against the original except in two unlikely forms:
an exhaustive `match` on `Extra` (the original has five more constructors; `ELLE.md` points the
agents at `additionalGraphs` / `extraAnalysesOf` instead), and an anonymous constructor `⟨..⟩`
for `Opts` (the original has more fields).

### What the leak grep still finds

`grep -rn "D[0-9]\|fix\|cpFixed\|deployed\|service\|round" stage/` finds:
- `stage/elle/closed_predicate.clj:259`: Elle's own comment "Work around a bug in dom-top--fixed
  now" (in `version-after`; the file is a whole, unmodified copy);
- `stage/lean/lake-manifest.json`: Lake's `"fixedToolchain": false` (after a build);
- `stage/lean/Elle/Model.lean:127, 135, 172`: the consistency model named `prefix`.

None names a known bug or fix.
