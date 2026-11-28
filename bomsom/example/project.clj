(defproject bomsom/example "0.1-SNAPSHOT"
  :description "bomsom used as a project uses it: the REPL with its window of cards, and a tutorial to evaluate."
  :dependencies [[io.github.pfeodrippe/bomsom-viz "0.1.0-SNAPSHOT"]
                 [io.github.pfeodrippe/jankifier "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  :main bomsom-example.main
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}
             :local {:dependencies ^:replace [[io.github.pfeodrippe/supercollider-sys "0.1.0-SNAPSHOT"]
                                              [org.jank-lang.commons/imgui-sys "2026.10-1"]
                                              [org.jank-lang.commons/imgui-glfw-sys "2026.10-1"]
                                              [org.jank-lang.commons/imgui-opengl2-sys "2026.10-1"]]
                     :source-paths ["../src" "../viz/src" "../../cards/src" "../../src"]
                     :jank {:include-dirs ["../include" "../viz/include" "../../cards/include"]}}})
