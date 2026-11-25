"""The trials, driven from outside the harness's process: does checking code against a Veil
model (harness.verify) make the model's code right more often?

    python3 drive.py lru,kv,queue 1,2,3 plain,verified

Each run is a process of its own, started for it and ended after it, so that nothing of
another run (its conversation, the namespaces it loaded, results) is there:

1. its directory (HOME) made anew: JANK.md and an empty work/, and for a verified run
   VERIFY.md and examples/parking.jank;
2. the harness started (harness.sh), the engine, the model and Veil's session loaded;
3. the process moved to HOME and sandboxed (harness.tools/confine!): it can't read the
   harness's sources and notes, this folder, the results, or this machine's other files under
   the home directory, beyond what compiling needs; that is checked before the run;
4. the task asked, in the mode, sampled with the seed: the task's text is sent with the run,
   nothing else about the trials is loaded;
5. the code graded in a new process of its own (the same sandbox, no model): graders.jank (this
   folder) sent only now, and the result appended to
   OUT/results.edn;
6. the process ended.

The run in progress is kept in OUT/live.edn; from a REPL of the harness elsewhere:
(hc/follow-file! "../trials-out/live.edn" "live"). Each run's conversation is kept in
OUT/<task>-<mode>-<seed>.edn (harness.cards/replay!).

The modes:
  plain     the task, and "test it with the eval tool until you are sure"
  verified  the task, VERIFY.md, the verify tool, and the gate: the turn ends only once the
            file passes harness.verify/check
"""
import json, os, shutil, signal, socket, subprocess, sys, time

PROJECT = '/Users/pfeodrippe/dev/jankifier'
HARNESS = PROJECT + '/harness'
PRIVATE = PROJECT + '/harness-private'
# TRIALS_OUT: another directory for the runs (an experiment kept apart from the trials).
OUT = os.environ.get('TRIALS_OUT', PROJECT + '/trials-out')
HOME = '/private/tmp/jank-agent/home'
TMP = '/private/tmp/jank-agent/tmp'   # the process's TMPDIR: the shared one holds other programs' files
USER_HOME = os.path.expanduser('~')

TASKS = {
    'lru': {'file': 'work/lru.jank', 'ask': (
        "Write the file work/lru.jank, a jank namespace `lru` with an LRU cache:\n"
        "- (new-cache capacity): a cache holding at most `capacity` entries (capacity >= 1).\n"
        "- (lookup cache k): the value for k, or nil. A key found becomes the most recently used.\n"
        "- (store! cache k v): k gets v and becomes the most recently used. When that makes more "
        "entries than the capacity, the least recently used entry is dropped.\n"
        "- (cached-keys cache): the keys held, most recently used first, as a vector.\n"
        "Keys and values are any jank values.")},
    'kv': {'file': 'work/kv.jank', 'ask': (
        "Write the file work/kv.jank, a jank namespace `kv` with a key-value store kept in a log "
        "file in a directory:\n"
        "- (open-store dir): the store kept in the directory `dir` (made if missing). It recovers "
        "what the log there holds.\n"
        "- (put! store k v) and (del! store k): each is appended to the log as a record before it "
        "returns, and changes the store.\n"
        "- (fetch store k): the value for k, or nil.\n"
        "- (crash! store keep): a crash during the last record written: the log keeps only the "
        "first `keep` bytes of that record (all of it when keep is at least its length; the "
        "records before it are whole). After a crash the store is opened again with open-store.\n"
        "Keys are integers; values are integers or strings without newlines. A write that returned "
        "is never lost, unless a crash tore its record (it was the last one, and keep was less than "
        "its length). A torn record is ignored when recovering, never misread. Strings are bytes in "
        "jank: (subs s 0 n) and (count s) count bytes; (spit f text :append true) appends.")},
    'queue': {'file': 'work/queue.jank', 'ask': (
        "Write the file work/queue.jank, a jank namespace `queue` with a bounded queue that "
        "several threads use at once:\n"
        "- (new-queue capacity): an empty queue holding at most `capacity` items (capacity >= 1).\n"
        "- (try-put! q x): adds x at the end and returns true when the queue has room; returns "
        "false, changing nothing, when it is full.\n"
        "- (try-take! q): removes and returns the first item, or returns nil when the queue is "
        "empty. Items are never nil.\n"
        "- (put! q x): adds x at the end, waiting while the queue is full. (take! q): removes and "
        "returns the first item, waiting while the queue is empty.\n"
        "- (size q): how many items it holds.\n"
        "Several threads (futures) call these at once: no item may be lost or given twice, items "
        "come out in the order they went in, and the queue never holds more than `capacity` items. "
        "jank has atoms (swap!, compare-and-set!) and (cpp/usleep microseconds) for waiting; it has "
        "no locks of its own.")},
}

PLAIN_TAIL = "\n\nTest it with the eval tool until you are sure it is right, then say what you did."



def verified_tail(file):
    model = file[:-len('.jank')] + '.lean'
    return ("\n\nMake it verified work: VERIFY.md (in the system text) says what the harness checks, and "
            "VEIL.md how to write a Veil model; examples/parking.jank and examples/parking.lean are a pair "
            "that passes. Put the code, its assertions and the `verification` map in " + file + ", and "
            "the Veil model of the code in " + model + ", and run the verify tool on " + file +
            " until it passes. Your answer is accepted only once it does.")


# nREPL (bencode over a socket).

def benc(value):
    if isinstance(value, dict):
        return b"d" + b"".join(benc(k) + benc(v) for k, v in sorted(value.items())) + b"e"
    if isinstance(value, int):
        return b"i%de" % value
    data = value.encode() if isinstance(value, str) else value
    return b"%d:" % len(data) + data


def bdec(data, at=0):
    c = data[at:at + 1]
    if c == b"i":
        end = data.index(b"e", at)
        return int(data[at + 1:end]), end + 1
    if c in (b"l", b"d"):
        items, at = [], at + 1
        while data[at:at + 1] != b"e":
            item, at = bdec(data, at)
            items.append(item)
        if c == b"l":
            return items, at + 1
        return dict(zip(items[0::2], items[1::2])), at + 1
    colon = data.index(b":", at)
    n = int(data[at:colon])
    if colon + 1 + n > len(data):
        raise ValueError("short")
    return data[colon + 1:colon + 1 + n].decode("utf-8", "replace"), colon + 1 + n


def nrepl_eval(port, code, timeout):
    answer = {"value": None, "ex": None, "err": ""}
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as s:
        s.sendall(benc({"op": "eval", "code": code, "id": "1", "ns": "user"}))
        buffer = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                return answer
            buffer += chunk
            while buffer:
                try:
                    message, used = bdec(buffer)
                except (ValueError, IndexError):
                    break
                buffer = buffer[used:]
                if "value" in message:
                    answer["value"] = message["value"]
                if "err" in message:
                    answer["err"] += message["err"]
                if "ex" in message:
                    answer["ex"] = message["ex"]
                if "done" in (message.get("status") or []):
                    return answer


def ev(port, code, timeout=600):
    a = nrepl_eval(port, '(do (cards.core/evaluations) ' + code + ')', timeout)
    if a["ex"]:
        raise RuntimeError((a["ex"] + " " + a["err"])[:1500])
    return a["value"]


def unstr(v):
    """The text of a printed jank string."""
    try:
        return json.loads(v)
    except (TypeError, ValueError):
        return v


def jstr(s):
    """A jank string literal."""
    return json.dumps(s, ensure_ascii=False)


# The process.

def start(log):
    port_file = HARNESS + '/.nrepl-port'
    if os.path.exists(port_file):
        os.remove(port_file)
    env = dict(os.environ, HARNESS_PROFILES='extras', GC_LARGE_ALLOC_WARN_INTERVAL='1000000')
    for k in ('HARNESS_HIDE', 'HARNESS_WORK'):
        env.pop(k, None)
    env['TMPDIR'] = TMP + '/'
    proc = subprocess.Popen([HARNESS + '/harness.sh', '--hidden', '--announce'], cwd=HARNESS,
                            stdout=open(log, 'w'), stderr=subprocess.STDOUT, start_new_session=True, env=env)
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError('the process ended: ' + open(log, errors='replace').read()[-1500:])
        try:
            port = int(open(port_file).read().strip())
            # Only a port this process listens on: another REPL started in harness/ (a
            # person's) writes the same file, and a run must never go to it.
            listening = subprocess.run(['lsof', '-nP', f'-iTCP:{port}', '-sTCP:LISTEN', '-t'],
                                       capture_output=True, text=True).stdout.split()
            ours = [p for p in listening if os.getpgid(int(p)) == proc.pid]
            if ours and (nrepl_eval(port, '(cards.core/evaluations)', 10)["value"] or '').isdigit():
                return port, proc
        except (OSError, ValueError):
            pass
        time.sleep(1)
    stop(None, proc)
    raise RuntimeError('the REPL did not start')


def stop(port, proc):
    if port:
        try:
            nrepl_eval(port, '(cards.core/stop!)', 10)
        except Exception:
            pass
        time.sleep(2)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            # Gone (macOS answers EPERM for a group of only exited processes).
            proc.poll()
            return
        for _ in range(20):
            if proc.poll() is not None:
                return
            time.sleep(0.5)


def make_home(mode):
    shutil.rmtree(HOME, ignore_errors=True)
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(TMP)
    os.makedirs(HOME + '/work')
    shutil.copy(HARNESS + '/JANK.md', HOME)
    if mode in ('verified', 'team'):
        # The verified mode's guides and examples: what the check asks (VERIFY.md), how to
        # write Veil (VEIL.md, examples/veil/), and a pair that passes.
        for f in ['VERIFY.md', 'VEIL.md']:
            shutil.copy(HARNESS + '/' + f, HOME)
        os.makedirs(HOME + '/examples')
        for f in ['parking.jank', 'parking.lean']:
            shutil.copy(HARNESS + '/examples/' + f, HOME + '/examples/')
        shutil.copytree(HARNESS + '/examples/veil', HOME + '/examples/veil')


CACHE = subprocess.run(['getconf', 'DARWIN_USER_CACHE_DIR'], capture_output=True, text=True).stdout.strip()


def confine_form():
    # Readable besides the system's directories: the run's directory and temporary one, and
    # what compiling and running need (the build's cache and headers, the engine, Lean's
    # toolchain, Veil's build, the system's caches such as Metal's).
    read = [HOME, TMP, CACHE, HARNESS + '/target/debug', HARNESS + '/include', PROJECT + '/inkling/include',
            PROJECT + '/inkling/lib', USER_HOME + '/.cache/jank',
            USER_HOME + '/.elan/toolchains/leanprover--lean4---v4.35.0', PROJECT + '/specs/.lake']
    write = [HOME, TMP, CACHE, OUT, HARNESS + '/target/debug', USER_HOME + '/.cache/jank']
    hide = ['/private/tmp/claude-501']
    v = lambda xs: '[' + ' '.join(jstr(x) for x in xs) + ']'
    return f'(tools/confine! {{:read {v(read)} :write {v(write)} :hide {v(hide)}}})'


def setup(port):
    ev(port, "(require '[inkling.core :as ink] '[harness.core :as h] '[harness.tools :as tools] "
             "'[harness.verify :as verify] '[harness.team :as team])")
    ev(port, '(def m (ink/open "../inkling/models/inkling-2-mini.ink"))', 300)
    ev(port, '(some? (verify/veil-session))', 300)
    ev(port, '(reset! verify/lake-project (str (cpp/harness.real_path @verify/lake-project)))')
    failed = ev(port, f'(str (cpp/harness.change_dir {jstr(HOME)}))')
    if failed != '""':
        raise RuntimeError('moving to the run\'s directory: ' + failed)
    ev(port, f'(reset! tools/hidden-paths [{jstr(PROJECT)}])')
    ev(port, confine_form())
    # What the run must not reach, tried from inside: each must be refused.
    shared_tmp = subprocess.run(['getconf', 'DARWIN_USER_TEMP_DIR'], capture_output=True, text=True).stdout.strip()
    forbidden = [HARNESS + '/README.md', HARNESS + '/src/harness/core.jank', PRIVATE, OUT, USER_HOME,
                 '/private/tmp', shared_tmp, '/Users/Shared', '/private/tmp/claude-501', '/Volumes']
    # A file read (its bytes), a directory listed: `ls` of a file needs only what the sandbox
    # leaves (the file's metadata).
    script = 'pwd; ls; ' + ' '.join(
        f'(if [ -d {p} ]; then ls {p}; else head -c 1 {p}; fi) >/dev/null 2>&1 && echo READABLE {p};' for p in forbidden)
    # Skipped: the system's directories, and the caches readable on purpose (checked to hold
    # nothing of the tasks or the trials: library sources, compiled modules, Veil's build).
    skipped = ['/System', '/usr', '/bin', '/sbin', '/Library', '/opt/homebrew', '/private/etc', '/private/var/db',
               '/dev', '/Applications/Xcode.app', CACHE.rstrip('/'), HARNESS + '/target/debug', HARNESS + '/include',
               PROJECT + '/inkling/include', PROJECT + '/inkling/lib', USER_HOME + '/.cache/jank',
               USER_HOME + '/.elan/toolchains/leanprover--lean4---v4.35.0', PROJECT + '/specs/.lake']
    system = ' -o '.join(f'-path {p}' for p in skipped)
    script += (f' find / \\( {system} \\) -prune -o \\( -name "*.jank" -o -name "*.jank~" -o -name "*.edn" -o -name "*.md" \\) -print 2>/dev/null'
               f' | grep -v "^{HOME}/" | sed "s/^/FOUND /" | head -20')
    probe = unstr(ev(port, '(tools/shell ' + jstr(script) + ' nil)', 600))
    if not probe.startswith(HOME) or 'READABLE' in probe or 'FOUND' in probe:
        raise RuntimeError('the run could reach what it must not:\n' + probe[:1500])
    slurped = ev(port, '(try (subs (slurp ' + jstr(HARNESS + '/src/harness/core.jank') + ') 0 10) '
                       '(catch cpp/std.exception e :refused) (catch :default e :refused))')
    if slurped != ':refused':
        raise RuntimeError('slurp read the harness\'s sources: ' + slurped)
    # The engine still works inside the sandbox.
    said = ev(port, '(let [s (ink/session m 512)] (ink/eval! s "The capital of France is") '
                    '(let [t (ink/top s 1)] (ink/free! s) (pr-str (mapv :piece t))))', 300)
    if not said or 'Paris' not in said:
        raise RuntimeError('the engine inside the sandbox said ' + str(said))
    return probe


def run_form(task, mode, seed):
    t = TASKS[task]
    team = mode == 'team'
    verified = mode == 'verified' or team
    ask = t['ask'] + (verified_tail(t['file']) if verified else PLAIN_TAIL)
    recording = f'{OUT}/{task}-{mode}-{seed}.edn'
    return f'''
(let [file (str {jstr(t['file'])})
      verified {'true' if verified else 'false'}
      live (str {jstr(OUT + '/live.edn')})
      current (atom nil)
      workers (atom nil)
      looped (atom false)
      system (str tools/situation (when verified (str "\\n\\n" (slurp "VERIFY.md"))))
      opts {{;; 128k tokens: about 4.3 GB of the engine's caches (64k each for a team's
             ;; three agents). There is no compaction, and the long thinking of effort 0.99
             ;; fills a context quickly.
                    :context {65536 if team else 131072}
                    :max-steps 80
                    ;; As the publisher evaluates Inkling (temperature 1, top-p off, effort
                    ;; 0.99), with room for the thinking that effort asks for.
                    :effort :max
                    :max-thinking 8192
                    :max-tokens 12288
                    :sampling {{:temperature 1.0 :seed {int(seed)}}}
                    ;; A verified run reminded of VERIFY.md's way of working when it has written
                    ;; nothing after 8, 16 and 24 steps: two kv runs read the guides and every
                    ;; example for 40 steps first, then ran out of steps.
                    :remind (fn [x step]
                              (when (and verified (contains? #{{8 16 24}} step)
                                         (not (some (fn [e] (and (= :call (:role e)) (= "write_file" (:name e)))) (h/entries x))))
                                (str step " steps and no file written yet. As VERIFY.md says: write a first small "
                                     "version of both files now (the code and its model, a few operations), run "
                                     "verify on it, and grow both from there. Look things up in VEIL.md when "
                                     "verify's messages need it.")))
                    :on-entry (fn [_]
                                (when-let [x @current]
                                  (h/save! x live)
                                  ;; A team's workers too, beside it (live-coder.edn, ...).
                                  (when-let [t @workers]
                                    (doseq [k [:coder :modeler]]
                                      (h/save! (get t k) (clojure.string/replace live #"\\.edn$" (str "-" (name k) ".edn")))))
                                  ;; Going round in a loop: the last six results all the
                                  ;; harness's "the same result as before" (a tool that reads)
                                  ;; or "ran again and gave the same result" (one with effects).
                                  ;; Ended, as the step limit would end it later.
                                  (let [rs (take-last 6 (filter (fn [e] (= :result (:role e))) (h/entries x)))]
                                    (when (and (= 6 (count rs))
                                               (every? (fn [e] (or (clojure.string/starts-with? (str (:text e)) "(This call gave exactly this result before")
                                                                   (clojure.string/ends-with? (str (:text e)) "(It ran again and gave the same result as the last time it was called so.)"))) rs))
                                      (reset! looped true)
                                      ;; (Not h/stop!, which waits for the turn: this runs inside it.)
                                      (swap! x assoc :stop true)))))}}
      ;; A team (the coordinator has the task, the verify tool and the gate), or one agent.
      tm (when {'true' if team else 'false'} (team/team m {{:file file :system system :agent opts}}))
      a (if tm
          (:coordinator tm)
          (h/agent m (merge opts {{:tools (vec (concat (tools/defaults) (when verified [(verify/tool)])))
                                  :system system
                                  :obligations (when verified (verify/gate file))}})))
      _ (reset! current a)
      _ (reset! workers tm)
      began (cpp/harness.seconds)
      _ (h/ask! a {jstr(ask)})
      _ (h/answer a)
      seconds (- (cpp/harness.seconds) began)
      _ (h/save! a {jstr(recording)})
      _ (when tm
          (h/save! (:coder tm) {jstr(recording[:-4] + '-coder.edn')})
          (h/save! (:modeler tm) {jstr(recording[:-4] + '-modeler.edn')}))
      check (when verified (verify/attempt (fn [] (verify/check file))))
      st (h/status a)
      r {{:task :{task} :mode :{mode} :seed {int(seed)} :file file
         :verified (when verified (boolean (:ok check)))
         :checks (count (filter (fn [e] (= :check (:role e))) (h/entries a)))
         :tokens (if tm (reduce + (map (fn [k] (:generated (h/status (get tm k)))) [:coordinator :coder :modeler])) (:generated st))
         :seconds seconds :state (:state st) :looped @looped
         :recording {jstr(recording)}}}]
  (if tm (team/close! tm) (h/close! a))
  (pr-str r))'''


def grade(port, task):
    text = open(PRIVATE + '/graders.jank').read()
    loaded = ev(port, '(pr-str (select-keys (cards.repl/evaluate ' + jstr(text) +
                ' "user" "graders.jank" 1 1 false) [:ok :error]))', 600)
    if ':ok true' not in loaded:
        return 'nil', jstr('the graders didn\'t load: ' + loaded)
    g = ev(port, f'(pr-str (let [g (verify/attempt (fn [] (harness-graders/grade :{task} '
                 f'{jstr(TASKS[task]["file"])})))] (if (and (map? g) (:threw g)) (str "the grader threw: " (:threw g)) g)))',
           3600)
    g = unstr(g)  # the pr-str text
    return ('true' if g == 'nil' else 'false'), g


def grade_fresh(task, log):
    """The run's code graded in a process of its own, started for it: in the run's process, the
    agent's earlier evaluations had left jank's compiled code in a state that failed the file
    (a C++ namespace redefined and then not found, "Failed to find symbol"), and two kv runs
    were graded wrong for it. The same sandbox, from the run's directory; no model."""
    port, proc = start(log)
    try:
        ev(port, "(require '[harness.tools :as tools] '[harness.verify :as verify])")
        failed = ev(port, f'(str (cpp/harness.change_dir {jstr(HOME)}))')
        if failed != '""':
            raise RuntimeError('moving to the run\'s directory: ' + failed)
        ev(port, f'(reset! tools/hidden-paths [{jstr(PROJECT)}])')
        ev(port, confine_form())
        return grade(port, task)
    finally:
        stop(port, proc)


def main():
    # One driver at a time: two would share the run's directory. (Stop one with SIGTERM: a
    # background job ignores SIGINT.)
    import fcntl
    os.makedirs(OUT, exist_ok=True)
    lock = open(OUT + '/driver.lock', 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit('another driver is running')
    tasks = sys.argv[1].split(',')
    seeds = [int(x) for x in sys.argv[2].split(',')]
    modes = sys.argv[3].split(',')
    os.makedirs(OUT, exist_ok=True)
    results_path = OUT + '/results.edn'
    results = []
    if os.path.exists(results_path):
        old = open(results_path).read().strip()
        if old not in ('', '[]'):
            results = [l for l in old[1:-1].strip().split('\n') if l.strip()]
    log = OUT + '/process.log'
    for task in tasks:
        for seed in seeds:
            for mode in modes:
                if any(f'{task}-{mode}-{seed}.edn"' in r for r in results):
                    print(f'SKIP {task} {mode} seed {seed}: already in results.edn', flush=True)
                    continue
                # Between runs, while OUT/pause exists, nothing runs: the GPU and the memory are
                # free for something else (a second model in memory slows both to a crawl).
                if os.path.exists(OUT + '/pause'):
                    print(f'PAUSED before {task} {mode} seed {seed}', flush=True)
                    while os.path.exists(OUT + '/pause'):
                        time.sleep(5)
                    print('RESUMED', flush=True)
                t0 = time.time()
                port = proc = None
                try:
                    make_home(mode)
                    port, proc = start(log)
                    setup(port)
                    print(f'START {task} {mode} seed {seed}: a new process, its directory has '
                          f'{sorted(os.listdir(HOME))}, the sandbox refuses the harness, the trials and the results',
                          flush=True)
                    r = unstr(ev(port, run_form(task, mode, seed), 3 * 3600))
                    # The code as the run left it, kept beside its conversation: a run graded
                    # wrong for a jank error ("Failed to find symbol") couldn't be checked again
                    # once the next run had made its directory anew.
                    written = HOME + '/' + TASKS[task]['file']
                    if os.path.exists(written):
                        shutil.copy(written, f'{OUT}/{task}-{mode}-{seed}.jank')
                    # The run's process ended before grading, which has a process of its own.
                    stop(port, proc)
                    port = proc = None
                    right, g = grade_fresh(task, log.replace('.log', '-grade.log'))
                    r = r[:-1] + f' :right {right} :grade {g}}}'
                    results.append(r)
                    with open(results_path, 'w') as f:
                        f.write('[' + '\n'.join(results) + ']\n')
                    print(f'RUN {task} {mode} seed {seed} ({time.time() - t0:.0f} s): {r}', flush=True)
                except Exception as e:
                    print(f'RUN {task} {mode} seed {seed} FAILED after {time.time() - t0:.0f} s: {e}', flush=True)
                    if time.time() - t0 < 120:
                        # Failed before the model could do much: the harness's fault, not the run's.
                        print('STOPPING: a run failed at its start', flush=True)
                        return
                finally:
                    if proc:
                        stop(port, proc)
    print('ALL DONE', flush=True)


if __name__ == '__main__':
    main()
