# Elle oracle

A small service that runs real Elle (jepsen-io/elle, commit 4e359e5) on request, through files.
It loads Elle into one JVM once, then answers each request file in a directory with a result
file. An agent harness can use it to ask Elle what it says about a history, or what one of its
functions returns, without paying the JVM start time each time.

## Files

```
oracle/
  oracle.clj     the service (java -Xmx2g -cp CP clojure.main oracle.clj DIR)
  oracle.sh      starts it: oracle.sh DIR
  classpath.sh   prints Elle's classpath (used by oracle.sh and test.sh)
  test.sh        the test (starts an oracle on a temp dir, runs test.clj, stops it)
  test.clj       the requests and checks of the test
  README.md      this file
```

Elle comes from `/Users/pfeodrippe/lean-work/elle` (set `ELLE_HOME` to use another tree): the
jars listed in `deps/classpath.txt`, the compiled Java classes in `upstream/target/classes` and
the Clojure source in `upstream/src`. `deps/classpath.txt` still names the tree's old place
(`~/dev/determinismo-mine-private/lean/elle`); `classpath.sh` rewrites those paths when it reads
the file and does not change it.

## Starting and stopping

```sh
oracle/oracle.sh /path/to/DIR > oracle.log 2>&1 &
```

- `DIR` is created if missing. A `DIR/stop` or `DIR/ready` left by an earlier oracle is removed.
- `DIR/ready` appears once Elle is loaded (it holds the JVM's pid). Requests written before that
  are answered once it is ready.
- `touch DIR/stop` makes the oracle exit within about 100 ms (up to 0.6 s until the JVM is
  gone). It finishes the request it is on, deletes `DIR/stop` and `DIR/ready`, and leaves any
  other requests in place.
- The log (stdout) has one line per request: file name, time taken, and the start of the result.
- Run one oracle per directory.
- `ELLE_ORACLE_LIMIT_S` sets the time limit in seconds (default 30).

## Requests

A request is a file `DIR/NAME.req.edn` holding one EDN map. Write it to another name first (one
not ending in `.req.edn`, e.g. `NAME.req.tmp`) and rename it, so the oracle never reads half a
file. If a request does not parse and was modified less than a second ago, the oracle tries it
again later in case it is still being written.

Requests are taken oldest first (by modification time, then by name). The answer goes to
`DIR/NAME.res.edn`, written to `NAME.res.edn.tmp` and renamed, so a reader that sees the file sees
all of it. The request file is then deleted.

There are two kinds of request.

### Check

`{:id any, :workload kw, :opts map, :history [op ...]}`, the shape of the input items of run.clj
(see Credit). `:workload` is `:closed-predicate` when missing (also `:list-append`,
`:rw-register`, `:monotonic`, `:monotonic-realtime`); `:opts` is `{}` when missing. The history is
given to `jepsen.history/history` and then to the workload's `check`, as run.clj's `run-one` does.
`:directory` is removed from `:opts`, so Elle writes no files.

Example (`closed-predicate.cases.edn` id 2):

```clojure
{:id 2 :workload :closed-predicate :opts {:consistency-models [:serializable]}
 :history [{:process 0 :type :invoke :f :init :value {0 0, 1 0}}
           {:process 0 :type :ok :f :init :value {0 0, 1 0}}
           {:process 1 :type :invoke :f :txn :value [[:delete 1]]}
           {:process 1 :type :ok :f :txn :value [[:delete 1]]}
           {:process 2 :type :invoke :f :txn :value [[:r 1 nil] [:r 0 nil]]}
           {:process 2 :type :ok :f :txn :value [[:r 1 nil] [:r 0 nil]]}]}
```

Result (run.clj's format):

```clojure
{:id 2, :valid? false, :anomaly-types ["G-single-item"],
 :not ["consistent-view" "repeatable-read"],
 :also-not ["forward-consistent-view" "serializable" "snapshot-isolation" "strong-serializable"
            "strong-session-serializable" "strong-session-snapshot-isolation"
            "strong-snapshot-isolation" "update-serializable"],
 :anomalies {"G-single-item" [{:cycle [5 1 3 5], :steps [:rw :ww :wr], :type :G-single-item}]}}
```

- `:valid?` is `true`, `false` or `:unknown`. `:anomaly-types`, `:not` and `:also-not` are sorted
  vectors of names.
- `:anomalies` maps each anomaly name to its cases. A cycle is given as `:cycle` (the history
  indices of its ops, first op repeated at the end), `:steps` (the type of each edge: `:ww`,
  `:wr`, `:rw`, ...) and `:type`. run.clj does not give the steps' keys, so neither does the
  oracle. An SCC is `{:scc ...}`. Any other case is Elle's map without `:op :writer :txns :mop`.
- When Elle throws, the result is `{:id .., :error "ExceptionClass: message", :data ..}`.

### Call

`{:id any, :call "ns/name", :args [arg ...]}` calls an Elle function with the EDN arguments.
`:call` is a string or a symbol naming a var. Only namespaces starting with `elle.` are allowed
(the namespace is loaded if needed). Keywords such as `:elle/unborn` and `:elle/dead` are read as
the Clojure keywords Elle uses, so `identical?` comparisons in Elle work.

```clojure
{:id "d11" :call "elle.closed-predicate/version<" :args [{1 [0 :elle/dead]} 1 :elle/dead 0]}
```

The result holds the function's return value printed with `pr-str`:

```clojure
{:id "d11", :value "true"}
```

A function outside `elle.*` is refused:

```clojure
{:id "x", :error "refused: clojure.java.shell/sh is not in a namespace starting with \"elle.\""}
```

Errors are also given for a missing var, a macro, a var that is not a function, and an exception
thrown by the function. Note that some `elle.*` functions write files (e.g.
`elle.viz/plot-analysis!`, `elle.core/write-cycles!`); calls to them are not refused.

### Errors and limits

- A request that is not readable EDN, or not a map, gives `{:error "malformed request: ..."}`.
- Each request gets 30 seconds. After that the result is
  `{:id .., :error "Elle did not end in 30 seconds"}` and the oracle moves on to the next request.
  The check's thread is interrupted. Printing stops at the interrupt, but Elle's own computation
  does not check for it, so a long check can go on using a core in the background until it ends.
- A result longer than 64 Mi characters gives an error instead (e.g. calling a function that
  returns an endless lazy sequence).
- Records in a result (e.g. `jepsen.history.Op`) are printed as plain maps, so results read with
  `clojure.edn/read-string`.
- Errors are caught per request; the loop does not stop on them.

## Timing

Measured on this machine (Apple silicon, JDK 23, `-Xmx2g`):

- Start: 1.6 to 2.9 s of JVM time until `DIR/ready` (1.7 to 3.9 s wall clock from running
  `oracle.sh`; it varies with the machine's load). This covers loading Elle from source and one
  small warm-up check.
- Checks (time from taking the request to writing the result):
  - the 6-op closed-predicate histories: 3 to 17 ms
  - a serial closed-predicate history of 100 transactions (202 ops): 9 to 37 ms
  - 400 transactions (802 ops): 27 to 43 ms
  - 1000 transactions (2002 ops): 40 to 70 ms
  - 5000 transactions (10002 ops): 180 to 260 ms

  The first request of each size is the slower one (JIT).
- Calls such as `version<`: about 1 ms.
- Round trip as a client sees it (write a request, poll for the result): about 50 ms for a small
  check. Most of it is the oracle's 100 ms polling interval.
- Stop: the process is gone 0.15 to 0.6 s after `touch DIR/stop`.

## Test

```sh
oracle/test.sh
```

It starts an oracle on a new temp dir and sends these requests:

- the histories of `closed-predicate.cases.edn` (3) and `closed-predicate-2.cases.edn` (1) from
  determinismo-workloads' `workloads/elle/lean/results`. Each result must equal the line of the
  same id in the `.elle.edn` file (valid?, anomaly-types and the rest).
- id 2's history without `:workload` and `:opts` (the defaults).
- a serial 400-transaction history, which must be valid.
- an unreadable request and a request that is not a map (both give `{:error ...}`).
- `elle.closed-predicate/version<` on `{1 [0 :elle/dead]} 1 :elle/dead 0`. Key 1's versions are
  `[0 :elle/dead]`, so `:elle/dead` does not come before 0. Elle still answers `true` (REPORT.md
  D11 in the replica): `version<` returns its accumulator `found-a?` when the versions run out.
  The test checks the value is `"true"`, the value Elle gives when called directly, and prints it.
- `elle.closed-predicate/resolve-version` on `{1 [:elle/unborn 0]} 1 nil`, which must give
  `:elle/unborn` (shows that the keywords arrive as Elle's keywords).
- `clojure.java.shell/sh`, which must be refused (and must not run).

It then checks that no request is left, measures one round trip, touches `DIR/stop` and checks
that the oracle exits and removes `DIR/stop` and `DIR/ready`. It prints PASS/FAIL lines, the
oracle's time per request, and a summary. It exits 0 when everything passes and removes the temp
dir; otherwise it keeps the dir and the log and names them.

## Credit and license

Elle is by Jepsen ([jepsen-io/elle](https://github.com/jepsen-io/elle), copyright Jepsen, LLC and
Peter Alvaro), under the Eclipse Public License 2.0. The oracle runs it unmodified.
`run-one` in `oracle.clj` is copied unchanged from `runner/run.clj` of the Lean replica of Elle in
[determinismo-workloads](https://github.com/determinismo-dst/determinismo-workloads)
(`workloads/elle/lean`). The example histories and Elle's answers the test uses come from the same
replica's `results/`.
