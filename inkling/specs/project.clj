(defproject inkling-specs "0.1-SNAPSHOT"
  :description "Veil models of the inkling engine's stateful logic, checked in-process from jank and compared with the engine (libinkling)."
  :dependencies [[jankifier/lean-sys "0.1.0-SNAPSHOT"]
                 [jankifier/veil "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  ;; ../src is inkling.core, the engine's jank namespace.
  :source-paths ["src" "../src"]
  :main inkling-specs.check
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
