(defproject supercollider-sys/example "0.1-SNAPSHOT"
  :dependencies [[io.github.pfeodrippe/supercollider-sys "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  :main supercollider-sys.example
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}
             :release {:jank {:target-dir "target/release"
                              :optimization-level 3}}})
