(require '[babashka.fs :as fs]
         '[jank.build.util :as util])

;; The cards' C++ (include/bomsom/viz.hpp) on jank's include path; bomsom's own comes with it.
(util/include-dir (str (fs/path (fs/parent *file*) "include")))
