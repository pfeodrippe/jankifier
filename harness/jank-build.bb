(require '[babashka.fs :as fs]
         '[jank.build.util :as util])

;; The harness's own header, and the engine, built by `make` in ../inkling (the build sandbox
;; can't run make: build it first): its headers and its library.
(let [here (fs/parent *file*)
      engine (fs/path (fs/parent here) "inkling")]
  (util/include-dir (str (fs/path here "include")))
  (util/include-dir (str (fs/path engine "include")))
  (util/link-library (str (fs/path engine "lib" "libinkling.dylib"))))
