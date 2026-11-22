(defproject jank-specs "0.1-SNAPSHOT"
  :description "A REPL for the tutorials and native/: the Veil models of jank, run from jank through lean-sys and veil."
  :dependencies [[jankifier/lean-sys "0.1.0-SNAPSHOT"]
                 [jankifier/veil "0.1.0-SNAPSHOT"]

                 ;; for nrepl and macros
                 [jankifier "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  :source-paths ["native/src" "src"]
  :main jank-specs.native
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
