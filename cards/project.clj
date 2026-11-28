(defproject io.github.pfeodrippe/cards "0.1.0-SNAPSHOT"
  :description "A window of cards (Dear ImGui) following a jank REPL: each evaluation drawn by what its value is."
  :license {:name "MIT"}
  :dependencies [[io.github.pfeodrippe/jankifier "0.1.0-SNAPSHOT"]
                 [org.jank-lang.commons/imgui-sys "2026.10-1"]
                 [org.jank-lang.commons/imgui-glfw-sys "2026.10-1"]
                 [org.jank-lang.commons/imgui-opengl2-sys "2026.10-1"]]
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
  :main cards.main
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
