(require '[babashka.fs :as fs]
         '[jank.build.util :as util])

;; The engine, built by `make` in the directory above (the build sandbox can't run make: build
;; it first): its headers and its library.
(let [engine (fs/parent (fs/parent *file*))]
  (util/include-dir (str (fs/path engine "include")))
  (util/link-library (str (fs/path engine "lib" "libinkling.dylib"))))
