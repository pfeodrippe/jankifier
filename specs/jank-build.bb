(require '[babashka.fs :as fs]
         '[jank.build.util :as util])

;; The conformance harnesses' C++ (include/jank_specs/harness.hpp).
(util/include-dir (str (fs/path (fs/parent *file*) "include")))

;; The model libraries, built here by `lake build +JankSpecs.Native.TinyAtom:dynlib` (the
;; build sandbox can't run Lake). Veil's packages first, dependencies before what uses them: a
;; Lean library resolves its imports' symbols among the libraries already loaded. lean-sys loads
;; Lean's runtime before all of these.
(let [lake (fs/path (fs/parent *file*) ".lake")
      package (fn [p lib] (str (fs/path lake "packages" p ".lake" "build" "lib" lib)))
      module (fn [lib] (str (fs/path lake "build" "lib" "lean" lib)))]
  (doseq [lib [(package "batteries" "libbatteries_Batteries.dylib")
               (package "Qq" "libQq_Qq.dylib")
               (package "aesop" "libaesop_Aesop.dylib")
               (package "proofwidgets" "libproofwidgets_ProofWidgets.dylib")
               (package "auto" "libauto_Auto.dylib")
               (package "cvc5" "libcvc5_cvc5.dylib")
               (package "smt" "libsmt_Smt.dylib")
               (package "lentil" "liblentil_Lentil.dylib")
               (package "Loom" "libLoom_Loom.dylib")
               (package "Lasso" "libLasso_Lasso.dylib")
               (package "VerifiedHAMT" "libVerifiedHAMT_VerifiedHAMT.dylib")
               (package "veil" "libveil_Veil.dylib")
               (module "jankSpecs_JankSpecs_Tutorial_TinyAtom.dylib")
               (module "jankSpecs_JankSpecs_Native_TinyAtom.dylib")]]
    (util/link-library lib)))
