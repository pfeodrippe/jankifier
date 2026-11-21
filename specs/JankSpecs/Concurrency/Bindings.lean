module
public import Veil

/-!
# jank's dynamic bindings and futures

A model of how jank 0.1 keeps the dynamic bindings of each thread, and how
`future` conveys them. Code references are to jank `f3d82d654`
(`compiler+runtime/`).

- **Binding frames** (`context.cpp` `push_thread_bindings`,
  `pop_thread_bindings`, `get_thread_bindings`): a stack of frames per
  `std::thread::id`, in one map. Pushing a frame copies the top frame's
  bindings and adds the new ones; `binding` pushes and pops
  (`clojure.core/binding`).
- **Thread ids** are the OS's (`pthread_t` on macOS), which it reuses once a
  thread has been joined; the frames map is keyed by them and never forgets
  one.
- **`future`** (`core.cpp` `future`): takes the creating thread's bindings,
  starts a thread, which pushes a frame with them, runs the body, and never
  pops that frame. Deref joins the thread (`obj/future.cpp`).
- **`future-cancel`** (`core.cpp` `cancel_future`): `pthread_cancel` on a running
  future. On macOS nothing records the cancellation (there is no
  `abi::__forced_unwind` to catch, and `is_future_cancelled` can't ask the
  thread), so the future stays `running`, and deref, after joining, returns
  its empty result: `nil`.

One dynamic var, `*x*`, is modelled. A future's body reads `*x*` (after
anything else it does), which is its result; futures don't bind `*x*`
themselves. Bindings by the main thread (`binding`) nest.
-/

veil module Bindings

type thread
type tid
type val

/- `main` is the main thread, with the OS thread id `mainTid`; `root` is
`*x*`'s root value. -/
immutable individual main : thread
immutable individual mainTid : tid
immutable individual root : val
immutable individual focus : Nat

/- Threads (futures). -/
relation spawned : thread → Bool
relation finished : thread → Bool
relation joined : thread → Bool
relation cancelled : thread → Bool
function tidOf : thread → tid
/- The creator's binding of `*x*` when the future was made (`none`: unbound). -/
function conveyed : thread → Option val
/- What the body read: `*x*`'s value. -/
function result : thread → val

/- OS thread ids in use (by a thread which hasn't been joined). -/
relation live : tid → Bool
/- Each thread id's stack of frames: `*x*`'s binding in each (`none`: not
bound), the top first. -/
function frames : tid → List (Option val)

/- What the main thread saw when it last dereffed a future: `some v`, or
`none` for `nil`. -/
individual lastDeref : Option val
individual lastDerefOf : thread

#gen_state

after_init {
  spawned T := false
  finished T := false
  joined T := false
  cancelled T := false
  conveyed T := none
  live I := false
  live mainTid := true
  frames I := []
  lastDeref := none
}

/- `*x*`'s binding in the top frame of `i`. -/
ghost relation boundIn (i : tid) (v : val) := (frames i).head? = some (some v)

/- `(binding [*x* v] ...)` on the main thread: push. The new frame copies the
top frame's bindings, then binds `*x*`. -/
action push (v : val) {
  frames mainTid := (some v) :: frames mainTid
}

/- The end of `(binding ...)`: pop. -/
action pop {
  require frames mainTid ≠ []
  frames mainTid := (frames mainTid).tail
}

/- `(future ...)` on the main thread: the future gets the main thread's
bindings, and a thread, with an OS thread id `i` not in use, which pushes a
frame: the top frame of `i`'s stack, if it has one, plus the conveyed
bindings. (The thread pushes it once it runs, but only it uses `i`'s frames,
so when doesn't matter.) -/
action spawn (f : thread) (i : tid) {
  require f ≠ main ∧ ¬ spawned f ∧ ¬ live i
  spawned f := true
  tidOf f := i
  live i := true
  let mine := (frames mainTid).head?.bind id
  conveyed f := mine
  let top := (frames i).head?.bind id
  frames i := (match mine with
               | some v => some v
               | none => top) :: frames i
}

/- The body reads `*x*`, and the thread ends, without popping its frame. -/
action finish (f : thread) {
  require spawned f ∧ ¬ finished f ∧ ¬ cancelled f
  finished f := true
  result f := ((frames (tidOf f)).head?.bind id).getD root
}

/- `(future-cancel f)` while it runs: the thread is cancelled. -/
action cancel (f : thread) {
  require spawned f ∧ ¬ finished f ∧ ¬ cancelled f
  cancelled f := true
}

/- `@f` on the main thread: join the thread (its id can then be reused), and
see its result, or `nil` if it was cancelled. -/
action deref (f : thread) {
  require spawned f ∧ (finished f ∨ cancelled f)
  if ¬ joined f then
    joined f := true
    live (tidOf f) := false
  lastDerefOf := f
  lastDeref := if cancelled f then none else some (result f)
}

/-! ## Properties -/

/- A future sees the binding it was given, or the root value. -/
safety [c3_binding_isolation]
  focus = 3 → (finished F → result F = (conveyed F).getD root)
/- A finished, joined thread leaves no binding frames. -/
safety [c4_frames_released]
  focus = 4 → (¬ live I ∧ I ≠ mainTid → frames I = [])
/- Dereffing a cancelled future doesn't return a value. -/
safety [c8_cancel_visible]
  focus = 8 → (lastDeref ≠ none ∨ ¬ cancelled lastDerefOf)

/- These hold: a running future's top frame has the binding it was given, and
a future given a binding sees it. -/
safety [conveyed_on_top]
  spawned F ∧ ¬ joined F ∧ conveyed F = some V → boundIn (tidOf F) V
safety [bound_future_sees_binding]
  finished F ∧ conveyed F = some V → result F = V
/- The main thread's id is never reused. -/
safety [main_live] live mainTid
safety [live_ids_distinct]
  spawned F ∧ spawned G ∧ ¬ joined F ∧ ¬ joined G ∧ F ≠ G → tidOf F ≠ tidOf G
safety [main_tid_unique] spawned F ∧ ¬ joined F → tidOf F ≠ mainTid

state_constraint [bounded] (frames mainTid).length ≤ 2

#gen_spec

/-! ## Model checking

`main` is thread 0, futures 1 and 2; three OS thread ids, `mainTid` 0; values
0 (the root) and 1, 2. -/

#model_check { thread := Fin 3, tid := Fin 3, val := Fin 3 }
  { main := 0, mainTid := 0, root := 0, focus := 0 }

/- Each expected property, on its own: the first run fails the build unless
the model checker finds a violation; the second prints the counterexample
without failing it, for the conformance harness to read from the build log. -/

-- c3_binding_isolation
#guard_msgs (drop error) in
#model_check interpreted { thread := Fin 3, tid := Fin 3, val := Fin 3 }
  { main := 0, mainTid := 0, root := 0, focus := 3 } (sequential := true)

set_option veil.violationIsError false in
#model_check interpreted { thread := Fin 3, tid := Fin 3, val := Fin 3 }
  { main := 0, mainTid := 0, root := 0, focus := 3 } (sequential := true)

-- c4_frames_released
#guard_msgs (drop error) in
#model_check interpreted { thread := Fin 3, tid := Fin 3, val := Fin 3 }
  { main := 0, mainTid := 0, root := 0, focus := 4 } (sequential := true)

set_option veil.violationIsError false in
#model_check interpreted { thread := Fin 3, tid := Fin 3, val := Fin 3 }
  { main := 0, mainTid := 0, root := 0, focus := 4 } (sequential := true)

-- c8_cancel_visible
#guard_msgs (drop error) in
#model_check interpreted { thread := Fin 3, tid := Fin 3, val := Fin 3 }
  { main := 0, mainTid := 0, root := 0, focus := 8 } (sequential := true)

set_option veil.violationIsError false in
#model_check interpreted { thread := Fin 3, tid := Fin 3, val := Fin 3 }
  { main := 0, mainTid := 0, root := 0, focus := 8 } (sequential := true)

#gen_executable

end Bindings
