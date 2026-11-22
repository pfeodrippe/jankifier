(defproject jankifier/veil "0.1.0-SNAPSHOT"
  :description "Veil models from jank, in-process: models as jank data, model checking, invariant proofs and runnable systems, with the results as jank data."
  :dependencies [[jankifier/lean-sys "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  :verbatim-paths ["include"])
