(defproject io.github.pfeodrippe/bomsom "0.1.0-SNAPSHOT"
  :description "Sound from jank: SuperCollider's server in the process (supercollider-sys), driven from the REPL."
  :license {:name "GPL-3.0-or-later"
            :url  "https://github.com/supercollider/supercollider/blob/develop/COPYING"}
  :dependencies [[io.github.pfeodrippe/supercollider-sys "0.1.0-SNAPSHOT"]]
  :url "https://github.com/pfeodrippe/jankifier"
  ;; Published to Clojars by .github/workflows/clojars.yml, with the deploy token in its secrets.
  :deploy-repositories [["clojars" {:url "https://repo.clojars.org"
                                    :username :env/clojars_username
                                    :password :env/clojars_password
                                    :sign-releases false}]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  :verbatim-paths ["include"]
  :main bomsom.core
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
