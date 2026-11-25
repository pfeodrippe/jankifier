# Reproductions of the findings

One file per finding of [RESULTS.md](../RESULTS.md). Each prints what it
expects and what it got, the passing variant first where there is one.
Findings that need concurrency run many times and print how often the bug
showed up.

- `.cljc` files run on jank and on Clojure, so Clojure's answer can be seen
  next to jank's:

  ```sh
  cd specs/repro
  jank run --module-path . <file>.cljc
  clojure -Sdeps '{:paths ["."]}' -M <file>.cljc
  ```

- `binding-frames-never-freed.jank` is jank only (it reads the runtime
  through C++): `jank run binding-frames-never-freed.jank`.
- `compare-exchange-weak-spurious.cpp` is the C++ jank's `compare-and-set!`
  runs; its comment has the two `clang++` commands.

- `.py` scripts need several processes (`jank compile-module`, a running
  REPL) or an nREPL client. They share a jank runner and client
  (`jank_harness.py`), start jank in scratch directories under
  `conformance/out/`, and print the same way: `python3 <file>.py`.

Checked on 2026-11-21 with jank 0.1 (Homebrew, `f3d82d654`) on macOS 15.1,
Apple Silicon, and Clojure 1.11.1; and on the build of jank's main published
on 2026-11-20 (`774d02f62`), where each prints the same, except N1 and S5
(fixed) and S8 (it compiles, but `(case k :a 1 true)` is `1`). The `.py`
scripts take another jank from `$JANK`. "Clojure" is what the same file prints on
Clojure. "determinismo" is its jank analysis
(`determinismo/ai-analysis/jank-0.1.md`), where a finding is also there.

## jank only

| # | File | jank | Clojure | determinismo |
|---|---|---|---|---|
| A1 | `transient-array-map-mutates-source.cljc` | `{:a 2}`, `{:b 2, :b 2}`, `{:a 3}`; `into` and `update-vals` change their argument | the sources unchanged | §3.14 |
| A2 | `transient-read-after-persistent.cljc` | 7 reads return data | all throw | |
| A3 | `multimethod-ancestor-preference-ignored.cljc` | throws for both preferences on an ancestor | `:a2`, `:v0` | |
| A5 | `alter-var-root-nested-deadlocks.cljc` | still running after 3 s | returns, root 1 | |
| C3 | `binding-leaks-across-futures.cljc` | 200 of 200 | 0 of 200 | |
| C5 | `delay-deref-self-deadlocks.cljc` | still running after 3 s | throws (stack overflow) | |
| C4 | `binding-frames-never-freed.jank` (jank only: it counts the frames through C++) | 1000 futures leave 1000 frames, all on one reused thread id; 1000 more leave 2000 | |
| C8 | `future-cancel-invisible.cljc` | `nil`, `false`, `false`, deref `nil` | `true`, `true`, `true`, deref throws | |
| S1 | `print-exception-crashes-at-exit.cljc` | exit code 139 | 0 | |
| S2 | `let-string-literal-does-not-compile.cljc` | the second `defn` doesn't compile | `ok` | (§3.13 has another `let` that codegen types wrong) |
| S3 | `timed-deref-is-a-stub.cljc` | `nil` three times | `1`, `:timeout`, `:timeout` | |
| S5 | `sort-empty-crashes.cljc` | exit code 139 at `(first (sort []))` | `nil` | |
| S6 | `regex-unmatched-group-empty-string.cljc` | `["a" ""]` | `["a" nil]` | |
| S7 | `if-number-and-boolean-literals.cljc` | `1` and `0` | `true` and `false` | |
| S8 | `case-literal-default-does-not-compile.cljc` | the second `defn` doesn't compile when called | `true` | |
| S9 | `count-arithmetic-unsigned.cljc` | `-2997`, `false`, `-2997` | `-2997`, `true`, `0` | |
| S10 | `small-integer-arithmetic-wraps.cljc` | `-2147483648` (twice), `-1486618624`, `-1294967296`, `2147483647`; `inc` is right | the right values | |
| M1 | `module-object-ignores-changed-dependency.py` | 1, also after `compile-module` again | | |
| M2 | `module-path-last-directory-wins.py` | `b` | | |
| M3 | `module-repl-never-sees-new-object.py` | `false` | | |
| M4 | `module-deleted-source-filesystem-error.py` | `filesystem error: in last_write_time` | | |
| M5 | `module-reload-runs-old-object.py` | 1 | | |
| N1 | `nrepl-bad-argument-ends-connection.py` | no response, then none on that connection; another connection works | | |
| N3 | `nrepl-done-with-eval-error.py` | `[["done", "eval-error"]]` | | |
| N4, N5 | `nrepl-concurrent-output-swap.py` | 20 of 20 rounds swapped; the late print lost | | §3.3 |
| N6 | `nrepl-sessions-share-star1.py` | `[42]` | | §3.4 |

The module cache and nREPL findings have no Clojure counterpart (no object
files; nREPL's own server keeps sessions and captures output per eval).

## Shared with Clojure

These go against what Clojure documents, on jank and on Clojure alike: A4
against its multimethod reference (the most specific matching method wins),
A6 against the docstrings of `defonce`, `with-redefs` and `require`.

| # | File | jank | Clojure |
|---|---|---|---|
| A4 | `multimethod-dispatch-depends-on-hash-order.cljc` | 14 of 40 throw | 9 of 40 throw |
| A6 | `defonce-race.cljc` | the expression ran twice in about half the runs (92 of 200) | most (192 of 200) |
| A6 | `with-redefs-race.cljc` | left redefined in 1622 of 2000 | 1844 of 2000 |
| A6 | `require-race.cljc` (with `repro_require_lib.cljc`) | loaded twice in 185 of 200 | 187 of 200 |

Counts vary from run to run.

## Depends on the CPU

C2: `compare-and-set!` is one `compare_exchange_weak` (`obj/atom.cpp:220`),
which C++ allows to fail although the atom holds the expected value; Clojure's
never does. On Apple Silicon it compiles to `casal`, which can't fail that way
(jank 0.1's binary has it), so jank shows nothing here. On a CPU without that
instruction (ARMv8.0, such as a Raspberry Pi 4's Cortex-A72) it's an
`ldaxr`/`stlxr` pair, which fails whenever another core stores to the same
memory in between.

| File | Here (Apple Silicon) | On an ARMv8.0 CPU |
|---|---|---|
| `compare-and-set-spurious-failure.cljc` | 0 of 200000, jank and Clojure | jank: expected to fail; not run (no such machine) |
| `compare-exchange-weak-spurious.cpp` (the same C++ call, `-mcpu=apple-m1` and `-mcpu=cortex-a72`) | 0 | 58520 and 63170 of 2000000 in two runs, on this Mac |

## Not reproduced

- Watch calls arriving out of order (once listed as "W") isn't a finding:
  `add-watch`'s docstring allows it, and Clojure does the same.
- S4 (agents, refs, `var-set`, `with-local-vars`, `flush`, `set!`, `locking`
  aren't ported): each fails as soon as it's used; determinismo has
  `locking` (§3.17).

- `lean-replica/jank_lean/*.jank` are clojure.test namespaces, one `deftest` per prediction of
  a Lean replica of jank (unreported.md, "Found by a Lean replica of jank"). Each asserts
  Clojure's result, so each fails on jank. On Clojure they pass once
  `cpp/jank.runtime.object_ref` becomes `Throwable` and `(thrown? (…))` becomes
  `(thrown? Throwable (…))`. Run one test per process, since some crash or hang jank:

  ```sh
  cd specs/repro/lean-replica
  jank --module-path . run-main run-one -- jank-lean.deviations-test d02-integer-division-is-a-ratio
  ```
