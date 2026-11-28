(defproject jankifier/harness "0.1.0-SNAPSHOT"
  :description "An agent's harness in jank, on the inkling engine: tools are functions, and one of them evaluates code in the process's own nREPL."
  :license {:name "MIT"}
  :dependencies [[io.github.pfeodrippe/cards "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  ;; inkling.core and inkling's cards from the engine's own sources.
  :source-paths ["src" "../inkling/src" "../inkling/viz/src"]
  :main harness.main
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}
             ;; What an agent's code can use beyond the engine, loaded into the process when
             ;; asked for (HARNESS_PROFILES=extras ./harness.sh): an HTTP library (httplib.h),
             ;; and Veil, with Lean, in-process (veil.core).
             :extras {:dependencies [[org.jank-lang.commons/cpp-httplib-sys "2026.10-1"]
                                     [jankifier/veil "0.1.0-SNAPSHOT"]]}})
