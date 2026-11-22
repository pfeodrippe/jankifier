(require '[babashka.fs :as fs]
         '[jank.build.util :as util])

;; The library's own C++ (include/cards/cards.hpp: the window, its fonts, the drawing
;; primitives) on jank's include path.
(util/include-dir (str (fs/path (fs/parent *file*) "include")))
