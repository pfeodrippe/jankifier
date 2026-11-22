(require '[babashka.fs :as fs]
         '[jank.build.util :as util])

;; The engine's headers (inkling/inkling.hpp, inkling/jank.hpp) and its library, built here by
;; `make` with jank's own clang and libc++ (the build sandbox can't run make: build it first).
(util/include-dir (str (fs/path (fs/parent *file*) "include")))
(util/link-library (str (fs/path (fs/parent *file*) "lib" "libinkling.dylib")))
