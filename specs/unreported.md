# Findings not reported upstream

Minimal examples of the findings in [RESULTS.md](RESULTS.md) for which no
jank issue or PR was found. Each was checked on 2026-11-21 on jank 0.1
(Homebrew), on jank main (the build published on 2026-11-20, `774d02f62`) and
on Clojure 1.11.1. Unless noted, jank 0.1 and main give the same result. The
longer reproductions are in [repro/](repro/).

## Wrong values, no error

- [ ] **A2**: a transient can be read after `persistent!` (`repro/transient-read-after-persistent.cljc`).

```clojure
(let [t (transient [1])]
  (persistent! t)
  (nth t 0))
;; jank => 1
;; clj  => IllegalAccessError: Transient used after persistent! call
```

Not the same as #1190 (A1, the persistent map changing). The other reads that
don't check: `contains?`, `find` on a vector; `get` with a fallback,
`contains?`, `find`, calling it with a fallback on an array map. None of them
calls `assert_active`.

- [ ] **S7 and S8**: an `if` or `case` with a number literal in one branch and a boolean literal in another returns a number for the boolean (`repro/if-number-and-boolean-literals.cljc`, `repro/case-literal-default-does-not-compile.cljc`).

```clojure
(defn f [x] (if x 1 true))
(f false)
;; jank => 1
;; clj  => true

(defn g [x] (case x :a 1 true))
(g :b)
;; jank 0.1  => doesn't compile (no viable overloaded '=')
;; jank main => 1
;; clj       => true
```

Related, closed: #1187 (`if` with a typed object branch), #1025 (`case`
default returning an unboxed value).

- [ ] **S9**: arithmetic on `count`'s result is unsigned (`repro/count-arithmetic-unsigned.cljc`).

```clojure
(< (- (count "abc") 4) 0)
;; jank => false
;; clj  => true
```

- [ ] **S6**: an optional regex group that didn't match is `""` (`repro/regex-unmatched-group-empty-string.cljc`).

```clojure
(re-find #"a(b)?" "a")
;; jank => ["a" ""]
;; clj  => ["a" nil]
```

- [ ] **S3**: `deref` with a timeout returns `nil` at once (`repro/timed-deref-is-a-stub.cljc`; "TODO: Blocking" in `clojure/core.jank`).

```clojure
(deref (promise) 10 :timeout)
;; jank => nil
;; clj  => :timeout
```

- [ ] **A3**: a multimethod preference declared on an ancestor is ignored (`repro/multimethod-ancestor-preference-ignored.cljc`).

```clojure
(derive ::c ::a2)
(derive ::a2 ::a)
(derive ::c ::b)
(defmulti f identity)
(defmethod f ::a2 [_] :a2)
(defmethod f ::b [_] :b)
(prefer-method f ::a ::b)
(f ::c)
;; jank => Multiple methods in multimethod `user/f` match dispatch value
;;         `:user/c`. ... neither is preferred.
;; clj  => :user/a2
```

`is_preferred` gets the hierarchy var instead of its value, so `parents` is
`nil` (`obj/multi_function.cpp`).

- [ ] **C3**: a future sees a binding from an earlier future, on macOS (`repro/binding-leaks-across-futures.cljc`).

```clojure
(def ^:dynamic *x* nil)
@(binding [*x* 1] (future *x*))
@(future *x*)
;; jank => 1
;; clj  => nil
```

A future's thread never pops its binding frame, frames are kept per OS thread
id and never removed, and macOS reuses thread ids. The frames also leak (C4:
1000 futures leave 1000 frames, `repro/binding-frames-never-freed.jank`).

- [ ] **C8**: `future-cancel` isn't recorded, on macOS (`repro/future-cancel-invisible.cljc`).

```clojure
(def f (future (cpp/usleep 5000000)))
(future-cancel f)
;; jank => nil
;; clj  => true
(future-cancelled? f)
;; jank => false
;; clj  => true
@f
;; jank => nil
;; clj  => throws CancellationException
```

## Hangs

- [ ] **A5**: `alter-var-root` inside `alter-var-root` of the same var (`repro/alter-var-root-nested-deadlocks.cljc`).

```clojure
(def z 0)
(alter-var-root #'z (fn [v] (alter-var-root #'z inc) (inc v)))
;; jank => hangs
;; clj  => 1
```

`alter_root` holds `write_mutex`, which isn't recursive, while calling the
function (`runtime/var.cpp`).

- [ ] **C5**: a delay whose body derefs itself (`repro/delay-deref-self-deadlocks.cljc`). Less important: Clojure fails too.

```clojure
(def d (delay (inc @d)))
@d
;; jank => hangs
;; clj  => StackOverflowError
```

## Doesn't compile

- [ ] **S2**: a `let` whose value is a string literal (`repro/let-string-literal-does-not-compile.cljc`).

```clojure
(let [] "ok")
;; jank => error: brackets are not allowed here; to declare an array, place
;;         the brackets after the name
;; clj  => "ok"
```

Related, closed: #1023 (`if` with two strings of the same length).

## Module loading

- [ ] **M1**: a module's object file is used although a dependency changed (`repro/module-object-ignores-changed-dependency.py`).

```sh
mkdir src
echo '(ns lib) (defmacro ver [] 1)' > src/lib.jank
echo '(ns app (:require [lib])) (defn -main [] (println (lib/ver)))' > src/app.jank
jank --module-path src compile-module app
echo '(ns lib) (defmacro ver [] 2)' > src/lib.jank
jank --module-path src run-main app
# => 1, expected 2
```

`jank compile-module app` again doesn't fix it.

- [ ] **M2**: with the same module in two directories, the last one wins (`repro/module-path-last-directory-wins.py`). `loader.hpp` says the first match is taken.

```sh
mkdir a b
echo '(ns lib) (defn -main [] (println "a"))' > a/lib.jank
echo '(ns lib) (defn -main [] (println "b"))' > b/lib.jank
jank --module-path a:b run-main lib
# => b, expected a
```

- [ ] **M5**: `(require 'm :reload)` after the object file was rebuilt runs the old code (`repro/module-reload-runs-old-object.py`).

```
src/lib.jank: (ns lib) (defn ver [] 1)
jank --module-path src compile-module lib
in a REPL started with --module-path src:
  (require 'lib) (lib/ver)            ; => 1
change src/lib.jank to (defn ver [] 2), then in another shell:
  jank --module-path src compile-module lib
in the same REPL:
  (require 'lib :reload) (lib/ver)    ; => 1, expected 2
```

`load_o` calls the `jank_load_lib` already in the process instead of loading
the new object file.

## nREPL

- [ ] **N4 and N5**: output capture is process-wide (`repro/nrepl-concurrent-output-swap.py`).

Two connections evaluate at the same time:

```clojure
;; connection 1
(do (cpp/usleep 50000) (println "A") (cpp/usleep 50000) 1)
;; connection 2
(do (cpp/usleep 50000) (println "B") (cpp/usleep 50000) 2)
```

One request's `:out` gets the other's print (20 of 20 rounds). Afterwards the
server's stdout can be left pointing at a deleted temp file, so prints outside
an eval (e.g. from a future) are lost. #1022 (closed) was a crash with two
clients evaluating at once, not this.

- [ ] **N3**: a failed eval sends `done` in the same message as the error (`repro/nrepl-done-with-eval-error.py`).

```clojure
(throw (ex-info "x" {}))
;; jank  => one message with :ex and :status ["done" "eval-error"]
;; nREPL => :status ["eval-error"], then a separate :status ["done"]
```

CIDER 2.1 leaves the request pending (its spinner keeps going) on the combined
message. `jankifier.nrepl` works around it.

## Left out

- A4 and A6: Clojure behaves the same.
- C2: `compare_exchange_weak` can't fail spuriously with the Apple Silicon build (it uses `casal`).
- C4: same cause as C3 (noted there).
- N6 (sessions share `*1`): already described in PR #1175.
- S1 (crash at exit after printing an exception): might be #854.
- M3: a running REPL keeps loading the source of a module compiled after it started; only slower.
- M4: a module whose source was deleted gives `filesystem error: in last_write_time` instead of "not found"; only the message.
- S4: features that aren't ported (agents, refs, `var-set`, ...).

## Found by a Lean replica of jank (checked on jank main)

These were predicted by a Lean replica of jank written blind from its sources (determinismo's
`lean/jank`, rounds 1 and 2), then checked on 2026-11-25 on jank main (`7135b7708`, x86-64
Linux, UTF-8 locale, each test in its own process with a 600 s limit, through determinismo-ci)
and on Clojure 1.11.1. The tests live with the replica, in determinismo-workloads'
[jank-interop/lean/tests](https://github.com/determinismo-dst/determinismo-workloads/tree/main/workloads/jank-interop/lean/tests): each asserts Clojure's result, so each fails on jank, and all pass on Clojure 1.11.1 except where noted. jank's
issues and PRs were searched by keyword on 2026-11-25; none found unless said.

Already elsewhere: A2 here (on main, `nth` after `persistent!` now refuses, but with a C++
exception that `thrown?` can't catch), A3 (the same on main), C3 (also on Linux x86-64), S3 and
S6 here; #1208 (32-bit arithmetic, `quot` of a BigInt).

### Crashes

- [ ] **D9**: on x86-64 the hardware's default NaN crashes jank (`deviations_test.jank`: `d09`, `d09b`).

```clojure
(defn sub [a b] (- a b))
(sub ##Inf ##Inf)
;; jank => SIGSEGV
;; clj  => ##NaN

(defn div [a b] (/ a b))
(div 0.0 0.0)
;; jank => SIGSEGV
;; clj  => ArithmeticException: Divide by zero
```

A double is stored as its raw bits (`oref.hpp`, `tag(f64)` at 194) and a word counts as a real
only below `0xFFF8000000000000` (94, 113). x86-64's default NaN is exactly that word, so it's
decoded as a pointer to address 0 (`as_pointer`, 142). On AArch64 the default NaN is a real.
Likely since #772 (NaN boxing).

- [ ] **D2b**: the int32 minimum divided by -1 traps (`d02b`).

```clojure
(defn div [a b] (/ a b))
(div -2147483648 -1)
;; jank => SIGFPE
;; clj  => 2147483648
```

`core/math.hpp` `div` (299) divides the two native integers (314): x86-64's `idiv` traps.

- [ ] **R47**: a fn whose parameter has the fn's own name reads its closure from the argument (`deviations_main_test.jank`: `r47`).

```clojure
(let [y 1] ((fn f [f] y) 5))
;; jank => SIGSEGV
;; clj  => 1
```

`cpp_processor.cpp` 1946–1957, 1984–1993.

- [ ] **R119**: `chunk-cons` realizes its rest, so an infinite real range overflows the stack (`r119`).

```clojure
(first (map inc (range 0.0 ##Inf)))
;; jank => SIGSEGV
;; clj  => 1.0
```

`seq.cpp` 1066; `core.jank` 2061, 2910.

- [ ] **R97**: comparing a keyword with a non-keyword is undefined behavior, and the `catch` never runs (`deviations_r2_test.jank`: `c02`).

```clojure
(try (compare :a 1) (catch cpp/jank.runtime.object_ref _ :caught))
;; jank => SIGSEGV
;; clj  => :caught   (catching Exception)
```

`keyword.cpp` 50; `rtti.hpp` 50–58.

- [ ] **D24**: a `catch` that throws, then a `finally` that throws, end the process (`d24`).

```clojure
(try (try (throw (ex-info "a" {}))
          (catch cpp/jank.runtime.object_ref _ (throw (ex-info "b" {})))
          (finally (throw (ex-info "c" {}))))
     (catch cpp/jank.runtime.object_ref e (ex-message e)))
;; jank => SIGABRT (std::terminate)
;; clj  => "c"   (catching Exception)
```

The generated code puts `finally` in a `scope_exit` guard (`cpp_processor.cpp` 1054–1138, at
1137), which throws while the catch's exception is unwinding.

### Hangs

- [ ] **R1**: a NUL in a string makes the reader loop forever (`deviations_reader_test.jank`: `a01`).

```clojure
(read-string (str "\"" (char 0) "\""))
;; jank => hangs
;; clj  => "\u0000"
```

`lex.cpp` `convert_to_codepoint` (452): `mbrtowc` returns 0 for NUL, and the loops advance by it.

- [ ] **D16**: a watch that removes itself hangs (`d16`).

```clojure
(def a (atom 0))
(add-watch a :once (fn [k r _ _] (remove-watch r k)))
(reset! a 1)
;; jank => hangs
;; clj  => 1
```

`atom.cpp` `notify_watches` (43) holds `watches.rlock()` (45) while it calls each watch, and
`remove_watch` takes the write lock.

- [ ] **R116**: `range` with a real end never ends past 2^31 (`r116`).

```clojure
(count (range 2147483646 2147483649.0))
;; jank => hangs
;; clj  => 3
```

`range.cpp` 147: the step's `add` wraps at 32 bits (#1208's arithmetic).

- [ ] **R117**: `doseq` mutates a sequence the program still holds (`r117`).

```clojure
(let [w (cons 0 [1 2 3])] (doseq [x w]) (count w))
;; jank => hangs
;; clj  => 4
```

`doseq` steps with `fresh-seq` / `next-in-place` (`core.jank` 2742, 2750).

### Wrong values, no error: numbers

- [ ] **D2**: `/` on two integers is C++ integer division (`d02`).

```clojure
(defn div [a b] (/ a b))
(double (div 1 2))
;; jank => 0.0
;; clj  => 0.5
```

`core/math.hpp` `div` (299, 314): there's no ratio for two integers. Related: #629 (closed,
ratio support in `/`).

- [ ] **D4b**: `quot` of doubles returns a long (`d04b`).

```clojure
(str (quot 7.5 2))
;; jank => "3"
;; clj  => "3.0"
```

`core/math.cpp` `quot` (321) casts the double quotient to `i64` (338).

- [ ] **D5**: `==` compares longs as doubles (`d05`).

```clojure
(== 9007199254740993 9007199254740992)
;; jank => true
;; clj  => false
```

`core/math.cpp` `is_equiv` (469, 482).

- [ ] **D6**: `abs` of -0.0 is -0.0 (`d06`).

```clojure
(defn absolute [x] (abs x))
(str (absolute -0.0))
;; jank => "-0.0"
;; clj  => "0.0"
```

`core/math.hpp` `abs`, object branch (1016): `data < 0ll` is false for -0.0.

- [ ] **D7**: `bigdec` of a long goes through a double (`d07`).

```clojure
(str (bigdec 9007199254740993))
;; jank => "9007199254740992.0"
;; clj  => "9007199254740993"
```

`core/math.cpp` `to_big_decimal` (803) builds it from `to_real()`.

- [ ] **D8**: BigDecimal `=` uses a double's epsilon (`d08`).

```clojure
(= 1M 1.0000000000000000001M)
;; jank => true
;; clj  => false
```

`obj/big_decimal.cpp` `equal` (154): `abs(a - b) < numeric_limits<f64>::epsilon()`.

- [ ] **D10**: `parse-long` and `parse-double` follow `strtoll`/`strtod` (`d10`, `d10b`).

```clojure
(parse-long " 5")
;; jank => 5
;; clj  => nil

(parse-double "inf")
;; jank => ##Inf
;; clj  => nil
```

`core/math.cpp` `parse_long` (678, `std::stoll` at 689), `parse_double` (712, `std::stod` at 723).

- [ ] **D12**: `1` and `1N` are `=` but hash differently (`d12`).

```clojure
(count (hash-set 1 1N))
;; jank => 2
;; clj  => 1
```

`big_integer::to_hash` (155) combines boost's limbs instead of hashing as a long.

- [ ] **D13**: `hash-unordered-coll` is never the hash of the set of the same elements (`d13`).

```clojure
[(hash-unordered-coll '(1 2)) (hash #{1 2})]
;; jank => [2400221969 460223544]
;; clj  => [460223544 460223544]
```

`core.jank` (6574) → `core.cpp` `hash_unordered` (1369) → `hash.cpp` `unordered(object_ref)` (181).

- [ ] **R23**: an `if` whose branches are a long and a double literal returns a double (`r23`).

```clojure
(if true 1 2.5)
;; jank => 1.0
;; clj  => 1
```

Literals are native (`cpp_util.cpp` `literal_type` 615/653; `processor.cpp`
`analyze_primitive_literal` 3241), and the `if` takes their common C++ type. Related: S7/S8 here
and #1187 (closed); here the branches widen. Compiled code only: the REPL's top level is
interpreted.

- [ ] **R24**: a `loop` local keeps its first value's native type (`r24`).

```clojure
(loop [x 0 n 0] (if (= n 1) x (recur 1.5 1)))
;; jank => 1
;; clj  => 1.5
```

`processor.cpp` `analyze_let` (2397–2400), `analyze_recur` (2183–2219),
`apply_implicit_conversion` (1074/1088).

- [ ] **R26**: a `case` gets one C++ type, from its last branch (`r26`).

```clojure
(case 5 1 1.5 0)
;; jank => 0.0
;; clj  => 0
```

`processor.cpp` `analyze_case` (1483–1581) with `cpp_util.cpp` 1908. Related: S7/S8 here.

- [ ] **R44**: `case` misses a long outside the int32 range (`r44`).

```clojure
(case 2147483648 2147483648 :hit :miss)
;; jank => :miss
;; clj  => :hit
```

`c_api.cpp` 991–1037; `cpp_processor.cpp` 1141–1170.

- [ ] **R122**: bytes are unsigned (`r122`).

```clojure
(aget (byte-array [-1]) 0)
;; jank => 255
;; clj  => -1
```

`core/array.cpp` 275; `builtin.hpp` 227.

- [ ] **R99**: a BigDecimal compares exactly with a double (`c04`).

```clojure
(compare 0.1M 0.1)
;; jank => -1
;; clj  => 0
```

`big_decimal.cpp` 182; `number.cpp` 460.

### Wrong values, no error: concurrency

- [ ] **D18**: `alter-meta!` loses updates (`d18`).

```clojure
(def a (atom 0))
(run! deref (doall (for [_ (range 8)]
                     (future (dotimes [_ 1000] (alter-meta! a update :n (fnil inc 0)))))))
(:n (meta a))
;; jank => 1237
;; clj  => 8000
```

`core.jank` 1235–1243: `; TODO: Atomics. (reset-meta! o (apply f (meta o) args))`.

- [ ] **D19**: a delay whose body returns nil runs again (`d19`).

```clojure
(def runs (atom 0))
(def d (delay (swap! runs inc) nil))
@d @d
@runs
;; jank => 2
;; clj  => 1
```

`delay.cpp` `deref` (19) checks `val.is_some()` (22) before running the body (34).

### Wrong values, no error: the compiler

- [ ] **R29**: a named fn's name doesn't shadow a macro of the same name (`r29`).

```clojure
((fn when [n] (if (= n 0) :done (when 0))) 1)
;; jank => nil
;; clj  => :done
```

`processor.cpp` `analyze_call` (3501).

- [ ] **R30**: macros get the wrong `&form` (`r30`).

```clojure
(defmacro form-of [& _] (list 'quote &form))
(form-of 1 2)
;; jank => ((1 2))
;; clj  => (form-of 1 2)
```

`context.cpp` `macroexpand1` (634) builds `cons(cons(rest(o), {}), o)`.

- [ ] **R33**: arithmetic on a boolean literal doesn't throw (`r33`).

```clojure
(eval '(+ true 1))
;; jank => no exception
;; clj  => ClassCastException
```

`cpp_util.cpp` `literal_type` (615): booleans are C++ `bool`.

- [ ] **R34**: `(:k)` doesn't throw (`r34`).

```clojure
(eval '(:k))
;; jank => no exception
;; clj  => ArityException: Wrong number of args (0) passed to: :k
```

`processor.cpp` `analyze_call` (3571–3578).

- [ ] **R37**: a call evaluates its arguments before its operator (`r37`).

```clojure
(def order (atom []))
((do (swap! order conj :f) identity) (do (swap! order conj :a) 1))
@order
;; jank => [:a :f]
;; clj  => [:f :a]
```

`ir/processor.cpp` `gen(call)` (110–121). Compiled code only.

- [ ] **R38**: locals whose names munge alike are one local (`r38`).

```clojure
(let [a-b 1 a_b 2] a-b)
;; jank => 2
;; clj  => 1
```

`ir/processor.cpp` 206, 249, 519; `core/munge.cpp` 9–36.

- [ ] **R42**: constants that are `=` and hash alike share one object (`r42`).

```clojure
(first (let [a [[]] b ['()]] b))
;; jank => []
;; clj  => ()
```

`cpp_processor.cpp` 153–157; `object.cpp` 346.

- [ ] **R108**: `defn` recursion bypasses the var (`r108`).

```clojure
(defn countdown [n] (if (pos? n) (countdown (dec n)) :done))
(def orig countdown)
(defn countdown [n] :redefined)
(orig 3)
;; jank => :done
;; clj  => :redefined
```

`core.jank` `defn` (727–779) expands to a named fn; `processor.cpp` 1658–1673.

- [ ] **R110**: `find-var` accepts an unqualified symbol (`r110`).

```clojure
(find-var 'map)
;; jank => no exception
;; clj  => IllegalArgumentException: Symbol must be namespace-qualified
```

`core.cpp` 835; `context.cpp` 136; `ns.cpp` 117.

- [ ] **R112**: `in-ns` returns nil (`r112`).

```clojure
(in-ns 'user)
;; jank => nil
;; clj  => #object[clojure.lang.Namespace … "user"]
```

`core.cpp` 819.

- [ ] **R103**: `remove-ns` removes `clojure.core` (`c08`).

```clojure
(remove-ns 'clojure.core)
;; jank => no exception
;; clj  => IllegalArgumentException: Cannot remove clojure namespace
```

`core.cpp` 840; `context.cpp` 420.

### Wrong values, no error: collections and sequences

- [ ] **R105**: sorted `find` returns the queried key (`r105`).

```clojure
(find (sorted-map 1 :x) 1.0)
;; jank => [1.0 :x]
;; clj  => [1 :x]
```

`persistent_sorted_map.cpp` 80; `transient_sorted_map.cpp` 62.

- [ ] **R118**: the `partition-by` transducer sends a partition twice after an early stop (`r118`).

```clojure
(transduce (partition-by odd?)
           (completing (fn [acc p] (let [a (conj acc p)] (if (= 2 (count a)) (reduced a) a))))
           [] [1 2 3])
;; jank => [[1] [2] [2]]
;; clj  => [[1] [2]]
```

`core.jank` 3320.

- [ ] **R120**: a cons isn't a collection (`r120`).

```clojure
(coll? (cons 0 [1]))
;; jank => false
;; clj  => true
```

`seq.cpp` 77, 787. Related: #1094 (closed, `coll?` for another sequence type).

- [ ] **R121**: `get-in` with no keys on a non-map returns nil (`r121`).

```clojure
(get-in 5 [])
;; jank => nil
;; clj  => 5
```

`seq.cpp` 475/486/494/509.

### Wrong values, no error: the reader

- [ ] **R4**: a leading `+` makes a symbol (`a04`).

```clojure
(read-string "+5")
;; jank => +5 (a symbol)
;; clj  => 5
```

`lex.cpp` 1168.

- [ ] **R5**: the int64 minimum reads as a BigInt (`a05`).

```clojure
(pr-str (read-string "-9223372036854775808"))
;; jank => "-9223372036854775808N"
;; clj  => "-9223372036854775808"
```

`lex.cpp` 1145–1156: `strtoll` on the digits after the `-` overflows.

- [ ] **R6**: radix literals with letter digits (`a06`).

```clojure
(read-string "36rN")
;; jank => 0N
;; clj  => 23
```

`lex.cpp` 955–1012: `N` and `M` are always taken as suffixes.

- [ ] **R10**: `@x` reads as an unqualified `deref` (`a10`).

```clojure
(read-string "@a")
;; jank => (deref a)
;; clj  => (clojure.core/deref a)
```

`parse.cpp` `parse_deref` (1803). A local named `deref` then shadows it.

- [ ] **R11**: a symbol tag is quoted (`a11`).

```clojure
(:tag (meta (read-string "^foo x")))
;; jank => (quote foo)
;; clj  => foo
```

`parse.cpp` `parse_meta_hint` (590–674, quoting at 614–625).

- [ ] **R13**: a set literal with keys that are `=` is accepted (`a13`).

```clojure
(read-string "#{1 1N}")
;; jank => no exception
;; clj  => IllegalArgumentException: Duplicate key: 1
```

The duplicate check (`parse.cpp` 722–743) compares hashes, and `1`/`1N` hash differently (D12).

- [ ] **R14**: `@` doesn't end a symbol (`a14`).

```clojure
(read-string "a@b")
;; jank => a@b
;; clj  => a
```

`lex.cpp` `is_special_char` (493–497) lacks `@`.

- [ ] **R15**: Unicode whitespace isn't whitespace (`a15`).

```clojure
(read-string "(\u2003a)")
;; jank => a list of one symbol that starts with U+2003
;; clj  => (a)
```

`lex.cpp` 558 uses byte-level `isspace`. Related: #224 (closed, U+2007 on macOS).

- [ ] **R16**: `:/` reads as a keyword with an empty name (`a16`).

```clojure
(name (read-string ":/"))
;; jank => ""
;; clj  => "/"
```

`parse.cpp` `parse_keyword` (1912–1929).

- [ ] **R19**: syntax quote qualifies a dotted symbol (`a19`).

```clojure
(eval (read-string "`(require 'clojure.set)"))
;; jank => (clojure.core/require (quote clojure.core/clojure.set))
;; clj  => (clojure.core/require (quote clojure.set))
```

`parse.cpp` 1489–1500.

- [ ] **R20**: an invalid number reads without error (`a20`).

```clojure
(read-string "1-2")
;; jank => no exception
;; clj  => NumberFormatException: Invalid number: 1-2
```

- [ ] **R21**: every read collection carries `:jank/source` metadata (`a21`).

```clojure
(meta (read-string "[1 2]"))
;; jank => {:jank/source {:module "clojure.core", :file "nil", …}}
;; clj  => nil
```

`parse.cpp` 387–418, 487–507; `core/meta.cpp` `source_to_meta` (171–228).

### Wrong values, no error: strings and printing

jank's strings are UTF-8; Clojure's are UTF-16. Several of these follow from that; R55 and R56
break `=` and `hash` themselves.

- [ ] **R55**: a string seq isn't `=` to itself (`b04`).

```clojure
(let [x (seq "é")] (= x x))
;; jank => false
;; clj  => true
```

`persistent_string_sequence.cpp` 34 → `seq_ext.hpp` 13 → `core/equal.cpp` 8.

- [ ] **R56**: a string seq and the equal vector hash differently (`b05`).

```clojure
(contains? (hash-set (seq "a")) [\a])
;; jank => false
;; clj  => true
```

`persistent_string_sequence.cpp` 72.

- [ ] **R53**: `seq` walks code points, disagreeing with jank's own `count` (`b02`).

```clojure
(count (seq "a😀"))
;; jank => 2   (and (count "a😀") is 5)
;; clj  => 3
```

`persistent_string_sequence.cpp` 78, 122, 128.

- [ ] **R57**: strings compare in UTF-8 byte order (`b06`).

```clojure
(compare "Ａ" "😀")
;; jank => -1
;; clj  => 9956
```

`immutable_string.hpp` 576.

- [ ] **R58**: `index-of` returns a byte index (`b07`).

```clojure
(clojure.string/index-of "éa" "a")
;; jank => 2
;; clj  => 1
```

`string.jank` 227/240 → `string_native.cpp` 257/264.

- [ ] **R59**: `trim` keeps Unicode whitespace (`b08`).

```clojure
(clojure.string/trim "\u2003a")
;; jank => "\u2003a"
;; clj  => "a"
```

`string_native.cpp` 271, 304: C `isspace` on bytes.

- [ ] **R60**: case mapping is one code point at a time (`b09`).

```clojure
(clojure.string/upper-case "ß")
;; jank => "ß"
;; clj  => "SS"
```

`util/string.cpp` 14, 26.

- [ ] **R61**: `capitalize` lower-cases a non-ASCII first letter (`b10`).

```clojure
(clojure.string/capitalize "Éa")
;; jank => "éa"
;; clj  => "Éa"
```

`util/string.cpp` 54.

- [ ] **R63**: `escape` never matches a non-ASCII character (`b12`).

```clojure
(clojure.string/escape "é" {\é "X"})
;; jank => "é"
;; clj  => "X"
```

`string.jank` 207–225.

- [ ] **R68**: doubles print in C++'s shortest form (`b15`).

```clojure
(str 100000.0)
;; jank => "1e+05"
;; clj  => "100000.0"
```

`number.cpp` 291/314 → `string_builder.cpp` 83–132.

- [ ] **R69**: `str` of a collection prints strings and characters unquoted (`b16`).

```clojure
(str ["a" \b])
;; jank => "[a b]"
;; clj  => "[\"a\" \\b]"
```

`persistent_vector.cpp` 96; `base_persistent_map.cpp` 62.

- [ ] **R70**: `pr-str` escapes BEL as `\a`, which Clojure's reader rejects (`b17`).

```clojure
(count (pr-str (str (char 7))))
;; jank => 4
;; clj  => 3
```

`util/escape.cpp` 179, 183.

- [ ] **R71**: `pr-str` of a regex doesn't escape `"` (`b18`).

```clojure
(pr-str (re-pattern "\""))
;; jank => "#\"\"\""   (#""", unreadable)
;; clj  => "#\"\\\"\""
```

`re_pattern.cpp` 23.

- [ ] **R72**: BigDecimals lose their scale and gain `.0` (`b19`).

```clojure
(str 1M)
;; jank => "1.0"
;; clj  => "1"
```

`big_decimal.cpp` 157, 169.

- [ ] **R76**: `print` of a string seq prints readable characters (`b23`).

```clojure
(print-str (seq "ab"))
;; jank => "(\\a \\b)"
;; clj  => "(a b)"
```

`persistent_string_sequence.cpp` 39–56.

### Wrong values, no error: regex

jank's regexes are `std::regex` (ECMAScript); Clojure's are `java.util.regex`.

- [ ] **R79**: `$` doesn't match before a final newline (`b25`).

```clojure
(re-find #"a$" "a\n")
;; jank => nil
;; clj  => "a"
```

- [ ] **R81**: `re-seq` searches the remainder as a new string (`b27`).

```clojure
(re-seq #"^a" "aa")
;; jank => ("a" "a")
;; clj  => ("a")
```

`core.cpp` `re_find` (972).

- [ ] **R82**: `re-matches` takes the first match, then checks that it covers the input (`b28`).

```clojure
(re-matches #"a|ab" "ab")
;; jank => nil
;; clj  => "ab"
```

`core.cpp` 1002.

- [ ] **R84**: replacements follow ECMAScript's rules (`b31`).

```clojure
(clojure.string/replace "5" #"(\d)" "\\$$1")
;; jank => "\\$1"
;; clj  => "$5"
```

`string_native.cpp` 224, 247.

### Throws or doesn't compile where Clojure works

- [ ] **D25**: `locking` can't compile (`d25`).

```clojure
(locking :lock 1)
;; jank => error: monitor-enter can't be resolved
;; clj  => 1
```

`core.jank` `locking` (5088) expands to `monitor-enter`/`monitor-exit` (5095), defined nowhere.

- [ ] **R2**: adjacent atoms need whitespace (`a02`).

```clojure
(read-string "(str\"a\")")
;; jank => error: expected whitespace
;; clj  => (str "a")
```

`lex.cpp` sets `require_space` at 1073, 1198, 1297, 1350.

- [ ] **R3**: `-0` before a delimiter is an error (`a03`).

```clojure
(read-string "[-0]")
;; jank => error: This base-8 number literal ended unexpectedly.
;; clj  => [0]
```

`lex.cpp` 691–707, 1030, 1056–1067.

- [ ] **R7**: a leading zero before `M` (`a07`).

```clojure
(read-string "08M")
;; jank => error
;; clj  => 8M
```

`lex.cpp` 691–723, 1107–1122: a leading `0` sets radix 8 and `M` keeps it.

- [ ] **R8**: octal string escapes are rejected (`a08`).

```clojure
(read-string "\"\\101\"")
;; jank => error: invalid escape sequence
;; clj  => "A"
```

`util/escape.cpp` `unescape` (35–145) has no octal case.

- [ ] **R12**: `#()` rejects `%10` and up (`a12`).

```clojure
(#(+ %10 %1) 1 2 3 4 5 6 7 8 9 10)
;; jank => error: invalid shorthand function parameter
;; clj  => 11
```

`parse.cpp` `parse_symbol` (1856–1860).

- [ ] **R17**: namespaced map literals are unsupported (`a17`).

```clojure
(read-string "#:a{:b 1}")
;; jank => error: unsupported reader macro
;; clj  => {:a/b 1}
```

`parse.cpp` `parse_reader_macro` (690–706).

- [ ] **R18**: Java-only regex syntax is a read error (`b30`).

```clojure
(re-pattern "(?i)a")
;; jank => C++ regex_error: Invalid '(?...)' zero-width assertion
;; clj  => #"(?i)a", matching "A"
```

`parse.cpp` `parse_regex` (888–913) → `re_pattern.cpp` 6–10.

- [ ] **R27**: `recur` in a fn inside a `loop` targets the loop (`r27`).

```clojure
((loop [a 1 b 2] (fn [y] (if y (recur nil) :done))) 5)
;; jank => error: recur … requires exactly 2
;; clj  => :done
```

`processor.cpp` `analyze_recur` (2143–2158); `loop_details` is set by `analyze_loop` (2611–2613).

- [ ] **R28**: an outer local shadows a named fn's own name (`r28`).

```clojure
((fn [f] ((fn f [n] (if (= n 0) :done (f 0))) 1)) 7)
;; jank => C++ exception: Invalid call to `small_integer` with `1` args provided.
;; clj  => :done
```

`processor.cpp` `analyze_symbol`: locals (1599) before the fn's name (1660).

- [ ] **R39**: a nested loop that rebinds a name breaks the outer `recur` (`r39`).

```clojure
(loop [i 0] (let [z (loop [i 5] (if (< i 6) (recur (inc i)) i))] (if (< i 2) (recur (inc i)) i)))
;; jank => C++ compile error
;; clj  => 2
```

`ir/processor.cpp` 270, 541: `local_to_loop_shadow` is never restored.

- [ ] **R40**: a nested fn that refers to its named parent crashes the compiler (`r40`).

```clojure
((fn my-f [] (fn [] my-f)))
;; jank => C++ exception: unordered_map::at
;; clj  => a fn
```

`ir/processor.cpp` 449 (`hoist_scoped_values`).

- [ ] **R41**: two `letfn`s in one fn emit invalid C++ (`r41`).

```clojure
((fn [] [(letfn [(f [] (g)) (g [] 1)] (f)) (letfn [(h [] 2)] (h))]))
;; jank => C++ compile error
;; clj  => [1 2]
```

`cpp_processor.cpp` 116, 897–904: `deferred_bindings` is never cleared.

- [ ] **R73**: `pr-str` takes one argument (`b20`).

```clojure
(pr-str 1 2)
;; jank => C++ exception: Invalid call … with `2` args provided.
;; clj  => "1 2"
```

`core.jank` 628–631.

- [ ] **R74**: the printer's dynamic vars don't exist (`b21`).

```clojure
(binding [*print-length* 2] (pr-str [1 2 3]))
;; jank => error: *print-length* can't be resolved
;; clj  => "[1 2 ...]"
```

`core.jank` 41.

- [ ] **R96**: booleans can't be compared with each other (`c01`).

```clojure
(compare true false)
;; jank => C++ exception: Objects of type `boolean` are not comparable to `boolean`.
;; clj  => 1
```

`number.cpp` 56 → `visit.hpp` 463 (no boolean case).

- [ ] **R98**: `compare` of two empty lists throws (`c03`).

```clojure
(compare '() '())
;; jank => error
;; clj  => 0
```

`equal.cpp` 24; `object.cpp` 228.

- [ ] **R101**: `get-method` throws when no method applies (`c06`).

```clojure
(defmulti f identity)
(get-method f ::nothing)
;; jank => C++ exception: … does not define a method for dispatch value …
;; clj  => nil
```

`core.cpp` 613 → `multi_function.cpp` 234.

- [ ] **R104**: `=` between sorted sets with incomparable keys throws (`r104`).

```clojure
(= (sorted-set 0) (sorted-set "a"))
;; jank => C++ exception: An object of type `persistent_string` was expected here, but a `small_integer` was provided instead.
;; clj  => false
```

`persistent_sorted_set.cpp` 56; `base_persistent_map.cpp` 31.

- [ ] **R114**: `range` over a long span throws (`r114`).

```clojure
(take 2 (range 9223372036854775807))
;; jank => C++ exception: integer_range overflow occurred in arithmetic.
;; clj  => (0 1)
```

`integer_range.cpp` 186, 197; `next` (113).

### Left out

- Refuted on main (jank behaves like Clojure): D3, D11, D14, D16b, D20, R45, R123 and one control.
  D11, D14 and D20 were fixed after jank 0.1.
- Failed in another way than predicted: D15 (A2 here), D23, R89 (a C++ enum; no Clojure
  equivalent). Unclear: R54 (`b03`, "Invalid UTF-8 string." where reading past the end was
  predicted).
- Not run (their shard's time went to the hangs above): `b01`, `b11`, `b24`, `b29`.
- In #1208: D1 and R25 (32-bit arithmetic), D4 (`quot` of a BigInt).
