(defproject jankifier/bomsom "0.1.0-SNAPSHOT"
  :description "Sound from jank: SuperCollider's server in the process (supercollider-sys), driven from the REPL."
  :license {:name "GPL-3.0-or-later"
            :url  "https://github.com/supercollider/supercollider/blob/develop/COPYING"}
  :dependencies [[jankifier/supercollider-sys "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  :verbatim-paths ["include"]
  :main bomsom.core
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
