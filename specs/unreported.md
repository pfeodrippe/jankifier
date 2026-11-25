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
`lean/jank`, rounds 1 to 4; round 3's S items appear here as LS and round 4's U items as LU, since S and U name this file's own), then checked on 2026-11-25 on jank main (`7135b7708`, x86-64
Linux, UTF-8 locale, each test in its own process with a 600 s limit, 120 s in round 3, through determinismo-ci)
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

- [ ] **LS34**: matching recurses per character, so long inputs overflow the stack (`deviations_r3_test.jank`: `s34`; on main: SIGSEGV).

```clojure
(re-find #"a*" (apply str (repeat 3000000 \a)))   ; Clojure "aaa…"   jank SIGSEGV
```

regex_executor.tcc `_M_dfs` 510, `_M_rep_once_more` 178, `_M_handle_match` 321. Nearly every frame is a non-tail call.

- [ ] **LU26**: `cpp/delete` of a pointer from C++'s own `new` crashes (`GC_free`) (`deviations_r4_test.jank`: `u26`; on main: SIGSEGV).

```clojure
(cpp/raw "inline int *make() { return new int(5); }")
(cpp/delete (cpp/make))   ; C++ frees it   jank SIGSEGV
```

codegen 1894–1919 emits `GC_free`; bdwgc `GC_free` 824–850 reads the header of memory the collector never allocated.

- [ ] **LU79**: `slurp` of a missing file ends the program: its native error can't be caught (`deviations_r4_test.jank`: `u79`; on main: an uncaught C++ exception "filesystem error: cannot get file size").

```clojure
(try (slurp "/no-such-dir/x.txt") (catch cpp/jank.runtime.object_ref _ :caught))   ; Clojure :caught   jank an uncaught C++ exception
```

core.jank `slurp`: `file_size` (7331) runs before `is_open`, and its `std::filesystem` error is no jank exception.

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

- [ ] **LS62**: a validator that calls `set-validator!` on its own atom hangs, and so does one that reads or updates its atom beside a concurrent `set-validator!` (`deviations_r3_hangs_test.jank`: `s62`; on main: still running after 120 s (killed)).

```clojure
(def a (atom 0))
(set-validator! a (fn [v] (when (= v 1) (set-validator! a (fn [_] true))) true))
(swap! a inc)   ; Clojure 1   jank hangs
```

atom.cpp `validate` 261–265 holds `validator.rlock()` (263) across the call; `set_validator` 236–241 takes `wlock()` (239). folly SharedMutex.h `lockExclusiveImpl` 1047–1110 sets kHasE, then waits for S (1086–1088).

- [ ] **LS63**: `alter-var-root` whose fn re-enters the var hangs (`deviations_r3_hangs_test.jank`: `s63`; on main: still running after 120 s (killed)).

```clojure
(def v 0)
(alter-var-root #'v (fn [x] (alter-var-root #'v inc) (+ x 10)))   ; Clojure 10   jank hangs
(alter-var-root #'v (fn [_] (def v 5) 6))                         ; Clojure 6    jank hangs
```

var.cpp `alter_root` 106–112 holds `write_mutex` (108) across `apply_to`; `bind_root` 101 takes it again. Clojure's methods are synchronized (reentrant).

- [ ] **LS64**: a delay whose body asks `(realized? d)` or derefs `d` hangs (`deviations_r3_hangs_test.jank`: `s64`; on main: still running after 120 s (killed)).

```clojure
(def d (delay (realized? d))) @d                ; Clojure false                jank hangs
(def e (delay @(future (realized? e)))) @e      ; Clojure false                jank hangs
(def s (delay @s)) @s                           ; Clojure StackOverflowError   jank hangs
```

delay.cpp `deref` 19–46 holds a non-recursive `std::mutex` (21) across the body (34); `is_realized` 51 takes it again.

- [ ] **LS65**: `future-cancel` of a future that another thread is dereferencing hangs all three threads (`deviations_r3_hangs_test.jank`: `s65`; on main: still running after 120 s (killed)).

```clojure
(def f (future (cpp/jank.runtime.sleep 100) 1)) (def g (future @f)) (cpp/jank.runtime.sleep 10)
(future-cancel f)   ; Clojure true (@g throws CancellationException)   jank: caller, g and f hang
```

future.cpp `deref` 17 holds the thread lock across `join()`. core.cpp `cancel_future` 1178 holds state S while taking the thread lock (1181). The future's completion needs state E (1132).

- [ ] **LS67**: reading pending lazy var metadata evaluates it under the var's exclusive lock, so a meta expression that reads the var's meta hangs (`deviations_r3_hangs_test.jank`: `s67`; on main: still running after 120 s (killed)).

```clojure
(defn mk [] (def ^{:doc "v" :m (meta #'v)} v 1)) (mk) (meta #'v)   ; Clojure the map   jank hangs
```

cpp_processor.cpp gen(def) 527–557 → var.cpp 296–302 → lazy_meta.cpp `get` 30–46 holds `state.wlock()` (32) across `_jank_eval_str`. - Needs a def compiled through codegen; the top-level interpreter sets meta eagerly.

- [ ] **LU13**: `alter-var-root` whose fn first-calls the var's fn hangs (a variant of LS63) (`deviations_r4_test.jank`: `u13`, `u13b`; on main: both hang (killed after 120 s)).

```clojure
(defn inc1 [x] (inc x))
(alter-var-root #'inc1 (fn [g] (g 1) g))             ; Clojure returns   jank hangs
(defn inc2 [x] (inc x))
(alter-var-root #'inc2 (fn [g] @(future (g 1)) g))   ; Clojure returns   jank hangs
```

var.cpp `alter_root` 108 holds `write_mutex`; the fn's first call realizes it, and `bind_root` 101 takes the mutex again. The Lean replica's tape: 10 steps on one thread, 12 on two (Mutexes.lean).

- [ ] **LU19**: `defmethod` with a lazy dispatch value realized by a thread calling the multimethod hangs (`deviations_r4_test.jank`: `u19`; on main: hangs (killed after 120 s)).

```clojure
(defmulti mm identity)
(defmethod mm :a [_] 1)
(let [l (lazy-seq (cons @(future (mm :a)) nil))]
  (defmethod mm l [_] 2)
  (mm l))   ; Clojure 2   jank hangs
```

multi_function.cpp `add_method` 145–153 holds the recursive mutex while hashing (realizing) `l`. `get_method` 248–260 takes the mutex on every call, because `cached_hierarchy` stores the var and is compared with its value, so the cache never matches. The Lean replica's tape: 7 steps.

- [ ] **LU28**: `with-meta` on `iterate` or `(range)` never returns (`deviations_r4_test.jank`: `u28`, `u28b`; on main: both hang (killed after 120 s)).

```clojure
(meta (with-meta (iterate inc 0) {:a 1}))   ; Clojure {:a 1}   jank never returns
(meta (with-meta (range) {:a 1}))           ; Clojure {:a 1}   jank never returns
```

An `iterator` isn't metadatable, and meta.cpp 50–53 builds the error's text from the infinite seq. Lean theorem `c2_iterate_with_meta`.

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

- [ ] **LS3**: non-terminating quotients return a value (`deviations_r3_test.jank`: `s03`; on main: `(/ 1.0M 3)` returned, no exception).

```clojure
(/ 1M 3)      ; Clojure throws "Non-terminating decimal expansion"   jank 0.333…M (128 digits)
(< 0M 1/3)    ; Clojure throws                                       jank true
```

- core/math.hpp `div` 299–340 → no_et_ops.hpp 139–166; - default_ops.hpp 569–574 (a long divisor is first converted to a decimal); - cpp_dec_float.hpp `operator/=` 1016–1045 → `calculate_inv` 1222–1286 (Newton iteration from a double estimate) → `operator*=` 951–1012, which keeps the top limbs and never rounds. `with-precision` is unported (core.jank 6487–6503).

- [ ] **LS4**: BigDecimals keep 128 significant digits (`deviations_r3_test.jank`: `s04`; on main: `(- 1.0M 1e-130.0M)` gave `1.0M`).

```clojure
(- 1M 1E-130M)   ; Clojure exact   jank 1.0M
(+ 1 1E130M)     ; Clojure exact   jank 1E+130
```

cpp_dec_float.hpp `rd_string` 2296–2318 and `operator+=` 759–937. A literal with 133 digits is truncated when read.

- [ ] **LS5**: BigDecimals below 1e-4 or from 1e128 print in boost's scientific form plus ".0" (`deviations_r3_test.jank`: `s05`; on main: `(str 1e-05.0M)` gave `"1e-05.0"`).

```clojure
(str 0.00001M)                    ; Clojure "0.00001"   jank "1e-05.0"
(pr-str 1E130M)                   ; Clojure "1E+130M"   jank "1e+130.0M"
(read-string (pr-str 0.00001M))   ; Clojure 0.00001M    jank lexer error
```

big_decimal.cpp 157–175 → string_builder.cpp 240–249 (appends ".0") → cpp_dec_float.hpp `str` 1913–2081; number_base.hpp 1394 picks the notation.

- [ ] **LS6**: a BigDecimal combined with a double gives a BigDecimal (`deviations_r3_test.jank`: `s06`; on main: `(+ 1.0M 0.5)` gave `1.5M`).

```clojure
(+ 1M 0.5)   ; Clojure 1.5                  jank 1.5M
(* 6M 0.1)   ; Clojure 0.6000000000000001   jank 0.600000000000000033306690738754696212708950042724609375M
```

math.hpp `add` 71–112 → boost `operator+(number, double)`, which converts the double exactly (cpp_dec_float.hpp 2461–2516) → make_box.hpp 36. Clojure uses `DOUBLE_OPS` (Numbers.java 976).

- [ ] **LS7**: `rem` of BigDecimals runs a 128-digit fmod (`deviations_r3_test.jank`: `s07`; on main: `(rem 1e+130.0M 3)` gave `99999997.0M`).

```clojure
(rem 1E130M 3)   ; Clojure 1M   jank 99999997.0M
```

math.cpp 269–289 → default_ops.hpp 1260–1321.

- [ ] **LS8**: `rem` of a ratio and a BigDecimal truncates the decimal first (`deviations_r3_test.jank`: `s08`; on main: `(rem 1.75M 1/2)` gave `0N`).

```clojure
(rem 1/2 0.1M)    ; Clojure 0.0M    jank throws "Division by zero is not permitted."
(rem 1.75M 1/2)   ; Clojure 0.25M   jank 0N
```

math.cpp 250–268 → generic_interconvert.hpp 533–563.

- [ ] **LS10**: BigDecimals that jank calls `=` hash differently (`deviations_r3_test.jank`: `s10`; on main: `(or (not= a b) (= (hash a) (hash b)))` was `false`).

```clojure
(count (hash-set 1M 1.0000000000000000001M))   ; jank 2, though jank's = says they are equal (D8)
```

big_decimal.cpp 177–180 → cpp_dec_float.hpp 259–266. The hashes are 3307139568 and 575929905.

- [ ] **LS11**: `(double x)` of a BigDecimal rounds twice and flushes subnormals to 0 (`deviations_r3_test.jank`: `s11`; on main: `(double 1e-310.0M)` gave `0.0`).

```clojure
(double 9007199254740993.00000000000000000001M)   ; Clojure 9.007199254740994E15   jank …992E15
(double 1E-310M)                                  ; Clojure 1.0E-310               jank 0.0
```

big_decimal.cpp 197–200 → `extract_double` 1570–1610 (rounds to 19 digits, then `strtod`).

- [ ] **LS12**: `(long x)` of a BigDecimal truncates exactly and saturates (`deviations_r3_test.jank`: `s12`; on main: `(long 1e+130.0M)` returned, no exception).

```clojure
(long 1E130M)   ; Clojure throws "Value out of range for long"   jank 9223372036854775807
```

big_decimal.cpp 192–195 → `extract_signed_long_long` 1664–1720.

- [ ] **LS14**: `(bigdec s)` follows boost's grammar (`deviations_r3_test.jank`: `s14`; on main: `(bigdec "inf")` returned, no exception).

```clojure
(bigdec "inf")   ; Clojure throws   jank inf
(bigdec "1e")    ; Clojure throws   jank 1.0M
(bigdec ".")     ; Clojure throws   jank 0.0M
```

math.cpp 823 → `rd_string` 2133–2147, 2104–2112, 2200.

- [ ] **LS15**: `(bigint s)` follows `cpp_int`'s grammar (`deviations_r3_test.jank`: `s15`; on main: `(bigint "010")` gave `8N`).

```clojure
(bigint "010")    ; Clojure 10N      jank 8N
(bigint "+5")     ; Clojure 5N       jank throws
(bigint "0x10")   ; Clojure throws   jank 16N
(bigint "-")      ; Clojure throws   jank 0N
```

math.cpp 765 → big_integer.cpp 33–58 (drops one trailing N) → cpp_int.hpp 1752–1922. A NUL ends the string.

- [ ] **LS19**: integer `/` with a BigInt operand truncates (`deviations_r3_test.jank`: `s19`; on main: `(/ 7N 2)` gave `3N`).

```clojure
(/ 7N 2)   ; Clojure 7/2   jank 3N
```

math.hpp `div` 299–340, using cpp_int's `/`.

- [ ] **LS20**: ratio arithmetic with a BigInt returns a long for an integral result (`deviations_r3_test.jank`: `s20`; on main: `(pr-str (* 0N 1/2))` gave `"0"`).

```clojure
(* 0N 1/2)   ; Clojure 0N   jank 0
(/ 3N 1/2)   ; Clojure 6N   jank 6
```

ratio.cpp 87–101.

- [ ] **LS21**: `(double -7/3)` divides two doubles (`deviations_r3_test.jank`: `s21`; on main: `(double -7/3)` gave `-2.3333333333333335`).

```clojure
(double -7/3)   ; Clojure -2.333333333333333   jank -2.3333333333333335
```

ratio.cpp 108–111. Not reported: dividing a BigDecimal by zero gives `inf.0M`/`nan.0M`; the book documents this behavior (68 questions). Also noted: `numerator`, `denominator` and `biginteger` print as `1N`, and `rationalize` is unported.

- [ ] **LS40**: float-to-integer conversions in emitted code have no range check (`deviations_r3_test.jank`: `s40`; on main: `(int 2147483648)` returned, no exception).

```clojure
(loop [x 0 n 0] (if (< n 1) (recur 1e10 (+ n 1)) x))   ; Clojure 1.0E10   jank -O0 -2147483648; -O1+ UB
(int 1e20)                                             ; Clojure throws   jank -O0 -9223372036854775808; -O1+ UB
(int 2147483648)                                       ; Clojure throws   jank 2147483648
((fn [^cpp/long p] p) 1e20)                            ; Clojure throws   jank UB inside libjank
```

(a) cpp_processor.cpp 1708–1716 (`static_cast<int>`); (b, c) math.hpp `to_int` 1410–1420; (d) `from_object` → `to_integer`; analyze_recur 2183–2214 → apply_implicit_conversion 1088–1118.

- [ ] **LU1**: (LS2) `(compare 2M (/ 6M 3M))`: Clojure 0, jank 1 (`deviations_r4_test.jank`: `u01`; on main: gave 1).

```clojure
(compare 2M (/ 6M 3M))         ; Clojure 0      jank 1
(= (str 2M) (str (/ 6M 3M)))   ; Clojure true   jank false
(compare 0.5M (/ 3 6M))        ; Clojure 0      jank 1
(compare 0.5M (/ 1.5M 3))      ; Clojure 0      jank 1
```

The same path as LS2.

- [ ] **LU2**: (LS9) `(compare 0.1M (bigdec 0.1))`: Clojure 0, jank -1 (`deviations_r4_test.jank`: `u02`; on main: gave -1).

```clojure
(compare 0.1M (bigdec 0.1))   ; Clojure 0   jank -1
```

math.cpp 817 → `operator=(double)`. The same as LS9.

- [ ] **LU75**: bit operations accept BigInts (`deviations_r4_test.jank`: `u75`; on main: `(bit-not (identity 5N))` threw nothing).

```clojure
(bit-not 5N)   ; Clojure throws   jank -6
```

math.cpp `to_i64` 22–25.

- [ ] **LU83**: `json/read-str` wraps integers in [2⁶³, 2⁶⁴) (`deviations_r4_test.jank`: `u83`; on main: gave -1).

```clojure
(json/read-str "18446744073709551615")   ; Clojure 18446744073709551615N   jank -1
```

json_native.cpp 142. Lean theorem `jank_reads_u64_wrapped`.

- [ ] **LU84**: `:bigdec` reads through a double (`deviations_r4_test.jank`: `u84`; on main: gave -1).

```clojure
(compare 0.1M (json/read-str "0.1" :bigdec true))   ; Clojure 0   jank -1
```

json_native.cpp 147. Extends LS9.

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

- [ ] **LU15**: `get-thread-bindings` maps each var to a box, not its value (`deviations_r4_test.jank`: `u15`; on main: gave false).

```clojure
(def ^:dynamic *x* 0)
(binding [*x* 1] (= 1 (get (get-thread-bindings) #'*x*)))   ; Clojure true   jank false
```

context.cpp `get_thread_bindings` 765–775 returns the `var_thread_binding` boxes (pushed at 706–750), and a box has no `equal`. Lean theorem `getTB_bound_differs`.

- [ ] **LU18**: `pop-thread-bindings` without a push returns nil instead of throwing (`deviations_r4_test.jank`: `u18`; on main: threw nothing).

```clojure
@(future (pop-thread-bindings))   ; Clojure throws   jank nil
```

context.cpp 752–763. Lean theorem `future_pop`.

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

- [ ] **LS38**: a macro expansion headed by a local's name is expanded again as a macro (`deviations_r3_test.jank`: `s38`; on main: `(let [comment (fn [x] (str "// " x))] (-> "hi" comment))` gave `nil`).

```clojure
(let [when 0] (and 1 (when true 7)))                       ; Clojure throws (0 is not a fn)   jank 7
(let [comment (fn [x] (str "// " x))] (-> "hi" comment))   ; Clojure "// hi"                  jank nil
(defn f [time] (-> 5 time)) (f inc)                        ; Clojure 6                        jank prints "Elapsed time…", 5
```

processor.cpp `analyze_call` 3501–3533 → context.cpp `macroexpand` 639–661 recurses at 657 → `macroexpand1` 604–637, which never checks locals. Clojure: `analyzeSeq` 7616–7618 and `isMacro` 7427–7430.

- [ ] **LS41**: a map or set expression whose keys collide at run time does not throw (`deviations_r3_test.jank`: `s41`; on main: `(let [a 1 b 1] {a :x, b :y})` returned, no exception).

```clojure
(let [a 1 b 1] {a :x b :y})          ; Clojure throws "Duplicate key"   jank {1 :y}
(let [a 1 b 1] #{a b})               ; Clojure throws                   jank #{1}
{(identity 1) :x (identity 1) :y}    ; top level: Clojure throws        jank {1 :x, 1 :y}, count 2
```

codegen/api.cpp 213–449 (`assoc_in_place`, `conj_in_place`); evaluate.cpp eval(map) 447–491 (`in_place_unique` 463/469) and eval(set) 493–509. Clojure: `RT.map`/`RT.set` → `createWithCheck`.

- [ ] **LU3**: (LS44) `(eval (list 'quote v))` turns `v`'s `{}` metadata into nil (`deviations_r4_test.jank`: `u03`; on main: gave nil).

```clojure
(let [v (with-meta [1] {})] (eval (list 'quote v)) (meta v))                      ; Clojure {}          jank nil
(let [v (with-meta [1] {:jank/source 1 :m 1})] (eval (list 'quote v)) (meta v))   ; Clojure both keys   jank {:m 1}
```

The same as LS44.

- [ ] **LU7**: (LS57, narrowed) inside a fn, `(if c 1 cpp/gd)` gives 2 where Clojure gives 2.5. At the top level, jank gives Clojure's result (`deviations_r4_test.jank`: `u07`; on main: gave 2).

```clojure
(cpp/raw "inline double gd = 2.5;")
((fn [c] (if c 1 cpp/gd)) false)   ; Clojure 2.5   jank 2
(if false 1 cpp/gd)                ; Clojure 2.5   jank 2.5 (top level)
```

cpp_util.cpp `find_branch_common_type` 1909–1995, for a compiled `if`. #1187 (closed 2026-11-17, in the checked commit) fixed other typed `if` branches; this case remains.

- [ ] **LU8**: an `alter-var-root` wrapper is lost at the wrapped fn's first call (`deviations_r4_test.jank`: `u08`; on main: the second call gave 2).

```clojure
(defn twice [x] (* 2 x))
(alter-var-root #'twice (fn [o] (fn [x] (+ 100 (o x)))))
[(twice 1) (twice 1)]   ; Clojure [102 102]   jank [102 2]
```

- [ ] **LU9**: `with-redefs`: the stub is replaced when the original first runs (`deviations_r4_test.jank`: `u09`; on main: gave `[:orig :orig]`).

```clojure
(defn greet [] :orig)
(let [o greet] (with-redefs [greet (fn [] :stub)] [(o) (greet)]))   ; Clojure [:orig :stub]   jank [:orig :orig]
```

core.jank `with-redefs-fn` 4549–4566.

- [ ] **LU10**: calling an old fn value for the first time reverts its var's redefinition (`deviations_r4_test.jank`: `u10`; on main: gave `:old`).

```clojure
(defn v [] :old)
(def s v)
(defn v [] :new)
(s)
(v)   ; Clojure :new   jank :old
```

- [ ] **LU11**: a defn'd fn's identity changes at its first call (`deviations_r4_test.jank`: `u11`; on main: `(identical? h f)` gave false).

```clojure
(defn f [] 1)
(def h f)
(f)
(identical? h f)   ; Clojure true   jank false
```

- [ ] **LU14**: a defn'd fn gets `{:name "ns/f"}` metadata after its first call (`deviations_r4_test.jank`: `u14`; on main: gave `{:name …}`).

```clojure
(defn f [] 1)
(f)
(meta f)   ; Clojure nil   jank {:name "user/f"}
```

processor.cpp 2064–2067; `realize` 66.

- [ ] **LU4**: (LS49) `(#cpp (add double) 1 2)`: C++ 3.0, jank 3 (`deviations_r4_test.jank`: `u04`; on main: gave 3).

```clojure
(cpp/raw "template <typename T> T add(T a, T b) { return a + b; }")
(#cpp (add double) 1 2)   ; C++ 3.0   jank 3
```

With the template declared in its own eval. The same as LS49.

- [ ] **LU20**: enum operands: jank's analysis ignores the user's operator, the JIT calls it, and the result is narrowed (0.5 becomes 0) (`deviations_r4_test.jank`: `u20`; on main: gave 0).

```clojure
(cpp/raw "enum ue { ua = 1, ub = 2 }; inline double operator*(ue, ue) { return 0.5; }")
(cpp/* cpp/ua cpp/ub)   ; C++ 0.5   jank 0
```

processor.cpp `build_cpp_call` 367–410 (`is_primitive` counts enums) types the call as the built-in operator's `int`; codegen 1794–1821 calls the user's operator and boxes its result as an `int`. Lean theorem `jank_primitive_operands_builtin_only`.

- [ ] **LU23**: operator lookup follows using-directives (`deviations_r4_test.jank`: `u23`; on main: threw nothing).

```clojure
(cpp/raw "namespace px { struct tag {}; }
          namespace pn { struct P {}; using namespace px; }
          namespace px { inline int operator|(pn::P const &, pn::P const &) { return 7; } }
          inline pn::P p;")
(cpp/| cpp/p cpp/p)   ; C++: no operator| found   jank accepts it
```

CppInterOp `GetOperator` 7017–7030 follows using-directives inside the associated namespaces; C++'s argument-dependent lookup ignores them.

- [ ] **LU24**: a user operator that C++ finds ambiguous with a built-in one is accepted (`deviations_r4_test.jank`: `u24`; on main: threw nothing).

```clojure
(cpp/raw "struct q { q(int) {} operator int() const { return 1; } };
          inline int operator+(q, q) { return 5; }
          inline q g(0);")
(cpp/+ cpp/g 1)   ; C++: ambiguous with int + int   jank accepts it
```

CppInterOp `BestOverloadMatch` 2203 adds no built-in candidates.

- [ ] **LU25**: `(cpp/wrap. 2.5)` uses the template's default arguments instead of deducing them (`deviations_r4_test.jank`: `u25`; on main: gave 2).

```clojure
(cpp/raw "template <typename T = int> struct wrap { T v; wrap(T x) : v(x) {} };")
(cpp/.-v (cpp/wrap. 2.5))   ; C++ 2.5 (wrap<double>)   jank 2 (wrap<int>)
```

`build_cpp_value` 3738–3752 → `instantiate(scope, {})` → CppInterOp.cpp `CompleteTemplateArguments` 6644 fills in the defaults. Lean theorem `jank_ctor_specialization_is_defaults`. Related: #525 (default arguments in templates, closed).

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

- [ ] **LS59**: a key or set element `=` to a stored one replaces the stored one in hash maps and hash sets (`deviations_r3_test.jank`: `s59`; on main: `(first (keys (assoc (hash-map (quote (1)) :a) [1] :b)))` gave `[1]`).

```clojure
(first (keys (assoc (hash-map '(1) :a) [1] :b)))   ; Clojure (1)   jank [1]
(first (conj #{'(1)} [1]))                         ; Clojure (1)   jank [1]
(first (conj #{0.0} -0.0))                         ; Clojure 0.0   jank -0.0
(let [m (into {} [[0 0] [1 1] [2 2] [3 3] [4 4] [5 5] [6 6] ['(1) 0]])]
  (some vector? (keys (assoc m [1] 1))))           ; Clojure nil   jank true (8 entries promote)
```

- persistent_hash_map.cpp 110 → immer map.hpp 400 → champ.hpp 604–606 (`copy_inner_replace_value`, the whole pair) and 577–581 (collision nodes); - transient paths: champ.hpp 697–699, 654; - sets: persistent_hash_set.cpp 151 → set.hpp 220; transient_hash_set.cpp 46. - Below 8 entries the array map keeps the stored key (native_array_map.cpp 139–162). - Clojure keeps the stored key: BitmapIndexedNode.assoc 704; PersistentHashSet.cons 98–101.

- [ ] **LS60**: an array-map transient can still be read after `persistent!` (`deviations_r3_test.jank`: `s60`; on main: `(let [t (transient {:a 1})] (persistent! t) (get t :a :nf))` returned, no exception).

```clojure
(let [t (transient {:a 1})] (persistent! t) (get t :a :nf))     ; Clojure throws   jank 1
(let [t (transient {:a 1})] (persistent! t) (contains? t :a))   ; Clojure throws   jank true
(let [t (transient {:a 1})] (persistent! t) (find t :a))        ; Clojure throws   jank [:a 1]
```

transient_array_map.cpp 47, 52, 62, 146 lack `assert_active()`; `to_persistent` 126–131 moves `data` with the defaulted move constructor (native_array_map.hpp 34), so the dead transient keeps the same array. #1235 (closed) is the vector case; array maps still answer after `persistent!`.

- [ ] **LU27**: `with-meta` on an infinite `repeat` writes the metadata into the original object (`deviations_r4_test.jank`: `u27`; on main: gave `{:a 1}`).

```clojure
(let [r (repeat 7)] (with-meta r {:a 1}) (meta r))   ; Clojure nil   jank {:a 1}
```

repeat.cpp `with_meta` 124–130 over `fresh_seq` 53–60, which returns `this` when infinite. Lean theorem `c1_repeat_meta_written`.

- [ ] **LU31**: `pop` of a one-element list drops the list's metadata (`deviations_r4_test.jank`: `u31`; on main: gave nil).

```clojure
(meta (pop (with-meta '(1) {:a 1})))   ; Clojure {:a 1}   jank nil
```

persistent_list.cpp `pop` 180–189.

- [ ] **LU32**: `seq` of a list drops the list's metadata (`deviations_r4_test.jank`: `u32`; on main: gave nil).

```clojure
(meta (seq (with-meta '(1 2) {:a 1})))   ; Clojure {:a 1}   jank nil
```

persistent_list.cpp 100–112.

- [ ] **LU33**: `transient` of a sorted map is accepted (`deviations_r4_test.jank`: `u33`; on main: threw nothing).

```clojure
(transient (sorted-map 1 2))   ; Clojure throws   jank a transient
```

- [ ] **LU34**: `array-map` with more than 8 pairs keeps only the first 8 keys (`deviations_r4_test.jank`: `u34`; on main: gave 8).

```clojure
(count (array-map 0 0 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8))   ; Clojure 9   jank 8
```

An update after 8 entries is also lost. persistent_array_map.cpp `create_from_seq` 36–55 discards the map `assoc_in_place` promotes to (transient_array_map.cpp 67–89). Lean theorem `jank_array_map_at_most_8`.

- [ ] **LU61**: `clojure.data/diff` never subdiffs maps, vectors or sets (`deviations_r4_test.jank`: `u61`; on main: gave `[{:a 1, :b 2} {:a 1, :b 3} nil]`).

```clojure
(clojure.data/diff {:a 1 :b 2} {:a 1 :b 3})   ; Clojure ({:b 2} {:b 3} {:a 1})   jank [{:a 1, :b 2} {:a 1, :b 3} nil]
```

data.jank 66: `equality-partition` is always `:atom`. Lean theorem `jankDiff_is_atomDiff`.

- [ ] **LU66**: `counted?` is true for strings, arrays and map seqs; `(bounded-count 1 "abc")` is 3 (`deviations_r4_test.jank`: `u66`; on main: gave true).

```clojure
(bounded-count 1 "abc")   ; Clojure 1       jank 3
(counted? "abc")          ; Clojure false   jank true
```

The same for arrays and map seqs. seq.cpp 131–141. Lean theorem `bounded_count_agree`.

- [ ] **LU67**: `map-entry?` is true for any 2-vector (`deviations_r4_test.jank`: `u67`; on main: gave true).

```clojure
(map-entry? [1 2])   ; Clojure false   jank true
```

Lean theorems `jank_map_entry_any_pair`, `map_entry_agree`.

- [ ] **LU69**: `clojure.walk` drops list metadata, which Clojure keeps since 1.12 (`deviations_r4_test.jank`: `u69`; on main: gave nil).

```clojure
(require '[clojure.walk :refer [postwalk]])
(meta (postwalk identity (with-meta '(1 2) {:m 1})))   ; Clojure 1.12 {:m 1} (1.11 nil)   jank nil
```

walk.jank 3–12. Lean theorems `jank_walk_drops_list_meta`, `walk_vec_meta_agree`.

- [ ] **LU81**: `zipmap` keeps the last of two equal keys (`deviations_r4_test.jank`: `u81`; on main: gave `(1)`).

```clojure
(first (keys (zipmap [[1] '(1)] [:a :b])))   ; Clojure [1]   jank (1)
```

core.jank 2411–2423 builds the map through a hash-map transient. Extends LS59.

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

- [ ] **LS16**: ratio parts that reach boost with a leading 0 are read as octal (`deviations_r3_test.jank`: `s16`; on main: `(read-string "0010/3")` gave `8/3`).

```clojure
0010/3                    ; Clojure 10/3                     jank 8/3
00017/1                   ; Clojure 17                       jank 15
1/0100000000000000000000  ; Clojure 1/100000000000000000000  jank 1/1152921504606846976
008/3                     ; Clojure 8/3                      jank throws
```

lex.cpp 905–915 (a radix-8 numerator drops only its first 0) and 916–935 (a denominator past i64 goes whole to boost).

- [ ] **LS17**: BigDecimal literal exponents and hex-looking literals (`deviations_r3_test.jank`: `s17`; on main: `(read-string "1e4294967296M")` returned, no exception).

```clojure
1e4294967296M   ; Clojure throws "Exponent overflow"   jank 1.0M (atoll, then an int32 wrap)
0x1e5M          ; Clojure invalid number               jank 100000.0M
1e67108872M     ; jank inf, printed "inf.0M"
```

lex.cpp 1123–1132 → `rd_string` 2104–2112, 2351–2375.

- [ ] **LU40**: no `:line`, `:column`, `:file`, `:name` or `:ns` metadata on read lists and defined vars; the nREPL's line/column fields never reach it (`deviations_r4_test.jank`: `u40`, `u40b`, `u40c`; on main: gave nil).

```clojure
(meta '(a b))         ; Clojure {:line … :column …}   jank nil
(defn f [])
(:line (meta #'f))    ; Clojure a line number         jank nil (also :column :file :name :ns)
;; an nREPL eval with "line" 7:
(:line (meta '(a)))   ; Clojure "7"                   jank "nil"
```

Positions only reach `{:jank/source …}` (core/meta.cpp 171–228), which `strip_source_meta` then removes; var.cpp `set_meta` 307–311 adds nothing. Lean theorems `jank_has_no_line_meta`, `jankPos_eq_cljPos`.

- [ ] **LU71**: `parse-uuid` accepts undashed and braced text (`deviations_r4_test.jank`: `u71`; on main: gave a uuid).

```clojure
(parse-uuid "00000000000000000000000000000000")         ; Clojure nil   jank #uuid "00000000-…"
(parse-uuid "{00000000-0000-0000-0000-000000000000}")   ; Clojure nil   jank #uuid "00000000-…"
```

stduuid uuid.h 503–547.

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

- [ ] **LS73**: `pr-str` of a namespace is its bare name (`deviations_r3_test.jank`: `s73`; on main: `(pr-str *ns*)` gave `"clojure.core"`).

```clojure
(pr-str *ns*)   ; Clojure "#object[clojure.lang.Namespace 0x… \"user\"]"   jank "user"
```

ns.cpp `to_code_string` 223.

- [ ] **LU16**: an unbound root prints `unbound@0x… for var #'x`, not `Unbound: #'x` (from LS70) (`deviations_r4_test.jank`: `u16`; on main: gave `"unbound@0x… for var …"`).

```clojure
(def x)
(str @#'x)   ; Clojure "Unbound: #'user/x"   jank "unbound@0x… for var #'user/x"
```

var.cpp 351–354. Lean theorem `unbound_str_differs`.

- [ ] **LU39**: `print` writes a pattern as its bare text (`deviations_r4_test.jank`: `u39`; on main: gave `"a"`).

```clojure
(print-str #"a")   ; Clojure "#\"a\""   jank "a"
```

Lean theorem `print_pattern_differs`.

- [ ] **LU63**: `Throwable->map` gives the outer exception's `:cause` and `:data`, not the root's (`deviations_r4_test.jank`: `u63`; on main: gave `"a"`).

```clojure
(:cause (Throwable->map (ex-info "a" {} (ex-info "b" {}))))   ; Clojure "b"   jank "a"
```

exception_info.cpp 116–148. Lean theorem `jank_cause_not_root`.

- [ ] **LU65**: `format` follows std::format: `(format "%d" 5)` is `"%d"` (`deviations_r4_test.jank`: `u65`; on main: gave `"%d"`).

```clojure
(format "%d" 5)   ; Clojure "5"    jank "%d"
(format "{}" 5)   ; Clojure "{}"   jank "5"
```

core.cpp 237–378. jank's docstring says std::format, but the book's differences page doesn't list it. Lean theorem `scan_no_braces`.

- [ ] **LU70**: a tagged literal prints its form with `str` (`deviations_r4_test.jank`: `u70`; on main: gave `"#foo bar"`).

```clojure
(pr-str (tagged-literal 'foo "bar"))   ; Clojure "#foo \"bar\""   jank "#foo bar"
```

- [ ] **LU78**: `spit` to a path it can't open returns nil (`deviations_r4_test.jank`: `u78`; on main: threw nothing).

```clojure
(spit "/no-such-dir/x.txt" "a")   ; Clojure throws   jank nil
```

- [ ] **LU85**: `write-str` writes BigInts and BigDecimals as strings (`deviations_r4_test.jank`: `u85`; on main: gave `"\"123\""`).

```clojure
(json/write-str 123N)   ; Clojure "123"   jank "\"123\""
```

json_native.cpp 69–72.

- [ ] **LU86**: `write-str` writes NaN as null (`deviations_r4_test.jank`: `u86`; on main: threw nothing).

```clojure
(json/write-str ##NaN)   ; Clojure throws   jank "null"
```

- [ ] **LU91**: `clojure.pprint/pprint` is `prn`: no line breaking at the right margin (`deviations_r4_test.jank`: `u91`; on main: printed one line).

```clojure
(with-out-str (clojure.pprint/pprint (vec (range 30))))   ; Clojure 30 lines   jank 1 line
```

jank's pprint.jank is `prn`; Clojure's dispatch.clj 92–101 breaks at the right margin, 72. Of `(vec (range n))` for n = 0..60, the 33 from n = 28 on differ. #147 (port clojure.pprint) is open.

- [ ] **LU64**: a printed exception chain lacks its root cause and repeats the middle one (`deviations_r4_test.jank`: `u64`; on main: the printed text had no `"c"`).

```clojure
(pr-str (ex-info "a" {} (ex-info "b" {} (ex-info "c" {}))))   ; Clojure names "a", "b" and "c"   jank no "c", "b" twice
```

exception_info.cpp 80–83. Lean theorem `jank_printed_via_wrong`.

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

- [ ] **LS22**: a quantifier after a non-ASCII character repeats only its last byte, and `\u00e9` and `\xe9` are the byte 0xE9 (`deviations_r3_test.jank`: `s22`; on main: `(re-matches (re-pattern "é*") "")` gave `nil`).

```clojure
(re-matches #"é*" "")    ; Clojure ""     jank nil
(re-find #"é+" "éé")     ; Clojure "éé"   jank "é"
(re-find #"\u00e9" "é")  ; Clojure "é"    jank nil
```

regex_scanner.tcc `_M_scan_normal` 96; regex_compiler.tcc `_M_quantifier` 179 (pops the last atom) and `_M_try_char` 563.

- [ ] **LS23**: `\uHHHH` above 0xFF is cut to its low byte (`deviations_r3_test.jank`: `s23`; on main: `(re-find (re-pattern "\\u0141") "A")` gave `"A"`).

```clojure
(re-find #"\u0141" "A")   ; Clojure nil (the pattern is Ł)   jank "A"
```

regex_scanner.tcc 353 → regex_compiler.tcc 563 (`assign(1, int)` narrows to `char`).

- [ ] **LS25**: possessive quantifiers compile, as nested greedy repeats (`deviations_r3_test.jank`: `s25`; on main: `(re-find (re-pattern "a++a") "aaa")` gave `"aaa"`).

```clojure
(re-find #"a++a" "aaa")       ; Clojure nil    jank "aaa"
(re-matches #"\d*+\d" "12")   ; Clojure nil    jank "12"
```

regex_compiler.tcc `_M_term` 138 (`while (_M_quantifier())`).

- [ ] **LS26**: a `{n}` after a quantifier repeats it; a `{n}` with nothing before it is a read error (`deviations_r3_test.jank`: `s26`; on main: `(re-find (re-pattern "a{2}{3}") "aaaaaa")` gave `"aaaaaa"`).

```clojure
(re-find #"a{2}{3}" "aaaaaa")   ; Clojure "aa"          jank "aaaaaa"
#"{2}"                          ; Clojure matches ""    jank read error
```

regex_compiler.tcc 138 and 80.

- [ ] **LS29**: POSIX bracket syntax and nested classes mean other things (`deviations_r3_test.jank`: `s29`; on main: `(re-find (re-pattern "[[:alpha:]]") "x")` gave `"x"`).

```clojure
(re-find #"[[:alpha:]]" "x")   ; Clojure nil   jank "x"
(re-find #"[[a]]" "a")         ; Clojure "a"   jank nil
(re-find #"[a-z&&[^b]]" "c")   ; Clojure "c"   jank nil
#"[[:foo:]]"                   ; Clojure valid   jank read error
```

regex_scanner.tcc 217–240; regex_compiler.tcc `_M_expression_term` 436; regex.tcc `lookup_classname` 279.

- [ ] **LS30**: `]` first in a class closes it (`deviations_r3_test.jank`: `s30`; on main: `(re-find (re-pattern "[]a]") "a")` gave `nil`).

```clojure
(re-find #"[]a]" "a")   ; Clojure "a"      jank nil
#"[^]"                  ; Clojure error    jank matches any byte, newline included
```

regex_scanner.tcc 248.

- [ ] **LS31**: Java escapes with another meaning (`deviations_r3_test.jank`: `s31`; on main: `(re-find (re-pattern "\\cJ") "\n")` gave `nil`).

```clojure
(re-find #"\cJ" "\n")      ; Clojure "\n"       jank nil (\cX is X)
(re-find #"\v" "\n")       ; Clojure "\n"       jank nil (VT only)
(re-find #"\Aa" "a")       ; Clojure "a"        jank nil (\A \z \Z \G are letters)
(re-find #"\Q.\E" ".")     ; Clojure "."        jank nil
(re-find #"\e" "e")        ; Clojure nil        jank "e"
(re-find #"\01" "\u0001")  ; Clojure "\u0001"   jank nil
#"\p{L}"  #"\x{41}"        ; Clojure valid      jank read errors
```

regex_scanner.tcc `_M_eat_escape_ecma` 310 (only `0 b f n r t v`; `\c` 344; `\x`/`\u` 353; any other letter is an identity escape).

- [ ] **LS33**: a lookahead at a search's first position sees a new input (`deviations_r3_test.jank`: `s33`; on main: `(re-find (re-pattern "a(?=\\b)") "ab")` gave `"a"`).

```clojure
(re-find #"a(?=\b)" "ab")            ; Clojure nil     jank "a"
(re-find #"foo(?=\bbar)" "foobar")   ; Clojure nil     jank "foo"
(re-seq #"b(?!^)" "b")               ; Clojure ("b")   jank nil
```

regex_executor.tcc `_M_lookahead` 151/157 builds the sub-executor with `_M_begin` at the current position. `_M_at_begin` (executor.h 167) and `_M_word_boundary` (552/560) look left only under `match_prev_avail`, which `_M_search` (42) sets only after the first start position.

- [ ] **LU35**: a capture made inside a lookahead at an earlier start position: Clojure keeps it, jank loses it (`deviations_r4_test.jank`: `u35`; on main: gave `["b" ""]`).

```clojure
(re-find #"(?=(a))x|b" "ab")   ; Clojure ["b" "a"]   jank ["b" ""]
```

Also `(re-find #"(?!(a))$" "a")`, and `clojure.string/replace` with `$1`. Java clears its groups once per `find`; libstdc++ restarts each start position from `_M_results` (regex_executor.tcc 41–57, 84–92). Census: 13,144 of 1,717,065 cases of up to 3 tokens differ, 178,668 of 39,495,600 of up to 4.

- [ ] **LU36**: `nth` on a matcher without groups indexes the match string's bytes (`deviations_r4_test.jank`: `u36`; on main: gave `\a`).

```clojure
(let [m (re-matcher #"ab" "xaby")] (re-find m) (nth m 0))   ; Clojure "ab"   jank \a
```

re_matcher.cpp 14–22 → the string's `nth`. Lean theorem `nth_no_groups_never_the_match`.

- [ ] **LU37**: `nth` on a matcher with no current match gives nil instead of throwing (`deviations_r4_test.jank`: `u37`; on main: threw nothing).

```clojure
(nth (re-matcher #"(a)" "a") 0)   ; Clojure throws   jank nil
```

Lean theorem `nth_without_match_nil`.

- [ ] **LU38**: `re-pattern` stops at the first NUL (`deviations_r4_test.jank`: `u38`; on main: gave `"x"`).

```clojure
(re-find (re-pattern (str "x" (char 0) "y")) "xz")   ; Clojure nil   jank "x"
```

re_pattern.cpp 6–11 uses `c_str()`. Lean theorem `jankEval4_pattern_nul`.

### Wrong values, no error: nREPL and the REPL

- [ ] **LU41**: `completions` gives each var the searched namespace as its `:ns` (`deviations_r4_test.jank`: `u41`; on main: gave `"user"`).

```clojure
;; nREPL {"op" "completions" "ns" "user" "prefix" "mapv"}
(:ns mapv-candidate)   ; Clojure "clojure.core"   jank "user"
```

completions.jank 54–64.

- [ ] **LU44**: after a read or analysis error, `(ex-message *e)` is `""` (`deviations_r4_test.jank`: `u44`; on main: gave `""`).

```clojure
;; nREPL evals, ns user
(ue5-undefined)
(ex-message *e)   ; Clojure "Syntax error compiling at (REPL:1:1)."   jank ""
```

evaluate.cpp `safe_eval` 750: the `exception_info` made from an `error_ref` gets no message.

### Wrong values, no error: modules and the CLI

- [ ] **LU45**: `run-main` calls `-main` with `*ns*` = clojure.core (Clojure: user) (`deviations_r4_test.jank`: `u45`; on main: gave `clojure.core`).

```clojure
;; jank run-main; Clojure: clojure -M -m
(defn -main [] (prn (ns-name *ns*) (read-string "::k")))   ; Clojure user :user/k   jank clojure.core :clojure.core/k
```

`eval` and `resolve` in `-main` act in clojure.core too. main.cpp `run_main` 83–115; context.cpp 107–113.

- [ ] **LU50**: `refer :only` accepts a set (`deviations_r4_test.jank`: `u50`; on main: threw nothing).

```clojure
(refer 'clojure.string :only #{'join})   ; Clojure throws   jank accepts it
```

- [ ] **LU51**: `:verbose` prints nothing (`deviations_r4_test.jank`: `u51`; on main: printed nothing).

```clojure
(with-out-str (require 'clojure.walk :reload :verbose))   ; Clojure "(clojure.core/load \"/clojure/walk\")\n"   jank ""
```

core.jank `load-lib` 4846.

- [ ] **LU55**: `(ns x)` gives the namespace `:jank/source` metadata (`deviations_r4_test.jank`: `u55`; on main: gave `{:jank/source …}`).

```clojure
(ns x)
(meta (find-ns 'x))   ; Clojure nil   jank {:jank/source …}
```

core.jank `ns` 5633–5637. Extends R21.

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

- [ ] **LS1**: `#'` followed by anything but a symbol is a read error (`deviations_r3_test.jank`: `s01`; on main: threw "Invalid var reader macro.").

```clojure
(read-string "#'1")   ; Clojure (var 1)         jank "A value after `#'` must be a symbol."
'[#'(f x)]            ; Clojure [(var (f x))]   jank: the file does not read
```

read/parse.cpp `parse_reader_macro_var_quote` 807 (check at 821–826). Clojure: LispReader VarReader 805–816.

- [ ] **LS18**: `bigint` of a ratio goes through i64 (`deviations_r3_test.jank`: `s18`; on main: threw: The value `33333333333333333333` is out of range for `i64` conversion.).

```clojure
(bigint 100000000000000000000/3)   ; Clojure 33333333333333333333N   jank throws "out of range for i64"
```

math.cpp 774–777 → ratio.cpp 113–116 → big_integer.cpp 200–208.

- [ ] **LS24**: a bracket range from ASCII to a non-ASCII byte is a read error (`deviations_r3_test.jank`: `s24`; on main: threw: Invalid range in bracket expression.).

```clojure
#"[a-é]"   ; Clojure valid   jank read error "Invalid range in bracket expression."
```

regex_compiler.h `_M_make_range` 500 compares signed `char`.

- [ ] **LS27**: a quantifier on an assertion is a read error (`deviations_r3_test.jank`: `s27`; on main: threw: Mismatched '(' and ')' in regular expression).

```clojure
#"^*a"  #"\b+a"  #"(?=a)*a"  #"a$?"   ; Clojure compile   jank read error
```

regex_compiler.tcc `_M_term` 134 returns after `_M_assertion`.

- [ ] **LS28**: backreferences that Java accepts are read errors (`deviations_r3_test.jank`: `s28`; on main: threw: Back-reference referred to an opened sub-expression.).

```clojure
#"\1"   #"\1(a)"   #"(a\1)"      ; Clojure compile               jank read errors
(re-find #"(a)\10" "aa0")        ; Clojure ["aa0" "a"] (\1 then "0")   jank read error (backref 10)
```

regex_scanner.tcc 372; regex_compiler.tcc 317 → regex_automaton.tcc 165/173.

- [ ] **LS32**: a class escape before `-` in a bracket is a read error (`deviations_r3_test.jank`: `s32`; on main: threw: Invalid start of '[x-x]' range in regular expression).

```clojure
#"[\w-a]"   ; Clojure \w, '-', 'a'   jank read error "Invalid start of '[x-x]' range"
```

regex_compiler.tcc 497.

- [ ] **LS35**: counted repeats past the NFA state limit are read errors (`deviations_r3_test.jank`: `s35`; on main: threw: Number of NFA states exceeds limit. Please use shorter regex string, or use smaller brace expression, or make _GLIBCXX_REGEX_STATE_LIMIT larger.).

```clojure
#"a{99999}"   #"\d{0,50000}"   ; Clojure valid   jank "Number of NFA states exceeds limit"
```

regex_compiler.tcc 243 → regex_automaton.h 33 (`_GLIBCXX_REGEX_STATE_LIMIT` 100000).

- [ ] **LS36**: a local bound to a number, boolean or string literal cannot appear in call position, even where Clojure never makes the call (`deviations_r3_test.jank`: `s36`; on main: threw "There is no call operator for `int`.").

```clojure
(let [x 1] (if false (x) :ok))      ; Clojure :ok   jank analyze/invalid-cpp-call
(let [x true] (if false (x) :ok))   ; Clojure :ok   jank compile error
(loop [f 2147483647 k 0] (if (= k 1) (f 2147483647) (recur :k 1)))   ; Clojure nil   jank compile error
```

processor.cpp `analyze_let` 2377 (literal native type, cpp_util.cpp `literal_type` 603–720) → `analyze_call` 3607 → `analyze_cpp_call` 4055 → `build_indirect_cpp_call` 874/965 "There is no call operator for `int`".

- [ ] **LS37**: `case` analyzes its default before its clauses (`deviations_r3_test.jank`: `s37`; on main: threw "The symbol `s37-h` could not be resolved.").

```clojure
(case 1 1 (def h 1) (h))                  ; Clojure #'user/h              jank unresolved symbol h
(case 2 1 (do (def inc 5) inc) (inc 1))   ; Clojure throws (unbound)      jank 2
(case 1 1 (var when) (do (def when 1) 2)) ; Clojure #'clojure.core/when   jank #'user/when
```

processor.cpp `analyze_case` 1386: default at 1466, clauses at 1500. Clojure: CaseExpr.Parser 9577 (clauses), then 9589 (default).

- [ ] **LS42**: more than 10 parameter symbols is rejected, and the `& rest` symbol counts as one (`deviations_r3_test.jank`: `s42`; on main: threw "This function has too many parameters. The max is 10. If you need more, use a variadic function.").

```clojure
(fn [a b c d e f g h i j k] k)     ; Clojure ok   jank "too many parameters. The max is 10"
(fn [a b c d e f g h i j & r] r)   ; Clojure ok   jank the same error
```

processor.cpp 1866–1872; `max_params` is 10 (core/call.hpp 18). - A fixed-arity fn called with N ≥ 11 arguments reports 11 in its arity error.

- [ ] **LS61**: a map's `conj` rejects a seq of entries, including an empty list (`deviations_r3_test.jank`: `s61`; on main: threw: invalid map entry: 'persistent_list').

```clojure
(conj {} ())                    ; Clojure {}        jank throws "invalid map entry"
(merge {:a 1} ())               ; Clojure {:a 1}    jank throws
(into {} [()])                  ; Clojure {}        jank throws
((fn [& {:as m}] m) :a 1 ())    ; Clojure {:a 1}    jank throws
```

obj/detail/base_persistent_map.cpp `conj` 169 (throws at 182–186: only nil, a map or a 2-vector); transient_array_map.cpp 98 (112–115); transient_hash_map.cpp 110 (124–129); core.jank destructure 3427–3436. Clojure: APersistentMap.cons 27–49 and ATransientMap.conj 25–47 walk any seqable.

- [ ] **LS71**: a top-level `(do …)` is analyzed as one form (`deviations_r3_test.jank`: `s71`; on main: threw "Invalid call to … with `0` args provided").

```clojure
(do (defmacro m [] 2) (m))   ; Clojure 2   jank throws "Invalid call to … with 0 args"
```

context_dynamic.cpp `eval_string` 59–71 analyzes each read form whole; processor.cpp `analyze_def` 1303–1306 interns at analysis; `analyze_call` 3505; evaluate.cpp eval(do) 574. Clojure: Compiler.eval 7684–7691 evaluates each form of a top-level `do` in turn.

- [ ] **LU29**: `(nth [1 2 3] 1.0)` throws instead of giving 2 (`deviations_r4_test.jank`: `u29`; on main: threw "requires an integer index, not a `small_real`").

```clojure
(nth [1 2 3] 1.0)   ; Clojure 2   jank throws
(nth [1 2 3] 1.5)   ; Clojure 2   jank throws
```

persistent_vector.cpp `nth` 322–348 checks the original index; lists truncate it. Lean theorem `c3_nth_double`.

- [ ] **LU30**: `(realized? (iterate inc 0))` throws (`deviations_r4_test.jank`: `u30`; on main: threw "Objects of type `iterator` are not realizable").

```clojure
(realized? (iterate inc 0))   ; Clojure true   jank throws
```

core.cpp `is_realized` 719–737.

- [ ] **LU49**: `load-string`, `requiring-resolve`, `ns-aliases`, `ns-refers` and others are unported, and `load-file` doesn't exist (the class of R113/R124, new names) (`deviations_r4_test.jank`: `u49`; on main: threw "TODO: port").

```clojure
(load-string "(+ 1 2)")                 ; Clojure 3                          jank throws "TODO: port"
(requiring-resolve 'clojure.core/inc)   ; Clojure #'clojure.core/inc         jank throws "TODO: port"
(ns-aliases 'clojure.core)              ; Clojure {}                         jank throws "TODO: port"
(resolve 'clojure.core/load-file)       ; Clojure #'clojure.core/load-file   jank nil
```

`load-reader`, `ns-refers` and `ns-imports` also throw "TODO: port".

- [ ] **LU62**: `ex-message`, `ex-data`, `ex-cause` of a non-exception throw instead of returning nil (`deviations_r4_test.jank`: `u62`; on main: threw "An object of type `exception_info` was expected").

```clojure
(ex-message "boom")   ; Clojure nil   jank throws
(ex-data "boom")      ; Clojure nil   jank throws
```

core.cpp 1338–1352.

- [ ] **LU68**: `shuffle` throws on `cons`, `repeat` and `sort` results (`deviations_r4_test.jank`: `u68`; on main: threw "Objects of type `cons` cannot be shuffled").

```clojure
(shuffle (repeat 3 :x))   ; Clojure [:x :x :x]   jank throws
(shuffle (cons 1 nil))    ; Clojure [1]          jank throws
```

seq.cpp 1178–1201. Extends R120.

- [ ] **LU76**: `(spit f 42)` throws (`deviations_r4_test.jank`: `u76`; on main: threw "`persistent_string` was expected, … `small_integer`").

```clojure
(def f "/tmp/x.txt")
(do (spit f 42) (slurp f))   ; Clojure "42"   jank throws
```

core.jank 7350.

- [ ] **LU77**: `slurp` takes no options (`deviations_r4_test.jank`: `u77`; on main: threw "Invalid call … with `3` args").

```clojure
(slurp "/tmp/x.txt" :encoding "UTF-8")   ; Clojure the text   jank throws (arity)
```

- [ ] **LU87**: `:eof-error? false` throws on empty input (`deviations_r4_test.jank`: `u87`; on main: threw "parse error … attempting to parse an empty input").

```clojure
(json/read-str "" :eof-error? false :eof-value :none)   ; Clojure :none   jank throws
```

json_native.cpp 198–202.

- [ ] **LU92**: `clojure.pprint` and `clojure.stacktrace` lack most of their documented functions (`deviations_r4_test.jank`: `u92`; on main: gave nil).

```clojure
(require 'clojure.pprint 'clojure.stacktrace)
(resolve 'clojure.pprint/print-table)             ; Clojure a var   jank nil
(resolve 'clojure.pprint/cl-format)               ; Clojure a var   jank nil
(resolve 'clojure.stacktrace/root-cause)          ; Clojure a var   jank nil
(resolve 'clojure.stacktrace/print-stack-trace)   ; Clojure a var   jank nil
```

`clojure.pprint/pp` and others are missing too. Lean theorems `pprint_missing`, `stacktrace_missing`. #147 (port clojure.pprint) is open.

- [ ] **LU5**: (LS50, now confirmed) a C++ function pointer with a `long const &` parameter can't be called with an integer (`deviations_r4_test.jank`: `u05`; on main: threw "argument 0 is not convertible from `int` to `const long &`").

```clojure
(cpp/raw "inline long twice(long const &x) { return 2 * x; } inline long (*twice_ptr)(long const &) = twice;")
(cpp/twice_ptr 21)   ; C++ 42   jank throws "argument 0 is not convertible"
```

Round 3's LS50, withdrawn then for lack of evidence (its run recorded no error text), confirmed by this run.

- [ ] **LU6**: (LS53, now confirmed) a built-in operator on a class that converts to `double` is refused (`deviations_r4_test.jank`: `u06`; on main: threw "The operator `+` is not supported for the type `u_b3_meters`").

```clojure
(cpp/raw "struct meters { double v; operator double() const { return v; } }; inline meters mk() { return {1.5}; }")
(cpp/+ (cpp/mk) 1.0)   ; C++ 2.5   jank throws "The operator `+` is not supported"
```

Round 3's LS53, withdrawn then for lack of evidence, confirmed by this run.

- [ ] **LU12**: `with-meta` on a defn'd fn not yet called throws (`deviations_r4_test.jank`: `u12`; on main: threw "… deferred_cpp_function … can't hold any metadata").

```clojure
(defn f [] 1)
(meta (with-meta f {:k 1}))   ; Clojure {:k 1}   jank throws "can't hold any metadata"
```

deferred_cpp_function.hpp 32–35 has no `with_meta`.

- [ ] **LU17**: `push-thread-bindings` refuses an array map (`deviations_r4_test.jank`: `u17`; on main: threw "invalid thread binding map (must be hash map)").

```clojure
(def ^:dynamic *x* 0)
(push-thread-bindings (array-map #'*x* 1))   ; Clojure binds *x* to 1   jank throws "must be hash map"
```

context.cpp 694–703. Lean theorem `pushArray_rejected`.

- [ ] **LU21**: a scoped enum's user `operator|` is refused (`deviations_r4_test.jank`: `u21`; on main: threw "The binary operator `|` is not supported for the types `u_b7_e` and `u_b7_e`").

```clojure
(cpp/raw "enum class e { a = 1, b = 2 };
          inline e operator|(e l, e r) { return static_cast<e>(static_cast<int>(l) | static_cast<int>(r)); }")
(cpp/| cpp/e.a cpp/e.b)   ; C++ e(3)   jank throws "not supported for the types"
```

Lean theorem `jank_primitive_operand_unary_builtin_only`.

- [ ] **LU22**: a derived class's operator doesn't hide its base's: the call is called ambiguous (`deviations_r4_test.jank`: `u22`; on main: threw "This call is ambiguous between 2 different overloads").

```clojure
(cpp/raw "struct base { int operator*(int) const { return 3; } };
          struct derived : base { int operator*(double) const { return 4; } }; inline derived d;")
(cpp/* cpp/d 1)   ; C++ 4   jank throws "This call is ambiguous"
```

CppInterOp.cpp `GetOperator` 6977–7064 adds the operators of every associated class; Clang's member lookup hides the base's.

- [ ] **LU48**: `load` of a resource path isn't found (`deviations_r4_test.jank`: `u48`; on main: threw "The module `/clojure/walk` could not be found").

```clojure
(load "/clojure/walk")   ; Clojure loads it   jank throws "could not be found"
```

core.jank `load` 4801.

- [ ] **LU59**: `compile` at run time throws (`deviations_r4_test.jank`: `u59`; on main: threw "Unable to write module, given output target 'unspecified'").

```clojure
(compile 'clojure.set)   ; Clojure clojure.set   jank throws "Unable to write module"
```

core.cpp 1361 returns nil where it doesn't throw.

- [ ] **LU72**: `areduce` throws: `unchecked-inc-int` is unported (`deviations_r4_test.jank`: `u72`; on main: threw "TODO: port unchecked-inc-int").

```clojure
(let [a (long-array [1 2 3])] (areduce a i ret 0 (+ ret (aget a i))))   ; Clojure 6   jank throws "TODO: port"
```

- [ ] **LU73**: `newline` throws: unported (`deviations_r4_test.jank`: `u73`; on main: threw "TODO: port newline").

```clojure
(with-out-str (newline))   ; Clojure "\n"   jank throws "TODO: port newline"
```

Round 4 predicts `flush` the same; this run stopped at `newline`.

- [ ] **LU74**: `unchecked-*`, `reversible?` and other core functions are unported (the class of R113/R124, new names) (`deviations_r4_test.jank`: `u74`, `u74b`; on main: threw "TODO: port unchecked-add", "TODO: port reversible?").

```clojure
(unchecked-add (identity 1) 2)   ; Clojure 3      jank throws "TODO: port unchecked-add"
(reversible? (identity []))      ; Clojure true   jank throws "TODO: port reversible?"
```

Also predicted unported: `into-array`, `indexed?`, `special-symbol?`, `instance?`, `class`, `with-open`, `line-seq`, the struct and stream functions, `reader-conditional`.

- [ ] **LU80**: `reduce-kv` over a seq of map entries throws (`deviations_r4_test.jank`: `u80`; on main: threw "Objects of type `persistent_array_map_sequence` do not support `reduce-kv`").

```clojure
(reduce-kv (fn [acc k _] (conj acc k)) [] (seq {:a 1}))   ; Clojure [:a]   jank throws "do not support `reduce-kv`"
```

seq.cpp 923–972.

- [ ] **LU82**: reading any `#inst` throws where the `en_US.UTF-8` locale isn't installed (`deviations_r4_test.jank`: `u82`; on main: threw "locale::facet::_S_create_c_locale name not valid").

```clojure
(read-string "#inst \"2020\"")   ; Clojure #inst "2020-01-01T00:00:00.000-00:00"   jank throws "name not valid"
```

inst.cpp 41 reads through `is.imbue(std::locale("en_US.utf-8"))`; Debian's and Ubuntu's base images ship only `C.UTF-8` (this run: Debian 13, `LANG=C.UTF-8`). Round 4's own prediction for this test (a year-only `#inst` read wrong, parse.cpp 948–975) waits for an image with that locale.

- [ ] **LU88**: `jank.shell/sh` splits an argument at a space that follows an odd number of `"` (`deviations_r4_test.jank`: `u88`; on main: printed `a\ b"` for `a" b`).

```clojure
(:out (sh "echo" "a\" b"))   ; Clojure "a\" b\n"   jank "a\\ b\"\n"
```

shell.jank `shell-escape` 78–79 and the joined command line (98–103) go through boost-process v1 `build_args` (detail/posix/basic_cmd.hpp 55–100): every `"`, an escaped one included, toggles the quote state.

- [ ] **LU89**: `sh` hangs when the child writes more than a pipe holds (`deviations_r4_hangs_test.jank`: `u89`; on main: still running after 120 s).

```clojure
(count (:out (sh "seq" "1" "100000")))   ; Clojure 588895   jank hangs
```

shell.jank 52–73 closes stdin and calls `process.wait()` before reading stdout: a child past the pipe's 65,536 bytes blocks for good. Clojure reads in futures before `waitFor` (java/shell.clj 118–130).

- [ ] **LU90** (low: Clojure's behavior is its source, not its docs): `sh`'s `:env` takes only strings (`deviations_r4_test.jank`: `u90`; on main: threw "An object of type `persistent_string` was expected here, but a `small_integer` was provided instead").

```clojure
(:out (sh "printenv" "N" :env {"N" 1}))   ; Clojure "1\n"   jank throws
```

`cpp/cast std.string` of a non-string (convert/builtin.hpp 333–336).

### Left out

- Refuted on main (jank behaves like Clojure): D3, D11, D14, D16b, D20, R45, R123 and one control.
  D11, D14 and D20 were fixed after jank 0.1.
- Failed in another way than predicted: D15 (A2 here), D23, R89 (a C++ enum; no Clojure
  equivalent). Unclear: R54 (`b03`, "Invalid UTF-8 string." where reading past the end was
  predicted).
- `b01`, `b11`, `b24`, `b29` (R52, R62, R78, R83) first had no result: their failure reports held
  invalid UTF-8 or a NUL, which the test runner's `grep` read as a binary file. Rerun with round 4,
  all four confirmed (rounds 1 and 2: 108 of 120).
- Round 4's reruns (2026-11-25), the runner reporting jank's error text: LU5, LU6, LU12, LU17,
  LU21, LU22, LU48, LU59, LU64, LU72, LU73, LU74, LU74b and LU79-LU81 confirmed; LU82 failed on
  another bug first (the `#inst` locale, its entry above); LU88-LU90 (jank.shell) confirmed in a
  second rerun once the test image had Boost's headers (jank's package depends on libboost-all-dev;
  the coverage image lacked them, and `(require 'jank.shell)` failed to compile).
- Round 3: refuted on main LS2 (BigDecimal division), LS9 (`bigdec` of a double), LS44 (`eval`
  of a quoted object's metadata), LS69 (an `ex-info` across a `finally`). The replica's round 4
  found LS2, LS9 and LS44's tests unable to see the prediction (jank's `=` on BigDecimals has
  D8's tolerance; LS44's metadata is one the strip pass keeps) and re-tests them with `compare`
  and `str`.
- LS50 (calls through function pointers) and LS53 (built-in operators on class operands), first
  listed as confirmed: their tests ran a `cpp/raw` and its use as one form, which jank analyzes
  whole (LS71), so jank's error says nothing about them. Re-tested by the replica's round 4. Failed in another way
  than predicted: LS49 and LS57 (C++ interop: jank errors where a wrong value was predicted), LS70
  (an unbound root prints jank's own way; no freed memory seen). Not checked yet: the items
  without a test (LS13, LS39, LS43, LS45-LS48, LS51, LS52, LS54-LS56, LS58, LS66, LS68, LS72,
  LS74-LS76).
- In #1208: D1 and R25 (32-bit arithmetic), D4 (`quot` of a BigInt).
