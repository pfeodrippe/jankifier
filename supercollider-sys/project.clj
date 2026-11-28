(defproject io.github.pfeodrippe/supercollider-sys "0.1.0-SNAPSHOT"
  :description "SuperCollider's server as a library (libscsynth), its UGen plugins and its C API, for jank."
  :license {:name "GPL-3.0-or-later"
            :url  "https://github.com/supercollider/supercollider/blob/develop/COPYING"}
  :url "https://github.com/pfeodrippe/jankifier"
  ;; Published to Clojars by .github/workflows/clojars.yml, with the deploy token in its secrets.
  :deploy-repositories [["clojars" {:url "https://repo.clojars.org"
                                    :username :env/clojars_username
                                    :password :env/clojars_password
                                    :sign-releases false}]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  ;; What configuring and building libscsynth and the plugins reads from SuperCollider's tree
  ;; (83 MB, most of it its own copy of Boost): CMake also configures sclang (lang, SCDoc,
  ;; editors), though only the server's targets are built.
  :verbatim-paths ["lib/supercollider/CMakeLists.txt"
                   "lib/supercollider/SCVersion.txt"
                   "lib/supercollider/build_sclang.cfg.in"
                   "lib/supercollider/COPYING"
                   "lib/supercollider/cmake_modules"
                   "lib/supercollider/common"
                   "lib/supercollider/include"
                   "lib/supercollider/server"
                   "lib/supercollider/external_libraries"
                   "lib/supercollider/lang"
                   "lib/supercollider/SCDoc"
                   "lib/supercollider/platform"
                   "lib/supercollider/editors"
                   "lib/supercollider/tools"])
