(defproject jankifier/inkling "0.1.0-SNAPSHOT"
  :description "An inference engine for Inkling 2 Mini, run and inspected from jank."
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  :verbatim-paths ["include"])
