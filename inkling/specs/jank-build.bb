(require '[babashka.fs :as fs]
         '[jank.build.util :as util])

;; The engine: its public header (inkling/inkling.hpp, inkling/jank.hpp), its internal header
;; (native/internal.hpp, for the thread pool and the Metal debugging entry point) and the library
;; built by `make` in inkling/. Veil's libraries are loaded by veil/session from a built Lake
;; project (../../specs), so nothing of Lean is linked here.
(let [inkling (fs/parent (fs/parent *file*))]
  (util/include-dir (str (fs/path inkling "include")))
  ;; The conformance tests' C++ (include/inkling_specs/harness.hpp).
  (util/include-dir (str (fs/path (fs/parent *file*) "include")))
  (util/include-dir (str (fs/path inkling "native")))
  (util/link-library (str (fs/path inkling "lib" "libinkling.dylib"))))
