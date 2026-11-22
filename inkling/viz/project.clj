(defproject jankifier/inkling-viz "0.1.0-SNAPSHOT"
  :description "inkling in a jank REPL with a window of cards: what each evaluation gave, drawn."
  :license {:name "MIT"}
  :dependencies [[jankifier/cards "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  ;; inkling.core from the engine's own sources.
  :source-paths ["src" "../src"]
  :main inkling.viz.main
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
