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
