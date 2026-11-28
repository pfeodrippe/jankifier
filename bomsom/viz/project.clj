(defproject jankifier/bomsom-viz "0.1.0-SNAPSHOT"
  :description "bomsom's cards for the cards window: the server, its levels, a scope, a spectrum and the synths with their controls, drawn every frame."
  :license {:name "GPL-3.0-or-later"
            :url  "https://github.com/supercollider/supercollider/blob/develop/COPYING"}
  :dependencies [[jankifier/bomsom "0.1.0-SNAPSHOT"]
                 [jankifier/cards "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  :verbatim-paths ["include"]
  ;; The window alone (./viz.sh); a project of one's own starts it with bomsom.viz/-main.
  :main bomsom.viz
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
