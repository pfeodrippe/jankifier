(defproject io.github.pfeodrippe/jankifier "0.1.0-SNAPSHOT"
  :description "Utils for writing more jank than C++."
  :url "https://github.com/pfeodrippe/jankifier"
  ;; Published to Clojars by .github/workflows/clojars.yml, with the deploy token in its secrets.
  :deploy-repositories [["clojars" {:url "https://repo.clojars.org"
                                    :username :env/clojars_username
                                    :password :env/clojars_password
                                    :sign-releases false}]]
  ;; The scratch file stays out of the jar.
  :jar-exclusions [#"scratch\.jank$"]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}
             :release {:jank {:target-dir "target/release"
                              :optimization-level 3}}})
