(defproject io.github.pfeodrippe/bomsom-viz "0.1.0-SNAPSHOT"
  :description "bomsom's cards for the cards window: the server, its levels, a scope, a spectrum and the synths with their controls, drawn every frame."
  :license {:name "GPL-3.0-or-later"
            :url  "https://github.com/supercollider/supercollider/blob/develop/COPYING"}
  :dependencies [[io.github.pfeodrippe/bomsom "0.1.0-SNAPSHOT"]
                 [io.github.pfeodrippe/cards "0.1.0-SNAPSHOT"]]
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
  ;; The window alone (./viz.sh); a project of one's own starts it with bomsom.viz/-main.
  :main bomsom.viz
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
