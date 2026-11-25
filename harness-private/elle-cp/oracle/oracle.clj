;; Elle oracle: runs real Elle (jepsen-io/elle, commit 4e359e5) on request files.
;; Usage: java -Xmx2g -cp CP clojure.main oracle.clj DIR   (oracle.sh gives CP; see README.md)
;;
;; Loads Elle once, writes DIR/ready, then every 100 ms takes each DIR/NAME.req.edn, oldest first,
;; writes the answer to DIR/NAME.res.edn (through a temp file and a rename) and deletes the
;; request. A request is a check {:id :workload :opts :history} or a call {:id :call :args}.
;; Each one gets LIMIT seconds (30, or $ELLE_ORACLE_LIMIT_S). It exits when DIR/stop exists,
;; deleting DIR/stop and DIR/ready.
;;
;; run-one is run.clj's, from the Lean replica of Elle in determinismo-workloads
;; (workloads/elle/lean/runner/run.clj), unchanged.
(ns oracle
  (:require [clojure.edn :as edn]
            [clojure.string :as str]
            [clojure.walk :as walk]
            [jepsen.history :as h]
            [elle.list-append :as la]
            [elle.rw-register :as rr]
            [elle.closed-predicate :as cp]
            [elle.core])
  (:import (java.io File Writer)
           (java.lang.management ManagementFactory)
           (java.nio.file CopyOption Files StandardCopyOption)))

(def limit-s
  (or (some-> (System/getenv "ELLE_ORACLE_LIMIT_S") parse-long) 30))

(def poll-ms 100)

;; Results longer than this are refused, so a huge or endless lazy value can't fill the heap.
(def max-result-chars (* 64 1024 1024))

;; A request that is not readable EDN and was modified less than this long ago may still be
;; being written; it is tried again on a later poll.
(def settle-ms 1000)

(defn log [& xs]
  (locking log
    (println (str (java.time.LocalTime/now)) (str/join " " xs))
    (flush)))

;; ---------------------------------------------------------------------------------------------
;; From run.clj (determinismo-workloads, workloads/elle/lean/runner/run.clj), unchanged.

(defn run-one [{:keys [id workload opts history]}]
  (try
    (let [hist (h/history history)
          res  (case workload
                 :list-append      (la/check opts hist)
                 :rw-register      (rr/check opts hist)
                 :closed-predicate (cp/check opts hist)
                 :monotonic (elle.core/check {:analyzer elle.core/monotonic-key-graph} hist)
                 :monotonic-realtime (elle.core/check
                                      {:analyzer (elle.core/combine elle.core/monotonic-key-graph
                                                                    elle.core/realtime-graph)}
                                      hist))]
      {:id id
       :valid? (:valid? res)
       :anomaly-types (vec (sort (map name (:anomaly-types res))))
       :not (vec (sort (map name (:not res))))
       :also-not (vec (sort (map name (:also-not res))))
       :anomalies (into (sorted-map)
                        (for [[t cs] (:anomalies res)]
                          [(name t)
                           (if (sequential? cs)
                             (vec (for [c cs]
                                    (cond (:cycle c) {:cycle (mapv :index (:cycle c))
                                                      :steps (mapv :type (:steps c))
                                                      :type (:type c)}
                                          (:scc c) {:scc (:scc c)}
                                          :else (dissoc c :op :writer :txns :mop))))
                             cs)]))})
    (catch Throwable e
      {:id id :error (str (.getName (class e)) ": " (.getMessage e))
       :data (when (instance? clojure.lang.ExceptionInfo e)
               (select-keys (ex-data e) [:valid? :type :message]))})))

;; ---------------------------------------------------------------------------------------------

(defn error-result
  ([id msg] (if (some? id) {:id id :error msg} {:error msg}))
  ([id msg ^Throwable e]
   (error-result id (str msg (.getName (class e)) ": " (.getMessage e)))))

(defn plain
  "Turns records (e.g. jepsen.history.Op) into plain maps, so the result reads as plain EDN."
  [x]
  (walk/postwalk (fn [y] (if (record? y) (into {} y) y)) x))

(defn bounded-pr-str
  "pr-str, but it throws when the thread is interrupted or the text passes max-result-chars, so
  printing an endless lazy seq ends at the time limit."
  [x]
  (let [sb  (StringBuilder.)
        put (fn [^String s]
              (when (Thread/interrupted)
                (throw (InterruptedException. "interrupted while printing the result")))
              (when (> (+ (.length sb) (.length s)) max-result-chars)
                (throw (ex-info (str "the result is longer than " max-result-chars " characters")
                                {})))
              (.append sb s))
        ;; A proxy fn takes every overload of its name: write(int), write(char[]),
        ;; write(String), write(char[] off len) and write(String off len).
        w   (proxy [Writer] []
              (write
                ([x]
                 (put (cond (string? x)  x
                            (integer? x) (String/valueOf (char x))
                            :else        (String. ^chars x))))
                ([buf off len]
                 (put (if (string? buf)
                        (subs buf off (+ (long off) (long len)))
                        (String. ^chars buf (int off) (int len))))))
              (flush [])
              (close []))]
    (binding [*out* w
              *print-length* nil
              *print-level* nil
              *print-meta* false
              *print-dup* false
              *print-namespace-maps* false]
      (pr x))
    (str sb)))

(defn check-request [{:keys [id workload opts history]}]
  (cond
    (not (sequential? history)) (error-result id "malformed request: :history must be a vector of ops")
    (not (or (nil? opts) (map? opts))) (error-result id "malformed request: :opts must be a map")
    ;; :directory would make Elle write files; the answer comes back in the result file instead.
    :else (run-one {:id       id
                    :workload (or workload :closed-predicate)
                    :opts     (dissoc (or opts {}) :directory)
                    :history  history})))

(defn call-request [{:keys [id call args]}]
  (let [sym (cond (symbol? call) call
                  (string? call) (symbol call))
        nsn (some-> sym namespace)]
    (cond
      (not (and sym nsn (seq (name sym))))
      (error-result id (str "malformed request: :call must name a var as \"namespace/name\", got "
                            (pr-str call)))

      (not (str/starts-with? nsn "elle."))
      (error-result id (str "refused: " sym " is not in a namespace starting with \"elle.\""))

      (not (or (nil? args) (sequential? args)))
      (error-result id "malformed request: :args must be a vector")

      :else
      (try
        (let [v (requiring-resolve sym)
              f (some-> v deref)]
          (cond
            (nil? v)               (error-result id (str "no such var: " sym))
            (:macro (meta v))      (error-result id (str sym " is a macro, not a function"))
            (not (or (fn? f) (instance? clojure.lang.MultiFn f)))
            (error-result id (str sym " is not a function"))
            :else                  {:id id :value (bounded-pr-str (apply f args))}))
        (catch Throwable e
          (error-result id "" e))))))

(defn handle [req]
  (if (contains? req :call)
    (call-request req)
    (check-request req)))

(defn run-limited
  "Handles the request on another thread and returns its result as an EDN string, or an error
  if it takes more than limit-s. A check that ignores the interrupt may keep running in the
  background until it ends; the oracle moves on."
  [req]
  (let [id  (:id req)
        fut (future
              (try (bounded-pr-str (plain (handle req)))
                   (catch Throwable e
                     (pr-str (error-result id "" e)))))
        res (deref fut (* 1000 limit-s) ::timeout)]
    (if (= ::timeout res)
      (do (future-cancel fut)
          (pr-str (error-result id (str "Elle did not end in " limit-s " seconds"))))
      res)))

(defn read-request
  "The request map, {::malformed msg}, or ::not-yet if it may still be being written."
  [^File f]
  (let [age (- (System/currentTimeMillis) (.lastModified f))]
    (try
      (let [req (edn/read-string (slurp f))]
        (if (map? req)
          req
          {::malformed "malformed request: it is not a map"}))
      (catch Throwable e
        (if (< age settle-ms)
          ::not-yet
          {::malformed (str "malformed request: it is not readable EDN: " (.getMessage e))})))))

(defn write-atomically! [^File out ^String s]
  (let [tmp (File. (.getParentFile out) (str (.getName out) ".tmp"))]
    (spit tmp (str s "\n"))
    (Files/move (.toPath tmp) (.toPath out)
                (into-array CopyOption [StandardCopyOption/ATOMIC_MOVE
                                        StandardCopyOption/REPLACE_EXISTING]))))

(def undeletable
  "Requests answered whose files could not be deleted; not taken again."
  (atom #{}))

(defn pending [^File dir]
  (->> (.listFiles dir)
       (filter (fn [^File f]
                 (and (.isFile f)
                      (str/ends-with? (.getName f) ".req.edn")
                      (not (@undeletable (.getPath f))))))
       (sort-by (fn [^File f] [(.lastModified f) (.getName f)]))))

(defn process!
  "Answers one request file. Returns true if it did (false if it was left for later)."
  [^File dir ^File f]
  (let [fname (.getName f)
        base  (subs fname 0 (- (count fname) (count ".req.edn")))
        out   (File. dir (str base ".res.edn"))
        t0    (System/nanoTime)
        req   (when (.exists f) (read-request f))]
    (cond
      (nil? req)          false
      (= ::not-yet req)   false
      :else
      (let [res (try
                  (if-let [m (::malformed req)]
                    (pr-str (error-result nil m))
                    (run-limited req))
                  (catch Throwable e
                    (pr-str (error-result (when (map? req) (:id req)) "oracle error: " e))))]
        (write-atomically! out res)
        (when-not (or (.delete f) (not (.exists f)))
          (swap! undeletable conj (.getPath f))
          (log "could not delete" fname))
        (log fname (format "%.1f ms" (/ (- (System/nanoTime) t0) 1e6))
             (if (> (count res) 200) (str (subs res 0 200) "...") res))
        true))))

(defn warm-up!
  "One small closed-predicate check, so the first request does not pay for loading classes."
  []
  (run-one {:id :warm-up
            :workload :closed-predicate
            :opts {:consistency-models [:serializable]}
            :history [{:process 0 :type :invoke :f :init :value {0 0, 1 0}}
                      {:process 0 :type :ok :f :init :value {0 0, 1 0}}
                      {:process 1 :type :invoke :f :txn :value [[:delete 1]]}
                      {:process 1 :type :ok :f :txn :value [[:delete 1]]}
                      {:process 2 :type :invoke :f :txn :value [[:r 1 nil] [:r 0 nil]]}
                      {:process 2 :type :ok :f :txn :value [[:r 1 nil] [:r 0 nil]]}]}))

(defn -main [dir-path]
  (let [dir   (File. ^String dir-path)
        stop  (File. dir "stop")
        ready (File. dir "ready")]
    (.mkdirs dir)
    (warm-up!)
    (log "ready on" (.getPath dir) "after"
         (str (.getUptime (ManagementFactory/getRuntimeMXBean)) " ms of JVM time;")
         "limit" (str limit-s " s"))
    (write-atomically! ready (str (.pid (java.lang.ProcessHandle/current))))
    (loop []
      (if (.exists stop)
        (do (.delete ready)
            (.delete stop)
            (log "stop")
            (shutdown-agents)
            (System/exit 0))
        (let [answered (try
                         (reduce (fn [n f]
                                   (if (.exists stop)
                                     (reduced n)
                                     (if (process! dir f) (inc n) n)))
                                 0 (pending dir))
                         (catch Throwable e
                           (log "error in the loop:" (str e))
                           0))]
          (when (zero? answered)
            (Thread/sleep (long poll-ms)))
          (recur))))))

(if (= 1 (count *command-line-args*))
  (-main (first *command-line-args*))
  (do (println "usage: java -cp CP clojure.main oracle.clj DIR")
      (System/exit 2)))
