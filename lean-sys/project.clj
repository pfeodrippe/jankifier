(defproject jankifier/lean-sys "0.1.0-SNAPSHOT"
  :description "Calling Lean 4 from jank: Lean's runtime, its C API (lean/lean.h), and helpers."
  :license {:name "Apache 2.0"
            :url  "https://github.com/leanprover/lean4/blob/master/LICENSE"}
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  :verbatim-paths ["lean-toolchain"])
