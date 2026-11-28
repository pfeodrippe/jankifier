(defproject jankifier/bomsom-viz "0.1.0-SNAPSHOT"
  :description "bomsom in a jank REPL with a window of cards: the server, its levels, a scope, a spectrum and the synths with their controls, drawn every frame."
  :license {:name "GPL-3.0-or-later"
            :url  "https://github.com/supercollider/supercollider/blob/develop/COPYING"}
  :dependencies [[jankifier/cards "0.1.0-SNAPSHOT"]
                 [jankifier/supercollider-sys "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  ;; bomsom.core from the library's own sources.
  :source-paths ["src" "../src"]
  :main bomsom.viz
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
