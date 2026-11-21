; The lib require-race.cljc requires: it counts how many times its body runs.
(ns repro-require-lib)
(swap! user/loads inc)
