# jank, for someone who knows Clojure

Notes for writing jank code in this process (jank 0.1, macOS). Each line was
tried here. jank is a Clojure dialect compiled to native code through C++:
the syntax, the data structures and most of `clojure.core` and
`clojure.string` are Clojure's (`clojure.set` after
`(require '[clojure.set :as set])`).

## What is missing or different

- **No JVM.** Nothing of Java exists: `(.method obj)` on Java objects,
  `Thread/sleep`, `System/currentTimeMillis`, `java.io.File`. Using one is an
  error when the code is read, even inside `try`.
- **Integers have 32 bits.** `(* 100000 100000)` is `1410065408` and
  `(+ 2147483647 1)` is `-2147483648`. For larger numbers use reals:
  `(* 100000.0 100000.0)`.
- **`format` does not format**: `(format "%d items" 3)` returns `"%d items"`.
  Use `str`.
- **No `load-file`, no `doc`.** Load a file with the load_file tool; read
  documentation with the describe tool or `(:doc (meta (var some.ns/name)))`,
  and list a namespace with the functions tool or `(keys (ns-publics 'some.ns))`.
- **In the eval tool**, `str` is clojure.string and `set` clojure.set, and every
  top-level form's value is shown.
- **`require` first, in an evaluation of its own.** `(do (require '[x :as y])
  (y/f))` fails, because the whole form is read before any of it runs. Several
  forms in one evaluation are fine: they run one after the other.
- **A text bound by `let` and used inside an inner function** must be made
  with `str`: `(let [s (str "text")] (fn [] s))`. With the bare literal the
  code does not compile ("cannot be captured").
- **`count` is unsigned.** `(max 0 (- (count [1 2]) 5))` is `-3`, and `min`
  of a count and a negative number is the count. Write `(long (count xs))`
  before subtracting from it or comparing it with what may be negative.
- **Strings are bytes** for `count`, `subs` and `clojure.string/index-of`:
  `(count "é")` is 2.
- **Regular expressions**: `[...]` classes and `\s` also match the bytes of
  accented letters. On such text use plain strings, or patterns without them.
- **Errors** are caught by type, inside `try` as in Clojure:

  ```clojure
  (try
    (risky)
    (catch jank.runtime.object_ref e (ex-message e))   ; ex-info and thrown values
    (catch cpp/jank.error_ref e (cpp/.-message (cpp/* e)))   ; jank's own: (subs "ab" 2 1)
    (catch cpp/std.exception e (cpp/.what e)))          ; C++'s: slurp of a missing file
  ```
  `(catch :default e ...)` catches anything, but `e` is nil there: use it only
  when what was thrown doesn't matter.
- **`first` of an empty sort ends the process**: `(first (sort []))` and
  `(first (sort-by f []))` crash (a segmentation fault), though `(sort [])` is
  `()`. Take `seq` first: `(first (seq (sort-by f xs)))` is nil when `xs` is
  empty. (jank's issue 1181, fixed in a later jank than this one.)
- **Integer division by zero gives 0**: `(/ 1 0)` is 0, it doesn't throw.
- **Sleeping**: `(cpp/usleep 250000)` (microseconds).
- **`(deref f 2000 :late)` doesn't wait**: with a timeout, `deref` returns nil at
  once (neither the value nor `:late`). Wait for a future with `@f`, or with a
  loop: `(loop [] (when-not (realized? f) (cpp/usleep 10000) (recur)))`.
- **Files**: this process can write only in its own directory (and the
  directory in `$TMPDIR`); a `spit` anywhere else writes nothing, without an
  error. `(spit path text :append true)` adds to the end of a file. `spit`
  into a directory that doesn't exist writes nothing and returns nil, without an
  error; `slurp` of a missing file throws C++'s error
  (above). There is no function to make a directory or to ask whether a file
  exists: use C++'s (see [Files and directories](#files-and-directories)).
- **The shell is macOS's**: `sed -i '' 's/a/b/' file` (BSD sed needs the `''`),
  no GNU-only options.
- **A `future` must catch everything it can throw.** What escapes one ends the
  whole process (an abort), not just the future. Wrap its body in `try` with
  the three `catch`es above and `(catch :default _ ...)`.
- **A loop that never stops doesn't compile as a function's last form**:
  `(defn spin [] (loop [n 0] (recur (inc n))))` fails when called ("'break'
  statement not in loop"). Give the loop a way to stop: `(when (running?)
  (recur ...))`. (A function is compiled the first time it runs, so in a
  `future` this error too ends the process.)
- These are here: atoms, `future` and `deref`, `binding`, `delay`,
  `slurp` and `spit`, `read-string`, `parse-long`, `re-find`, `sort-by`,
  transients, multimethods, `defmacro`.

## Calling C++

Names of C++ are written with `cpp/` and dots for `::`.

```clojure
(cpp/usleep 1000)                          ; a C function
(cpp/std.string "abc")                     ; a constructor; a std::string comes back as a string
(cpp/.size (cpp/std.string "abc"))         ; a method                                  ;=> 3
(cpp/.-field obj)                          ; a field
(cpp/int 3)                                ; a native int
(cpp/* pointer)  (cpp/& value)             ; what a pointer points to; a value's address
```

C++ source is given whole with `cpp/raw`, at the top level of an evaluation:
includes, namespaces, functions. What it defines is called like any C++.

```clojure
(cpp/raw "#include <cmath>
namespace mine
{
  inline double hyp(double const a, double const b)
  {
    return std::sqrt(a * a + b * b);
  }
}")

(cpp/mine.hyp 3.0 4.0)                                                               ;=> 5.0
```

- Write `inline` on functions and variables defined this way.
- A function called from jank takes and returns numbers, `bool`, strings
  (`std::string`), or jank values (`jank::runtime::object_ref`). Other C++
  types can't cross: an error says the type "is not convertible".
- A compile error of the C++ comes back as the evaluation's error, with
  clang's message.
- C++ names can't have `-` in them: `make-dir` is not a name there, `make_dir` is.
- C++ given to `cpp/raw` is checked with clang before jank compiles it; when
  it doesn't compile, clang's message comes back and nothing of it is run.
- C++ does not allow defining the same thing twice. The same source evaluated
  again is fine (nothing happens); a changed function under the same name is
  refused ("redefinition"), and the earlier one stays. So give corrected or
  changed source a **new namespace name** (`mine2`, `mine3`), and call that one.

### Files and directories

```clojure
(cpp/raw "#include <filesystem>
namespace files
{
  inline bool make_dirs(std::string const &path)
  {
    std::error_code ec;
    std::filesystem::create_directories(path, ec);
    return std::filesystem::is_directory(path);
  }

  inline bool exists(std::string const &path)
  {
    return std::filesystem::exists(path);
  }
}")

(cpp/files.make_dirs "work/store")       ;=> true: made, with its parents, or already there
(cpp/files.exists "work/store/log")      ;=> false
```

In a file of your own, put the `cpp/raw` form at the top level, after the
`ns` form.

### A jank function called from C++

A jank function is an `object_ref`; C++ calls it with `.call(...)`. A text
becomes a jank value with `make_box`, and a jank value becomes text with
`to_string`.

```cpp
jank::runtime::object_ref f;                                    // a jank function
auto const arg{ jank::runtime::make_box<jank::runtime::obj::persistent_string>(
  jtl::immutable_string{ text.data(), text.size() }) };         // std::string -> jank
auto const said{ jank::runtime::to_string(f.call(arg)) };       // call it; jank -> text
std::string const out{ said.data(), said.size() };
```

## An HTTP server

`httplib.h` (cpp-httplib) is on the include path when the process was started
with `HARNESS_PROFILES=extras`. This was tried: every GET is answered by a
jank function that gets the path and returns the text.

```clojure
(cpp/raw "#include <httplib.h>
#include <thread>
namespace web
{
  inline httplib::Server server;
  inline jank::runtime::object_ref handler;

  inline void start(jank::runtime::object_ref const f, int const port)
  {
    handler = f;
    server.Get(\".*\", [](httplib::Request const &req, httplib::Response &res) {
      auto const path{ jank::runtime::make_box<jank::runtime::obj::persistent_string>(
        jtl::immutable_string{ req.path.data(), req.path.size() }) };
      auto const said{ jank::runtime::to_string(handler.call(path)) };
      res.set_content(std::string{ said.data(), said.size() }, \"text/plain\");
    });
    std::thread{ [port] { server.listen(\"127.0.0.1\", port); } }.detach();
  }

  inline void stop()
  {
    server.stop();
  }
}")

(defn answer [path] (str "hello from jank: " path "\n"))
(cpp/web.start answer 8097)
;; then, with the shell tool: curl -s -m 3 localhost:8097/abc
(cpp/web.stop)
```

The server listens on a thread of its own, so `start` returns at once. The
jank function can be defined again while the server runs only if C++ looks it
up each time; here it holds the function it was started with.

## Veil

`veil.core` (with `HARNESS_PROFILES=extras`) runs
[Veil](https://github.com/verse-lab/veil) in this process. A model is a Veil
file (`.lean`, VEIL.md says how to write one), elaborated into a session with
`veil/load-file!`; `veil/model-check` then checks it by its module's name and
returns a counterexample as jank data. Require it **before** including
`httplib.h` (a macOS header that comes with it defines `nil` as a macro, and
Lean's header then fails to compile).

```clojure
(require '[veil.core :as veil])
(def vs (veil/session {:lake-project "../specs"}))                                ; about 12 s
(veil/load-file! vs "work/lot.lean" {:checks? false})   ; Lean's messages: [{:severity :line :text}]
(veil/model-check vs "ParkingLot" {:instance {:spot 2} :max-depth 8})
```
