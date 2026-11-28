(require '[babashka.fs :as fs]
         '[jank.build.util :as util])

;; bomsom's C++ (../include/bomsom/server.hpp) and the cards' (include/bomsom/viz.hpp).
(let [here (fs/parent *file*)]
  (util/include-dir (str (fs/path here "include")))
  (util/include-dir (str (fs/path (fs/parent here) "include"))))
