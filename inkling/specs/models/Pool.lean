module
public import Veil

/-!
# The thread pool

`native/internal.hpp` (`struct pool`) and `native/model.cpp` (`pool::run`,
`pool::work`, `pool::worker_loop`, `pool::~pool`): the CPU path's fork-join
workers. `run(n, grain, fn)` calls `fn` on chunks of `[0, n)`, on the workers
and on the calling thread, and returns when all of them ran.

- A job (`next`, `remaining`, the task) lives on `run`'s stack. `run` stores
  its address in `current`, adds one to `generation` under the mutex, notifies
  the workers, works on the job itself, waits for `remaining == 0`, stores
  null in `current`, and waits for `active == 0`.
- A worker remembers the generation it saw (`seen`, at first the generation
  when the pool made its thread). It spins, then sleeps on the condition
  variable, until `generation != seen`; then it returns if `stopping`, else
  adds one to `active`, loads `current`, works on that job if there is one,
  and subtracts one from `active`.
- `work` takes chunks with `next.fetch_add(chunk)` until `next >= total`,
  runs the task on each, and subtracts each from `remaining`.
- The destructor sets `stopping` and adds one to `generation` under the
  mutex, notifies, and joins the workers.

Every access to a shared variable is a step. The mutex's critical sections
(the generation's increment; a worker's check of the predicate and going to
sleep) are one step each. A job is identified by the number of its `run`;
`liveJob` is the job in scope, 0 between runs.

`fixed` says which changes the pool has. The engine has `seq_cst` and
`seen_at_construction` (both made after this model found what they fix);
`fun _ => false` is the pool before them:

- `seq_cst`: `run`'s `current.store(nullptr)` and `active.load()`, and the
  workers' `active.fetch_add`, `current.load()` and `active.fetch_sub`, are
  sequentially consistent. Before, they were release and acquire.
- `seen_at_construction`: a worker's first `seen` is the generation when the
  pool made its thread (a lambda capture in `pool::pool`). Before, it was the
  thread's first statement, `seen = generation.load()`: a thread that started
  after the destructor's increment never saw the generation change, and slept
  forever while the destructor waited to join it.
- `stop_in_wait`: another way to fix that, not the engine's: a worker also
  leaves its wait when `stopping` is set (the loop's condition and the wait's
  predicate are `generation == seen && !stopping`).

`weak` is what `memory_order_release` and `memory_order_acquire` allow: `run`'s
`current.store(nullptr)` can become visible to the workers after `run` has
read `active` (store buffering). The library built for this machine had
`stlur` for the store and `ldapur` for the load, a load the processor may
order before an earlier store-release; with `memory_order_seq_cst` the load is
`ldar`, which it may not (and on x86 the store is followed by a barrier). With
`seq_cst`, `weak` changes nothing.
`spuriousWakeups` lets a sleeping worker wake without a notification; without
them, a state where the destructor waits for a worker that sleeps forever has
no step left, which is how the conformance namespace finds it.
-/

veil module Pool

type worker
type item
enum mpc_t = { m_idle, m_store, m_gen, m_notify, m_fetch, m_task, m_sub, m_wait_remaining,
               m_clear, m_wait_active, m_return, m_notify_stop, m_join, m_done }
enum wpc_t = { w_new, w_spin, w_lock, w_sleep, w_woken, w_seen, w_stop_check, w_inc, w_load,
               w_fetch, w_task, w_sub, w_dec, w_exited }
enum fix_t = { stop_in_wait, seq_cst, seen_at_construction }

/- The job: `total` indices in chunks of `chunk`; an item's index. -/
immutable individual total : Nat
immutable individual chunk : Nat
immutable function ord : item → Nat
/- How many times the caller calls `run` before destroying the pool. -/
immutable individual maxRuns : Nat
immutable individual weak : Bool
immutable individual spuriousWakeups : Bool
immutable relation fixed : fix_t → Bool

/- The pool's shared state. -/
individual generation : Nat
individual current : Nat
individual active : Nat
individual stopping : Bool
/- The job on `run`'s stack. -/
individual liveJob : Nat
individual jobNext : Nat
individual jobRemaining : Nat
/- The caller. -/
individual mpc : mpc_t
individual runs : Nat
individual mBegin : Nat
/- Its store of null to `current`, not yet visible to the workers. -/
individual buffered : Bool
/- The workers. -/
function wpc : worker → wpc_t
function seen : worker → Nat
function jptr : worker → Nat
function wBegin : worker → Nat
/- Ghost: how many times the current job's task ran on each item, and whether
a worker touched a job that was out of scope. -/
function count : item → Nat
individual useAfterScope : Bool

#gen_state

after_init {
  generation := 0
  current := 0
  active := 0
  stopping := false
  liveJob := 0
  jobNext := 0
  jobRemaining := 0
  mpc := m_idle
  runs := 0
  mBegin := 0
  buffered := false
  wpc W := w_new
  seen W := 0
  jptr W := 0
  wBegin W := 0
  count I := 0
  useAfterScope := false
}

/-! ## The caller: `run` -/

/- `job j; ... j.remaining.store(n)`. -/
action runBegin {
  require mpc = m_idle ∧ runs < maxRuns ∧ ¬ buffered
  runs := runs + 1
  liveJob := runs + 1
  jobNext := 0
  jobRemaining := total
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
  wpc W := if wpc W = w_sleep then w_woken else wpc W
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

/- `j.remaining.fetch_sub(end - begin)`. -/
action runSub {
  require mpc = m_sub
  jobRemaining := jobRemaining - (if total ≤ mBegin + chunk then total - mBegin else chunk)
  mpc := m_fetch
}

/- `while(j.remaining.load() > 0)`. -/
action runAllDone {
  require mpc = m_wait_remaining ∧ jobRemaining = 0
  mpc := m_clear
}

/- `current.store(nullptr)`. -/
action runClear {
  require mpc = m_clear
  if weak ∧ ¬ fixed seq_cst then
    buffered := true
  else
    current := 0
  mpc := m_wait_active
}

/- The store buffer drains. -/
action flush {
  require buffered
  current := 0
  buffered := false
}

/- `while(active.load() > 0)`. -/
action runNoneActive {
  require mpc = m_wait_active ∧ active = 0
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
  require mpc = m_idle ∧ ¬ buffered
  stopping := true
  generation := generation + 1
  mpc := m_notify_stop
}

action stopNotify {
  require mpc = m_notify_stop
  wpc W := if wpc W = w_sleep then w_woken else wpc W
  mpc := m_join
}

/- `t.join()` for every worker. -/
action join {
  require mpc = m_join ∧ ∀ W, wpc W = w_exited
  mpc := m_done
}

/-! ## A worker: `worker_loop` -/

/- The thread starts, with `seen` the generation when the pool made it (0:
the pool is made in the initial state), or, before that change, with
`seen = generation.load()`. -/
action workerStart (w : worker) {
  require wpc w = w_new
  if ¬ fixed seen_at_construction then
    seen w := generation
  wpc w := w_spin
}

/- `while(generation.load() == seen)`: it changed. -/
action spinChanged (w : worker) {
  require wpc w = w_spin ∧ (generation ≠ seen w ∨ (fixed stop_in_wait ∧ stopping))
  wpc w := w_seen
}

/- It didn't, and the worker has spun enough: it goes for the mutex. -/
action spinToLock (w : worker) {
  require wpc w = w_spin ∧ generation = seen w ∧ ¬ (fixed stop_in_wait ∧ stopping)
  wpc w := w_lock
}

/- With the mutex: `wake.wait(lock, pred)` returns at once if the predicate
holds, else the worker sleeps (and releases the mutex). -/
action lockCheck (w : worker) {
  require wpc w = w_lock
  if generation ≠ seen w ∨ (fixed stop_in_wait ∧ stopping) then
    wpc w := w_seen
  else
    wpc w := w_sleep
}

/- Notified: it takes the mutex and checks the predicate again. -/
action wokenCheck (w : worker) {
  require wpc w = w_woken
  if generation ≠ seen w ∨ (fixed stop_in_wait ∧ stopping) then
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

/- `if(stopping) return`. -/
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
  active := active + 1
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
    jobRemaining := jobRemaining - (if total ≤ wBegin w + chunk then total - wBegin w else chunk)
    wpc w := w_fetch
}

/- `active.fetch_sub(1)`. -/
action retire (w : worker) {
  require wpc w = w_dec
  active := active - 1
  wpc w := w_spin
}

/-! ## Properties -/

/- No worker reads or writes a job after its `run` returned. -/
safety [no_use_after_scope] ¬ useAfterScope
/- The task runs at most once on each index, -/
safety [at_most_once] count I ≤ 1
/- and `run` returns only when it ran on every index. -/
safety [all_ran_at_return] mpc = m_return → count I = 1

#gen_spec

-- For the checks driven from jank (veil/model-check, veil/system).
#gen_executable

/-! ## Model checking

Two workers, a job of three indices in chunks of one or two, one or two runs
and then the destructor (which can also come before any run).

Whether every run ends (no worker left asleep when the destructor joins) is
not a safety property of a state: the conformance namespace asks for the
reachable states without a successor, and checks that they are all `m_done`
(`inkling-specs.pool/deadlocks`). -/

-- The engine's pool: sequentially consistent handshake, `seen` from construction.
#model_check { worker := Fin 2, item := Fin 3 }
  { total := 3, chunk := 1, ord := fun i => i.val, maxRuns := 2, weak := true,
    spuriousWakeups := true, fixed := fun f => f = seq_cst ∨ f = seen_at_construction }
#model_check { worker := Fin 2, item := Fin 3 }
  { total := 3, chunk := 2, ord := fun i => i.val, maxRuns := 2, weak := true,
    spuriousWakeups := true, fixed := fun f => f = seq_cst ∨ f = seen_at_construction }

-- The pool before those changes, with what release and acquire allow: a
-- worker works on a job whose `run` has returned.
set_option veil.violationIsError false in
#model_check { worker := Fin 2, item := Fin 2 }
  { total := 2, chunk := 1, ord := fun i => i.val, maxRuns := 2, weak := true,
    spuriousWakeups := true, fixed := fun _ => false }

end Pool
