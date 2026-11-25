;; Test of the Elle oracle; test.sh starts the oracle and runs this.
;; Usage: java -cp CP clojure.main test.clj DIR
;; Sends requests to the oracle serving DIR, waits for the answers and prints PASS/FAIL lines.
(ns oracle-test
  (:require [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:import (java.io File)
           (java.nio.file CopyOption Files StandardCopyOption)))

(def dir (io/file (first *command-line-args*)))

(def results
  "/Users/pfeodrippe/dev/determinismo-workloads/workloads/elle/lean/results")

(defn now-ms [] (/ (System/nanoTime) 1e6))

(defn send!
  "Writes NAME.req.edn (through a temp file and a rename). x is a request map or raw text."
  [name x]
  (let [tmp (File. dir (str name ".req.tmp"))]
    (spit tmp (if (string? x) x (pr-str x)))
    (Files/move (.toPath tmp) (.toPath (File. dir (str name ".req.edn")))
                (into-array CopyOption [StandardCopyOption/ATOMIC_MOVE]))))

(defn await-result
  "The parsed NAME.res.edn once it exists, or ::timeout."
  [name timeout-ms]
  (let [f  (File. dir (str name ".res.edn"))
        t1 (+ (now-ms) timeout-ms)]
    (loop []
      (cond (.exists f)    (edn/read-string (slurp f))
            (> (now-ms) t1) ::timeout
            :else          (do (Thread/sleep 5) (recur))))))

(def outcomes (atom []))

(defn report! [ok? name msg]
  (swap! outcomes conj ok?)
  (println (if ok? "PASS" "FAIL") name (str "- " msg))
  (flush))

(defn elle-answers
  "The answers in a .elle.edn file (one map per line, the :meta line left out), by :id."
  [file]
  (into {}
        (for [line (str/split-lines (slurp (io/file results file)))
              :when (not (str/blank? line))
              :let [m (edn/read-string line)]
              :when (not= :meta (:id m))]
          [(:id m) m])))

(defn serial-history
  "A serial closed-predicate history of n transactions over keys 0-3 (writes of unique values
  and reads of the current ones), which every consistency model allows."
  [n]
  (let [init {0 0, 1 0, 2 0, 3 0}]
    (loop [i 0, state init, ops [{:process 0 :type :invoke :f :init :value init}
                                 {:process 0 :type :ok :f :init :value init}]]
      (if (= i n)
        ops
        (let [k1 (mod i 4), k2 (mod (+ i 1) 4), v (inc i)
              inv [[:r k2 nil] [:w k1 v]]
              ok  [[:r k2 (state k2)] [:w k1 v]]
              p   (inc (mod i 5))]
          (recur (inc i) (assoc state k1 v)
                 (conj ops {:process p :type :invoke :f :txn :value inv}
                       {:process p :type :ok :f :txn :value ok})))))))

;; ---------------------------------------------------------------------------------------------
;; The requests, all sent at once and answered in order.

(def cp-cases
  (for [[file answers] [["closed-predicate" "closed-predicate.elle.edn"]
                        ["closed-predicate-2" "closed-predicate-2.elle.edn"]]
        :let [cases   (edn/read-string (slurp (io/file results (str file ".cases.edn"))))
              answers (elle-answers answers)]
        c cases]
    {:name (str file "-" (:id c)), :request c, :elle (answers (:id c))}))

(def d10-history
  (:history (nth (edn/read-string (slurp (io/file results "closed-predicate.cases.edn"))) 2)))

(def requests
  (concat
   (for [{:keys [name request elle]} cp-cases]
     {:name name
      :request request
      :check (fn [r]
               (cond (not= (:valid? r) (:valid? elle))
                     [false (str "valid? " (:valid? r) ", Elle's answer " (:valid? elle))]
                     (not= (:anomaly-types r) (:anomaly-types elle))
                     [false (str "anomaly-types " (:anomaly-types r) ", Elle's answer "
                                 (:anomaly-types elle))]
                     (not= r elle)
                     [false (str "valid? and anomaly-types match, the rest differs: " (pr-str r))]
                     :else
                     [true (str "valid? " (:valid? r) " " (:anomaly-types r)
                                ", the whole result equals the .elle.edn line")]))})
   [{:name "defaults"
     :request {:id "defaults" :history d10-history}
     :check (fn [r]
              [(and (false? (:valid? r)) (= ["G-single-item"] (:anomaly-types r)))
               (str "no :workload or :opts: valid? " (:valid? r) " " (:anomaly-types r))])}
    {:name "serial-400"
     :request {:id "serial-400" :opts {:consistency-models [:strict-serializable]}
               :history (serial-history 400)}
     :check (fn [r]
              [(and (true? (:valid? r)) (= [] (:anomaly-types r)))
               (str "802 ops, valid? " (:valid? r) " " (:anomaly-types r)
                    (when (:error r) (str " " (:error r))))])}
    {:name "malformed"
     :request "{:id :broken :history ["
     :check (fn [r]
              [(and (string? (:error r)) (not (contains? r :valid?)))
               (pr-str r)])}
    {:name "not-a-map"
     :request "[1 2 3]"
     :check (fn [r] [(string? (:error r)) (pr-str r)])}
    {:name "call-version<"
     :request {:id "d11" :call "elle.closed-predicate/version<"
               :args [{1 [0 :elle/dead]} 1 :elle/dead 0]}
      ;; Key 1's versions are [0 :elle/dead]: :elle/dead does not precede 0. version< is a
      ;; loopr that returns its accumulator found-a? when the versions run out (REPORT.md D11),
      ;; so Elle answers true; a direct call of Elle in its own JVM gives true too.
     :check (fn [r]
              [(= "true" (:value r))
               (str "(version< {1 [0 :elle/dead]} 1 :elle/dead 0) = " (or (:value r) (pr-str r)))])}
    {:name "call-resolve-version"
     :request {:id "unborn" :call "elle.closed-predicate/resolve-version"
               :args [{1 [:elle/unborn 0]} 1 nil]}
      ;; resolve-version compares with identical?, so :elle/unborn must arrive as the keyword.
     :check (fn [r]
              [(= ":elle/unborn" (:value r))
               (str "(resolve-version {1 [:elle/unborn 0]} 1 nil) = " (or (:value r) (pr-str r)))])}
    {:name "call-refused"
     :request {:id "refused" :call "clojure.java.shell/sh" :args ["touch" (str dir "/shell-ran")]}
     :check (fn [r]
              (Thread/sleep 50)
              [(and (some-> (:error r) (str/starts-with? "refused"))
                    (not (contains? r :value))
                    (not (.exists (File. dir "shell-ran"))))
               (pr-str r)])}]))

(defn run []
  (let [t0    (now-ms)
        named (map-indexed (fn [i r] (assoc r :file (format "%02d-%s" i (:name r)))) requests)]
    (doseq [{:keys [file request]} named]
      (send! file request))
    (doseq [{:keys [file name check]} named]
      (let [r (await-result file 120000)]
        (if (= ::timeout r)
          (report! false name "no result in 120 s")
          (let [[ok? msg] (check r)]
            (report! ok? name msg)))))
    (println (format "%d requests answered in %.0f ms" (count named) (- (now-ms) t0)))
    ;; Round trip of one small request on its own (includes the oracle's 100 ms polling).
    (let [t1 (now-ms)
          _  (send! "round-trip" (:request (first cp-cases)))
          r  (await-result "round-trip" 30000)]
      (report! (= (dissoc r :id) (dissoc (:elle (first cp-cases)) :id)) "round-trip"
               (format "one small check alone, %.0f ms from writing the request to reading the result"
                       (- (now-ms) t1))))
    (let [left (filter #(str/ends-with? (.getName ^File %) ".req.edn") (.listFiles dir))]
      (report! (empty? left) "requests-deleted"
               (if (empty? left) "no .req.edn left" (str "left: " (mapv #(.getName ^File %) left)))))))

(run)
(println (format "test.clj: %d passed, %d failed"
                 (count (filter true? @outcomes)) (count (remove true? @outcomes))))
(System/exit (if (every? true? @outcomes) 0 1))
