(require '[babashka.fs :as fs]
         '[clojure.string :as string]
         '[jank.build.util :as util])

;; Lean's runtime and its C header, from elan's toolchain of the version in lean-toolchain: a Lean
;; library built as a shared library works only with the runtime of the Lean version it was built
;; with.
(let [toolchain (string/trim (slurp (str (fs/path (fs/parent *file*) "lean-toolchain"))))
      ;; leanprover/lean4:v4.35.0 is installed in ~/.elan/toolchains/leanprover--lean4---v4.35.0
      dir-name  (-> toolchain (string/replace "/" "--") (string/replace ":" "---"))
      prefix    (str (System/getProperty "user.home") "/.elan/toolchains/" dir-name)]
  (util/include-dir (str prefix "/include"))
  (util/link-dir (str prefix "/lib/lean"))
  ;; In dependency order: these libraries have no rpath, so each finds the ones it depends on
  ;; only when they're already loaded. A library built by Lake depends on Lake_shared.
  (doseq [lib ["leanshared_1" "leanshared_2" "Init_shared" "leanshared" "Lake_shared"]]
    (util/link-library lib)))
