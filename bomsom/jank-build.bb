(require '[babashka.fs :as fs]
         '[jank.build.util :as util])

;; bomsom's own C++ (include/bomsom/server.hpp) on jank's include path.
(util/include-dir (str (fs/path (fs/parent *file*) "include")))
