(defproject jank-specs "0.1-SNAPSHOT"
  :description "A REPL for tutorial.jank and native/: the Veil models of jank, called from jank through lean-sys."
  :dependencies [[jankifier/lean-sys "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  :source-paths ["native/src"]
  :main jank-specs.native
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
