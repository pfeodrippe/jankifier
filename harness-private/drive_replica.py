"""Runs the replica trials: a team of three agents (harness.replica) translates a piece of
Elle into Lean and writes a specification apart, then compares them (elle-cp/ELLE.md).

    python3 -u drive_replica.py elle-cp 1,2,3

Each run is a new sandboxed process (drive.py's start, setup and sandbox), its directory
holding only what the agents may read: elle/closed_predicate.clj, the Lean project with the
rest of Elle already translated (Elle as written, without the known fixes), and ELLE.md. The
grade, outside the sandbox: the team's translation compiled against the human replica's base
and compared with the human replica on random histories (elle-cp/grader). The specification
and the report are read by hand.
"""
import os
import shutil
import subprocess
import sys
import time

import drive

HERE = os.path.dirname(os.path.abspath(__file__))
ELLE = HERE + '/elle-cp'
LAKE = os.path.expanduser('~/.elan/toolchains/leanprover--lean4---v4.35.0/bin/lake')

TASKS = {
    'elle-cp': {
        'translation': 'lean/ElleCP/ClosedPredicate.lean',
        'spec': 'lean/ElleCP/Spec.lean',
        'report': 'REPORT.md',
        'dir': 'lean',
        'code': 'elle/closed_predicate.clj',
        'spec-sources': 'elle/DOCSTRING.md',
        'ask': ("ELLE.md describes the work: Elle's closed-predicate checker "
                "(elle/closed_predicate.clj) translated into Lean as it is written, a specification "
                "written apart from the definitions, the two compared on many small histories, and "
                "what they disagree on written in REPORT.md. Do it."),
    },
}


def make_home(task):
    drive.make_home('plain')
    shutil.copytree(ELLE + '/stage/elle', drive.HOME + '/elle')
    shutil.copytree(ELLE + '/stage/lean', drive.HOME + '/lean', ignore=shutil.ignore_patterns('.lake'))
    shutil.copy(ELLE + '/ELLE.md', drive.HOME)


def run_form(task, seed):
    t = TASKS[task]
    rec = f'{drive.OUT}/{task}-team-{seed}.edn'
    live = drive.OUT + '/live.edn'
    files = '{' + ' '.join(f':{k} {drive.jstr(t[k])}' for k in ['translation', 'spec', 'report', 'dir', 'code', 'spec-sources']) + '}'
    return f'''
(let [live (str {drive.jstr(live)})
      current (atom nil)
      workers (atom nil)
      system (str tools/situation "\\n\\n" (slurp "ELLE.md"))
      opts {{:context 65536
            :max-steps 160
            :effort :max
            :max-thinking 8192
            :max-tokens 12288
            :sampling {{:temperature 1.0 :seed {int(seed)}}}
            :on-entry (fn [_]
                        (when-let [x @current]
                          (h/save! x live)
                          (when-let [t @workers]
                            (doseq [k [:translator :specifier]]
                              (h/save! (get t k) (clojure.string/replace live #"\\.edn$" (str "-" (name k) ".edn")))))))}}
      tm (replica/team m {{:system system :agent opts :worker-context 98304 :files {files}}})
      a (:coordinator tm)
      _ (reset! current a)
      _ (reset! workers tm)
      began (cpp/harness.seconds)
      _ (h/ask! a {drive.jstr(t['ask'])})
      _ (h/answer a)
      seconds (- (cpp/harness.seconds) began)
      _ (h/save! a {drive.jstr(rec)})
      _ (h/save! (:translator tm) {drive.jstr(rec[:-4] + '-translator.edn')})
      _ (h/save! (:specifier tm) {drive.jstr(rec[:-4] + '-specifier.edn')})
      st (h/status a)
      r {{:task :{task} :seed {int(seed)}
         :checks (count (filter (fn [e] (= :check (:role e))) (h/entries a)))
         :tokens (reduce + (map (fn [k] (:generated (h/status (get tm k)))) [:coordinator :translator :specifier]))
         :seconds seconds :state (:state st)
         :recording {drive.jstr(rec)}}}]
  (replica/close! tm)
  (pr-str r))'''


def keep(task, seed):
    """The team's files, kept beside its conversation for reading by hand."""
    dest = f'{drive.OUT}/{task}-team-{seed}'
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    for p in ['lean/ElleCP', 'REPORT.md']:
        src = drive.HOME + '/' + p
        if os.path.isdir(src):
            shutil.copytree(src, dest + '/' + os.path.basename(p))
        elif os.path.exists(src):
            shutil.copy(src, dest)
    return dest


def grade(task, seed):
    """The translation compiled against the human replica's base and compared with the human
    replica (elle-cp/grader), outside the sandbox: (agreed, disagreed, text)."""
    t = TASKS[task]
    src = drive.HOME + '/' + t['translation']
    g = ELLE + '/grader'
    if not os.path.exists(src):
        return None, None, 'no translation'
    shutil.copy(src, g + '/ElleCP/ClosedPredicate.lean')
    b = subprocess.run([LAKE, 'build'], cwd=g, capture_output=True, text=True, timeout=1800)
    if b.returncode != 0:
        return None, None, 'the translation does not build against the original base:\n' + (b.stdout + b.stderr)[-3000:]
    r = subprocess.run([LAKE, 'build', 'grade'], cwd=g, capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        return None, None, 'the grade does not build:\n' + (r.stdout + r.stderr)[-3000:]
    # Its own time limit: a translation that never ends would hold the grade.
    try:
        r = subprocess.run([g + '/.lake/build/bin/grade', '2000'], cwd=g, capture_output=True, text=True, timeout=3600)
    except subprocess.TimeoutExpired:
        return None, None, 'the grade did not end in an hour (a translation that loops?)'
    # The grader's slot back to the placeholder, for the next run.
    shutil.copy(ELLE + '/stage/lean/ElleCP/ClosedPredicate.lean', g + '/ElleCP/ClosedPredicate.lean')
    return None, None, (r.stdout + r.stderr)[-6000:]


def main():
    task = sys.argv[1]
    seeds = [int(x) for x in sys.argv[2].split(',')]
    os.environ['LAKE'] = LAKE
    for seed in seeds:
        if os.path.exists(f'{drive.OUT}/{task}-team-{seed}.edn'):
            print(f'SKIP {task} seed {seed}: already run', flush=True)
            continue
        if os.path.exists(drive.OUT + '/pause'):
            print(f'PAUSED before {task} seed {seed}', flush=True)
            while os.path.exists(drive.OUT + '/pause'):
                time.sleep(5)
        t0 = time.time()
        port = proc = None
        try:
            make_home(task)
            port, proc = drive.start(drive.OUT + '/process.log')
            # Before setup, whose sandbox refuses the harness's own sources from then on; its own
            # evaluation (a require and its alias in one form fail in jank).
            drive.ev(port, "(require '[harness.replica :as replica])", 300)
            drive.setup(port)
            print(f'START {task} seed {seed}: its directory has {sorted(os.listdir(drive.HOME))}', flush=True)
            answer = drive.ev(port, run_form(task, seed), 12 * 3600)
            if answer is None:
                # The process ended during the run (something the agents ran crashed it): its
                # conversations so far are in the live files; what they wrote is kept and graded.
                for k in ['', '-translator', '-specifier']:
                    src = f'{drive.OUT}/live{k}.edn'
                    if os.path.exists(src):
                        shutil.copy(src, f'{drive.OUT}/{task}-team-{seed}{k}.edn')
                answer = drive.jstr(f'{{:task :{task} :seed {seed} :state :crashed}}')
            r = drive.unstr(answer)
            drive.stop(port, proc)
            port = proc = None
            kept = keep(task, seed)
            _, _, g = grade(task, seed)
            with open(kept + '/GRADE.txt', 'w') as f:
                f.write(g)
            print(f'RUN {task} seed {seed} ({time.time() - t0:.0f} s): {r}\nGRADE (kept in {kept}):\n{g[-1500:]}', flush=True)
        except Exception as e:
            print(f'RUN {task} seed {seed} FAILED after {time.time() - t0:.0f} s: {e}', flush=True)
            if time.time() - t0 < 120:
                print('STOPPING: a run failed at its start', flush=True)
                return
        finally:
            if proc:
                drive.stop(port, proc)
    print('ALL DONE', flush=True)


if __name__ == '__main__':
    main()
