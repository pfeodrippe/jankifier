(require '[babashka.fs :as fs]
         '[jank.build.util :as util])

;; The games' C interface (include/play/play.h) and its library, built by `make` here (the
;; build sandbox can't run make: build it first).
(let [here (fs/parent *file*)]
  (util/include-dir (str (fs/path here "include")))
  (util/link-library (str (fs/path here "lib" "libplay.dylib"))))
