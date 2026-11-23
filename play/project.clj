(defproject jankifier/play "0.1.0-SNAPSHOT"
  :description "Games for a model to play, in a jank process with its window of cards: an NES, NetHack and Doom, each one's state as data and text, and its picture in a card."
  :license {:name "MIT"}
  :dependencies [[jankifier/cards "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  :source-paths ["src"]
  :main play.main
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
