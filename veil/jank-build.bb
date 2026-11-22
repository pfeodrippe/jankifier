(require '[babashka.fs :as fs]
         '[jank.build.util :as util])

;; veil's Lean code (veil_jank/source.hpp), elaborated into its sessions.
(util/include-dir (str (fs/path (fs/parent *file*) "include")))
