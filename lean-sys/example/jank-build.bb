(require '[babashka.fs :as fs]
         '[jank.build.util :as util])

;; The example's own Lean library, built by `lake build` in lean/ (the build sandbox can't run
;; Lake: build it before `lein run`). This project's directives come after its dependencies', so
;; the library loads after Lean's runtime, which lean-sys links.
(util/link-dir (str (fs/path (fs/parent *file*) "lean" ".lake" "build" "lib")))
(util/link-library "leanSysExample_LeanSysExample")
