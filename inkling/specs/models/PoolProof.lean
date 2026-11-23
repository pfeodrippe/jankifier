module
public import Veil

/-!
# The thread pool, proved

The engine's pool as it is now (`native/internal.hpp`, `native/model.cpp`),
step by step as `Pool.lean` models it, with its properties proved for any
number of workers, indices, chunk size and runs (`#check_invariants`).
`Pool.lean` keeps the model checks, including the earlier versions it found
wrong; this file has only the current one: the hand-off's four accesses are
sequentially consistent (so `current.store(nullptr)` is visible to a worker
that reads `current` after `run` read `active`), and a worker's first `seen`
is the generation when the pool made its thread.

Two counters of the C++ are sets here, because the proof needs their
relation with what the threads are doing and the solver can't count:

- `active` is the number of workers that announced themselves and haven't
  retired (each worker adds 1 and later subtracts 1, so the counter is the
  size of that set at every moment); here it is the set `announced`, and
  `run`'s `while(active.load() > 0)` waits until the set is empty;
- the job's `remaining` is the number of indices whose chunk hasn't been
  subtracted yet (every chunk is subtracted once, after its task); here it is
  the set of indices not yet `finished`, and `run`'s
  `while(j.remaining.load() > 0)` waits until every index is finished.

The model checks of `Pool.lean` cover the counters themselves, for small
instances.

Properties: no worker touches a job after its `run` returned; the task runs
at most once on each index, and on every index before `run` returns; and no
reachable state is stuck (every state but the end has a step: the destructor
never waits forever for a worker). The last one is about one state at a time:
it says nothing of a run that goes on forever (that would need fairness).
-/

set_option veil.smt.trust false

veil module PoolProof

type worker
type item
enum mpc_t = { m_idle, m_store, m_gen, m_notify, m_fetch, m_task, m_sub, m_wait_remaining,
               m_clear, m_wait_active, m_return, m_notify_stop, m_join, m_done }
enum wpc_t = { w_new, w_spin, w_lock, w_sleep, w_woken, w_seen, w_stop_check, w_inc, w_load,
               w_fetch, w_task, w_sub, w_dec, w_exited }

immutable individual total : Nat
immutable individual chunk : Nat
immutable function ord : item → Nat
immutable individual maxRuns : Nat
immutable individual spuriousWakeups : Bool

individual generation : Nat
individual current : Nat
relation announced : worker → Bool
individual stopping : Bool
individual liveJob : Nat
individual jobNext : Nat
relation finished : item → Bool
individual mpc : mpc_t
individual runs : Nat
individual mBegin : Nat
function wpc : worker → wpc_t
function seen : worker → Nat
function jptr : worker → Nat
function wBegin : worker → Nat
function count : item → Nat
individual useAfterScope : Bool

#gen_state

/- The indices are 0 .. total - 1, each once; chunks have at least one index. -/
assumption [items] ord I < total
assumption [item_ords] ord I = ord J → I = J
assumption [chunk_pos] 0 < chunk

after_init {
  generation := 0
  current := 0
  announced U := false
  stopping := false
  liveJob := 0
  jobNext := 0
  finished I := false
  mpc := m_idle
  runs := 0
  mBegin := 0
  wpc U := w_new
  seen U := 0
  jptr U := 0
  wBegin U := 0
  count I := 0
  useAfterScope := false
}

/-! ## The caller: `run` -/

/- `job j; ... j.remaining.store(n)`: a job, numbered by its run. -/
action runBegin {
  require mpc = m_idle ∧ runs < maxRuns
  liveJob := runs + 1
  runs := runs + 1
  jobNext := 0
  finished I := false
  count I := 0
  mpc := m_store
}

/- `current.store(&j)`. -/
action runStore {
  require mpc = m_store
  current := liveJob
  mpc := m_gen
}

/- `{ lock; generation.fetch_add(1); }`. -/
action runGeneration {
  require mpc = m_gen
  generation := generation + 1
  mpc := m_notify
}

/- `wake.notify_all()`. -/
action runNotify {
  require mpc = m_notify
  wpc U := if wpc U = w_sleep then w_woken else wpc U
  mpc := m_fetch
}

/- `work(j)`: `begin = j.next.fetch_add(j.chunk)`. -/
action runFetch {
  require mpc = m_fetch
  let b := jobNext
  jobNext := b + chunk
  if b ≥ total then
    mpc := m_wait_remaining
  else
    mBegin := b
    mpc := m_task
}

/- `(*j.task)(begin, end)`. -/
action runTask {
  require mpc = m_task
  count I := if mBegin ≤ ord I ∧ ord I < mBegin + chunk then count I + 1 else count I
  mpc := m_sub
}

/- `j.remaining.fetch_sub(end - begin)`: the chunk's indices are finished. -/
action runSub {
  require mpc = m_sub
  finished I := finished I ∨ (mBegin ≤ ord I ∧ ord I < mBegin + chunk)
  mpc := m_fetch
}

/- `while(j.remaining.load() > 0)`. -/
action runAllDone {
  require mpc = m_wait_remaining ∧ ∀ I, finished I
  mpc := m_clear
}

/- `current.store(nullptr)` (sequentially consistent). -/
action runClear {
  require mpc = m_clear
  current := 0
  mpc := m_wait_active
}

/- `while(active.load() > 0)`. -/
action runNoneActive {
  require mpc = m_wait_active ∧ ∀ U, ¬ announced U
  mpc := m_return
}

/- `run` returns: the job goes out of scope. -/
action runReturn {
  require mpc = m_return
  liveJob := 0
  mpc := m_idle
}

/-! ## The caller: `~pool` -/

/- `{ lock; stopping = true; generation.fetch_add(1); }`. -/
action stop {
  require mpc = m_idle
  stopping := true
  generation := generation + 1
  mpc := m_notify_stop
}

action stopNotify {
  require mpc = m_notify_stop
  wpc U := if wpc U = w_sleep then w_woken else wpc U
  mpc := m_join
}

/- `t.join()` for every worker. -/
action join {
  require mpc = m_join ∧ ∀ U, wpc U = w_exited
  mpc := m_done
}

/-! ## A worker: `worker_loop(seen)` -/

/- The thread starts, with `seen` the generation when the pool made it (0:
the pool is made in the initial state). -/
action workerStart (w : worker) {
  require wpc w = w_new
  wpc w := w_spin
}

/- `while(generation.load() == seen)`: it changed. -/
action spinChanged (w : worker) {
  require wpc w = w_spin ∧ generation ≠ seen w
  wpc w := w_seen
}

/- It didn't, and the worker has spun enough: it goes for the mutex. -/
action spinToLock (w : worker) {
  require wpc w = w_spin ∧ generation = seen w
  wpc w := w_lock
}

/- With the mutex: `wake.wait(lock, pred)` returns at once if the predicate
holds, else the worker sleeps (and releases the mutex). -/
action lockCheck (w : worker) {
  require wpc w = w_lock
  if generation ≠ seen w then
    wpc w := w_seen
  else
    wpc w := w_sleep
}

/- Notified: it takes the mutex and checks the predicate again. -/
action wokenCheck (w : worker) {
  require wpc w = w_woken
  if generation ≠ seen w then
    wpc w := w_seen
  else
    wpc w := w_sleep
}

/- A spurious wakeup. -/
action spurious (w : worker) {
  require spuriousWakeups ∧ wpc w = w_sleep
  wpc w := w_woken
}

/- `seen = generation.load()`. -/
action noteGeneration (w : worker) {
  require wpc w = w_seen
  seen w := generation
  wpc w := w_stop_check
}

/- `if(stopping.load()) return`. -/
action stopCheck (w : worker) {
  require wpc w = w_stop_check
  if stopping then
    wpc w := w_exited
  else
    wpc w := w_inc
}

/- `active.fetch_add(1)`. -/
action announce (w : worker) {
  require wpc w = w_inc
  announced w := true
  wpc w := w_load
}

/- `j = current.load()`. -/
action loadCurrent (w : worker) {
  require wpc w = w_load
  jptr w := current
  if current = 0 then
    wpc w := w_dec
  else
    wpc w := w_fetch
}

/- `work(*j)`: `begin = j.next.fetch_add(j.chunk)`. -/
action workerFetch (w : worker) {
  require wpc w = w_fetch
  if jptr w ≠ liveJob then
    useAfterScope := true
    wpc w := w_dec
  else
    let b := jobNext
    jobNext := b + chunk
    if b ≥ total then
      wpc w := w_dec
    else
      wBegin w := b
      wpc w := w_task
}

action workerTask (w : worker) {
  require wpc w = w_task
  if jptr w ≠ liveJob then
    useAfterScope := true
  else
    count I := if wBegin w ≤ ord I ∧ ord I < wBegin w + chunk then count I + 1 else count I
  wpc w := w_sub
}

action workerSub (w : worker) {
  require wpc w = w_sub
  if jptr w ≠ liveJob then
    useAfterScope := true
    wpc w := w_dec
  else
    finished I := finished I ∨ (wBegin w ≤ ord I ∧ ord I < wBegin w + chunk)
    wpc w := w_fetch
}

/- `active.fetch_sub(1)`. -/
action retire (w : worker) {
  require wpc w = w_dec
  announced w := false
  wpc w := w_spin
}

/-! ## Properties -/

/- No worker reads or writes a job after its `run` returned. -/
safety [no_use_after_scope] ¬ useAfterScope
/- The task runs at most once on each index, -/
safety [at_most_once] count I ≤ 1
/- and `run` returns only when it ran on every index. -/
safety [all_ran_at_return] mpc = m_return → count I = 1
/- No state is stuck: the end, or the caller can take a step, or a worker
can (a worker is blocked only asleep or after it returned). -/
safety [no_stuck]
  mpc = m_done
  ∨ (mpc ≠ m_wait_remaining ∧ mpc ≠ m_wait_active ∧ mpc ≠ m_join)
  ∨ (mpc = m_wait_remaining ∧ ∀ I, finished I)
  ∨ (mpc = m_wait_active ∧ ∀ U, ¬ announced U)
  ∨ (mpc = m_join ∧ ∀ U, wpc U = w_exited)
  ∨ (∃ w, wpc w ≠ w_sleep ∧ wpc w ≠ w_exited)

/-! ## Auxiliary invariants -/

/- The caller's phases: where the job pointer and the job are. -/
invariant [no_job] (mpc = m_idle ∨ mpc = m_notify_stop ∨ mpc = m_join ∨ mpc = m_done) → liveJob = 0 ∧ current = 0
invariant [job_stored]
  (mpc = m_gen ∨ mpc = m_notify ∨ mpc = m_fetch ∨ mpc = m_task ∨ mpc = m_sub ∨ mpc = m_wait_remaining ∨ mpc = m_clear)
    → current = liveJob ∧ 0 < liveJob
invariant [job_unstored] (mpc = m_store ∨ mpc = m_wait_active ∨ mpc = m_return) → current = 0 ∧ 0 < liveJob
/- active is the set of workers between announce and retire. -/
invariant [announced_states] announced U ↔
  (wpc U = w_load ∨ wpc U = w_fetch ∨ wpc U = w_task ∨ wpc U = w_sub ∨ wpc U = w_dec)
/- A worker holding a job pointer holds the live job, while run hasn't
returned. -/
invariant [holders]
  (wpc U = w_fetch ∨ wpc U = w_task ∨ wpc U = w_sub) →
    jptr U = liveJob ∧ 0 < liveJob ∧ mpc ≠ m_store ∧ mpc ≠ m_return
/- Claims: a thread with a chunk to run or subtract. Claims are below the
claim counter and a chunk apart from each other. -/
invariant [caller_claim] (mpc = m_task ∨ mpc = m_sub) → mBegin < total ∧ mBegin + chunk ≤ jobNext
invariant [worker_claim] (wpc U = w_task ∨ wpc U = w_sub) → wBegin U < total ∧ wBegin U + chunk ≤ jobNext
invariant [claims_apart_cw] (mpc = m_task ∨ mpc = m_sub) → (wpc U = w_task ∨ wpc U = w_sub) →
  mBegin + chunk ≤ wBegin U ∨ wBegin U + chunk ≤ mBegin
invariant [claims_apart_ww] (wpc U = w_task ∨ wpc U = w_sub) → (wpc Y = w_task ∨ wpc Y = w_sub) → U ≠ Y →
  wBegin U + chunk ≤ wBegin Y ∨ wBegin Y + chunk ≤ wBegin U
/- What has run: an index is run once at most, only once claimed; a claimed
index not run yet is in a chunk about to run; a chunk about to run has none
of its indices run, a chunk being subtracted has them all. -/
invariant [count_bound] count I ≤ 1
invariant [count_claimed] count I = 1 → ord I < jobNext
invariant [unrun_pending] count I = 0 → ord I < jobNext →
  (mpc = m_task ∧ mBegin ≤ ord I ∧ ord I < mBegin + chunk)
  ∨ (∃ w, wpc w = w_task ∧ wBegin w ≤ ord I ∧ ord I < wBegin w + chunk)
invariant [caller_task_fresh] mpc = m_task → mBegin ≤ ord I → ord I < mBegin + chunk → count I = 0
invariant [worker_task_fresh] wpc U = w_task → wBegin U ≤ ord I → ord I < wBegin U + chunk → count I = 0
invariant [caller_sub_done] mpc = m_sub → mBegin ≤ ord I → ord I < mBegin + chunk → count I = 1
invariant [worker_sub_done] wpc U = w_sub → wBegin U ≤ ord I → ord I < wBegin U + chunk → count I = 1
/- Finished indices were run; an index run but not finished is in a chunk
being subtracted. -/
invariant [finished_run] finished I → count I = 1
invariant [run_unfinished] count I = 1 → ¬ finished I →
  (mpc = m_sub ∧ mBegin ≤ ord I ∧ ord I < mBegin + chunk)
  ∨ (∃ w, wpc w = w_sub ∧ wBegin w ≤ ord I ∧ ord I < wBegin w + chunk)
/- After the caller's last fetch everything is claimed; once it stopped
waiting, everything is finished. -/
invariant [all_claimed] (mpc = m_wait_remaining ∨ mpc = m_clear ∨ mpc = m_wait_active ∨ mpc = m_return) → total ≤ jobNext
invariant [all_finished] (mpc = m_clear ∨ mpc = m_wait_active ∨ mpc = m_return) → finished I
invariant [caller_not_working] (mpc = m_wait_remaining ∨ mpc = m_clear ∨ mpc = m_wait_active ∨ mpc = m_return)
  → mpc ≠ m_task ∧ mpc ≠ m_sub
/- Between runs and after the destructor, no worker works on a job. -/
invariant [idle_no_claims] (mpc = m_idle ∨ mpc = m_store ∨ mpc = m_notify_stop ∨ mpc = m_join ∨ mpc = m_done) →
  wpc U ≠ w_fetch ∧ wpc U ≠ w_task ∧ wpc U ≠ w_sub
/- Generations: a worker's `seen` is never ahead; once stopping, only a
worker that noted the last generation (and is about to return) has seen it. -/
invariant [seen_le] seen U ≤ generation
invariant [stopping_phase] stopping ↔ (mpc = m_notify_stop ∨ mpc = m_join ∨ mpc = m_done)
invariant [stop_seen] stopping → seen U = generation → (wpc U = w_stop_check ∨ wpc U = w_exited)
invariant [stopped_generation] stopping → 0 < generation
/- Once the destructor notified, no worker sleeps. -/
invariant [no_sleep_after_notify] (mpc = m_join ∨ mpc = m_done) → wpc U ≠ w_sleep
invariant [exited_stopping] wpc U = w_exited → stopping

#gen_spec

#check_invariants

end PoolProof
