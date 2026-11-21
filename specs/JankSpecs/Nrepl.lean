module
public import Veil

/-!
# jank's nREPL server

A model of how jank 0.1's nREPL server handles requests
(`src/jank/jank/nrepl/server/` at `f3d82d654`):

- **Connections** (`core.jank` `-main`, `handle-client`): each client gets a
  future, which reads its requests and handles them one at a time, in order,
  writing each one's responses. If handling a request throws, the future's
  `catch` prints it and the loop ends: that connection gets no more
  responses.
- **Evaluation** (`handler/eval.jank` `do-eval`, `capture.jank`,
  `evaluate.cpp` `safe_eval`): stdout is captured in steps: `dup` file
  descriptor 1 (the backup), `fflush(stdout)`, `dup2` a temp file over 1;
  evaluate; then `fflush(stdout)`, `dup2` the backup back, and read and delete
  the temp file. The descriptor and the `stdout` buffer are the process's, not
  the connection's, and other connections' steps interleave with these.
- **Printing** (`core.cpp` `println`) `fwrite`s to C's `stdout`, which is
  buffered: what's printed goes to wherever descriptor 1 points when the
  buffer is flushed (by any capture's `fflush`), not when it's printed. A failed eval answers with
  `{:ex ... :status [:done :eval-error]}`, one message; a successful one sends
  `:value` and then `{:status [:done]}`.
- **`*1`** is set with `var::set`, on the connection thread's binding (the
  connection's future conveyed it), so each connection has its own `*1`.
  Sessions aren't tracked: `clone` returns a new id and nothing uses it.
- A request whose eval arguments are wrong (e.g. a non-numeric `"line"`)
  throws while converting them, inside the capture (which is restored), and
  outside `safe-eval`, so it ends the connection's loop.

- Every response goes through `response-for` (`core.jank`), which copies the
  request's `id` and `session` into it; an op without a handler gets
  `{:status [:error :unknown-op :done]}` (`handler.jank`).

The requests, which connection sends them and in which session, are the
theory: requests on a connection are handled in their order (`tot.le`). Only
stdout is modelled; stderr is captured the same way.

The state uses only relations and enums (no `Option`), so that
`#check_invariants` can prove what holds for any number of connections,
requests and sessions.
-/

-- The SMT solver's answers are turned into proofs which Lean's kernel checks.
set_option veil.smt.trust false

veil module Nrepl

type conn
type req
type session
instantiate tot : TotalOrder req
open TotalOrder

enum kind_t = { evalOk, evalPrint, evalThrow, evalStar1, evalBad, unknownOp, otherOp }
enum phase_t = { queued, taken, capturing, evaluated, flushed, released, answered, lost }

immutable function reqConn : req → conn
immutable function reqKind : req → kind_t
immutable function reqSession : req → session
immutable individual focus : Nat

relation alive : conn → Bool
relation busy : conn → Bool
function phase : req → phase_t

/- Where file descriptor 1 points: `stdoutTo q` when it's the temp file of
`q`'s capture, nowhere when it's the process's stdout. `backupTo r q` when
`r`'s backup is `q`'s temp file (none: the process's stdout). -/
relation stdoutTo : req → Bool
relation backupTo : req → req → Bool
relation deleted : req → Bool
/- What's in `stdout`'s buffer: `r` printed it and it isn't flushed yet. -/
relation buffered : req → Bool
/- `printedIn r q`: what `r` printed went to `q`'s temp file (before it was
read back); `printedLost r`: to a temp file already deleted. -/
relation printedIn : req → req → Bool
relation printedLost : req → Bool
relation printedTerminal : req → Bool

/- What an eval returned (`valueIs r q`: request `q`'s value; none: `nil`),
and whether its error came in the same message as `done`. -/
relation valueIs : req → req → Bool
relation errDoneTogether : req → Bool
/- `*1` of each connection's thread, what it would be per session, and what
an eval of `*1` should have returned. -/
relation star1Is : conn → req → Bool
relation star1SessionIs : session → req → Bool
relation expectedIs : req → req → Bool
/- The responses carried the request's `id` and `session`; an unknown op was
reported as one. -/
relation tagged : req → Bool
relation unknownReported : req → Bool

#gen_state

after_init {
  alive C := true
  busy C := false
  phase R := queued
  stdoutTo R := false
  backupTo R Q := false
  deleted R := false
  buffered R := false
  printedIn R Q := false
  printedLost R := false
  printedTerminal R := false
  valueIs R Q := false
  errDoneTogether R := false
  star1Is C R := false
  star1SessionIs S R := false
  expectedIs R Q := false
  tagged R := false
  unknownReported R := false
}

ghost relation isEval (r : req) :=
  reqKind r = evalOk ∨ reqKind r = evalPrint ∨ reqKind r = evalThrow ∨
  reqKind r = evalStar1 ∨ reqKind r = evalBad

/- `fflush(stdout)`: the buffer goes to wherever descriptor 1 points: the
process's stdout, a temp file, or a temp file already deleted. -/
procedure flush {
  printedTerminal X := decide (printedTerminal X ∨ (buffered X ∧ ∀ Q, ¬ stdoutTo Q))
  printedLost X := decide (printedLost X ∨ (buffered X ∧ ∃ Q, stdoutTo Q ∧ deleted Q))
  printedIn X Q := decide (printedIn X Q ∨ (buffered X ∧ stdoutTo Q ∧ ¬ deleted Q))
  buffered X := false
}

/- The connection's loop takes its next request. Other ops answer right away;
an eval starts its capture: `dup` of descriptor 1, the backup. -/
action take (c : conn) (r : req) {
  require alive c ∧ ¬ busy c
  require reqConn r = c ∧ phase r = queued
  require ∀ Q, reqConn Q = c ∧ phase Q = queued → le r Q
  if isEval r then
    busy c := true
    backupTo r Q := stdoutTo Q
    phase r := taken
  else
    if reqKind r = unknownOp then
      unknownReported r := true
    tagged r := true
    phase r := answered
}

/- The capture goes on: `fflush`, then the temp file over descriptor 1. -/
action redirect (r : req) {
  require phase r = taken
  flush
  stdoutTo Q := decide (Q = r)
  phase r := capturing
}

/- The eval runs, inside the capture; what it prints goes to the buffer. -/
action evaluate (r : req) {
  require phase r = capturing
  let c := reqConn r
  if reqKind r = evalPrint then
    buffered r := true
  if reqKind r = evalOk ∨ reqKind r = evalPrint then
    valueIs r Q := decide (Q = r)
    star1Is c Q := decide (Q = r)
    star1SessionIs (reqSession r) Q := decide (Q = r)
  if reqKind r = evalStar1 then
    valueIs r Q := star1Is c Q
    expectedIs r Q := star1SessionIs (reqSession r) Q
  phase r := evaluated
}

/- The capture ends: `fflush`, ... -/
action endFlush (r : req) {
  require phase r = evaluated
  flush
  phase r := flushed
}

/- ... then descriptor 1 goes back to the backup, and the temp file is read
and deleted. -/
action release (r : req) {
  require phase r = flushed
  stdoutTo Q := backupTo r Q
  deleted r := true
  if reqKind r = evalBad then
    -- The bad argument threw: the connection's loop ends.
    alive (reqConn r) := false
    busy (reqConn r) := false
    phase r := lost
  else
    phase r := released
}

/- The responses are written. -/
action respond (r : req) {
  require phase r = released
  if reqKind r = evalThrow then
    errDoneTogether r := true
  tagged r := true
  busy (reqConn r) := false
  phase r := answered
}

/-! ## Properties -/

/- N1: every request is answered: a connection's loop doesn't end. -/
safety [n1_connection_survives] focus = 1 → alive C
/- N3: `done` comes in its own message, not with `eval-error`. -/
safety [n3_done_separate] focus = 3 → ¬ errDoneTogether R
/- N4: an eval's output goes to its own response, and only there. -/
safety [n4_output_isolation]
  focus = 4 → ((printedIn X R → X = R) ∧ ¬ printedLost X ∧ ¬ printedTerminal X)
/- N5: once no eval is running, stdout is the process's again. -/
safety [n5_stdout_restored] focus = 5 → ((∀ C, ¬ busy C) → ¬ stdoutTo Q)
/- N6: `*1` is the session's last value. -/
safety [n6_sessions_isolated]
  focus = 6 → (phase R = answered ∧ reqKind R = evalStar1 → (valueIs R Q ↔ expectedIs R Q))
/- N2: every response carries its request's `id` and `session`. N7: an
unknown op is reported as one. (They hold by `response-for` and the
`:default` handler, which the model copies; the conformance check is what
tests them on jank.) -/
safety [n2_responses_tagged] phase R = answered → tagged R
safety [n7_unknown_op_reported]
  phase R = answered ∧ reqKind R = unknownOp → unknownReported R

/- These hold: a connection handles one eval at a time, in order. -/
ghost relation inEval (r : req) :=
  phase r = taken ∨ phase r = capturing ∨ phase r = evaluated ∨ phase r = flushed ∨
  phase r = released

safety [one_eval_per_connection] inEval R ∧ inEval Q ∧ reqConn R = reqConn Q → R = Q
safety [in_order]
  phase R ≠ queued ∧ reqConn Q = reqConn R ∧ le Q R → phase Q ≠ queued
safety [answered_only_when_alive_or_before]
  phase R = lost → ¬ alive (reqConn R)

/- Auxiliary invariants, which make the above inductive: a connection with an
eval in progress is busy; only evals go through the capture; descriptor 1 and each backup point to at most one
temp file. -/
invariant [eval_busy] inEval R → busy (reqConn R)
invariant [only_evals_capture] inEval R ∨ phase R = lost → isEval R
invariant [stdout_single] stdoutTo Q ∧ stdoutTo R → Q = R
invariant [backup_single] backupTo R Q ∧ backupTo R X → Q = X

#gen_spec

/-! ## Proofs

Everything except N1, N3, N4, N5 and N6 is proved for any number of
connections, requests and sessions. Those five are only required when `focus`
is 1, 3, 4, 5 or 6; they're false there (the model checker below shows it), so
their rows fail. That doesn't weaken the other proofs: with `focus = 0` they
hold trivially, so the others are inductive on their own, and no action reads
`focus`, so the reachable states are the same for every `focus`. `#guard_msgs`
pins the table of results, so the build fails if any of them changes. -/

/--
info: Initialization must establish the invariant:
  doesNotThrow ... ✅
  n1_connection_survives ... ✅
  n3_done_separate ... ✅
  n4_output_isolation ... ✅
  n5_stdout_restored ... ✅
  n6_sessions_isolated ... ✅
  n2_responses_tagged ... ✅
  n7_unknown_op_reported ... ✅
  one_eval_per_connection ... ✅
  in_order ... ✅
  answered_only_when_alive_or_before ... ✅
  eval_busy ... ✅
  only_evals_capture ... ✅
  stdout_single ... ✅
  backup_single ... ✅
The following set of actions must preserve the invariant and successfully terminate:
  release
    doesNotThrow ... ✅
    n1_connection_survives ... ❌
    n3_done_separate ... ✅
    n4_output_isolation ... ✅
    n5_stdout_restored ... ❌
    n6_sessions_isolated ... ✅
    n2_responses_tagged ... ✅
    n7_unknown_op_reported ... ✅
    one_eval_per_connection ... ✅
    in_order ... ✅
    answered_only_when_alive_or_before ... ✅
    eval_busy ... ✅
    only_evals_capture ... ✅
    stdout_single ... ✅
    backup_single ... ✅
  redirect
    doesNotThrow ... ✅
    n1_connection_survives ... ✅
    n3_done_separate ... ✅
    n4_output_isolation ... ❌
    n5_stdout_restored ... ✅
    n6_sessions_isolated ... ✅
    n2_responses_tagged ... ✅
    n7_unknown_op_reported ... ✅
    one_eval_per_connection ... ✅
    in_order ... ✅
    answered_only_when_alive_or_before ... ✅
    eval_busy ... ✅
    only_evals_capture ... ✅
    stdout_single ... ✅
    backup_single ... ✅
  endFlush
    doesNotThrow ... ✅
    n1_connection_survives ... ✅
    n3_done_separate ... ✅
    n4_output_isolation ... ❌
    n5_stdout_restored ... ✅
    n6_sessions_isolated ... ✅
    n2_responses_tagged ... ✅
    n7_unknown_op_reported ... ✅
    one_eval_per_connection ... ✅
    in_order ... ✅
    answered_only_when_alive_or_before ... ✅
    eval_busy ... ✅
    only_evals_capture ... ✅
    stdout_single ... ✅
    backup_single ... ✅
  respond
    doesNotThrow ... ✅
    n1_connection_survives ... ✅
    n3_done_separate ... ❌
    n4_output_isolation ... ✅
    n5_stdout_restored ... ❌
    n6_sessions_isolated ... ❌
    n2_responses_tagged ... ✅
    n7_unknown_op_reported ... ✅
    one_eval_per_connection ... ✅
    in_order ... ✅
    answered_only_when_alive_or_before ... ✅
    eval_busy ... ✅
    only_evals_capture ... ✅
    stdout_single ... ✅
    backup_single ... ✅
  evaluate
    doesNotThrow ... ✅
    n1_connection_survives ... ✅
    n3_done_separate ... ✅
    n4_output_isolation ... ✅
    n5_stdout_restored ... ✅
    n6_sessions_isolated ... ✅
    n2_responses_tagged ... ✅
    n7_unknown_op_reported ... ✅
    one_eval_per_connection ... ✅
    in_order ... ✅
    answered_only_when_alive_or_before ... ✅
    eval_busy ... ✅
    only_evals_capture ... ✅
    stdout_single ... ✅
    backup_single ... ✅
  take
    doesNotThrow ... ✅
    n1_connection_survives ... ✅
    n3_done_separate ... ✅
    n4_output_isolation ... ✅
    n5_stdout_restored ... ✅
    n6_sessions_isolated ... ✅
    n2_responses_tagged ... ✅
    n7_unknown_op_reported ... ✅
    one_eval_per_connection ... ✅
    in_order ... ✅
    answered_only_when_alive_or_before ... ✅
    eval_busy ... ✅
    only_evals_capture ... ✅
    stdout_single ... ✅
    backup_single ... ✅
-/
#guard_msgs in
set_option veil.printCounterexamples false in
set_option veil.violationIsError false in
#check_invariants

/-! ## Model checking

Two connections, four requests, two sessions. -/

-- Everything that holds, with every kind of request: conn 0 sends 0 and 1,
-- conn 1 sends 2 and 3.
#model_check { conn := Fin 2, req := Fin 4, session := Fin 2 }
  { reqConn := fun r => if r.val < 2 then 0 else 1,
    reqKind := fun r => match r.val with
      | 0 => kind_t_IndT.evalPrint | 1 => kind_t_IndT.evalStar1
      | 2 => kind_t_IndT.evalPrint | _ => kind_t_IndT.evalThrow,
    reqSession := fun r => if r.val % 2 = 0 then 0 else 1, focus := 0 }

-- N1: a bad eval argument ends the connection.
#guard_msgs (drop error) in
#model_check { conn := Fin 2, req := Fin 4, session := Fin 2 }
  { reqConn := fun _ => 0,
    reqKind := fun r => if r.val = 0 then kind_t_IndT.evalBad else kind_t_IndT.evalOk,
    reqSession := fun _ => 0, focus := 1 } (sequential := true)

set_option veil.violationIsError false in
#model_check { conn := Fin 2, req := Fin 4, session := Fin 2 }
  { reqConn := fun _ => 0,
    reqKind := fun r => if r.val = 0 then kind_t_IndT.evalBad else kind_t_IndT.evalOk,
    reqSession := fun _ => 0, focus := 1 } (sequential := true)

-- N3: an eval which throws.
#guard_msgs (drop error) in
#model_check { conn := Fin 2, req := Fin 4, session := Fin 2 }
  { reqConn := fun _ => 0, reqKind := fun _ => kind_t_IndT.evalThrow,
    reqSession := fun _ => 0, focus := 3 } (sequential := true)

set_option veil.violationIsError false in
#model_check { conn := Fin 2, req := Fin 4, session := Fin 2 }
  { reqConn := fun _ => 0, reqKind := fun _ => kind_t_IndT.evalThrow,
    reqSession := fun _ => 0, focus := 3 } (sequential := true)

-- N4 and N5: two connections printing at the same time.
#guard_msgs (drop error) in
#model_check { conn := Fin 2, req := Fin 4, session := Fin 2 }
  { reqConn := fun r => if r.val < 2 then 0 else 1, reqKind := fun _ => kind_t_IndT.evalPrint,
    reqSession := fun _ => 0, focus := 4 } (sequential := true)

set_option veil.violationIsError false in
#model_check { conn := Fin 2, req := Fin 4, session := Fin 2 }
  { reqConn := fun r => if r.val < 2 then 0 else 1, reqKind := fun _ => kind_t_IndT.evalPrint,
    reqSession := fun _ => 0, focus := 4 } (sequential := true)

#guard_msgs (drop error) in
#model_check { conn := Fin 2, req := Fin 4, session := Fin 2 }
  { reqConn := fun r => if r.val < 2 then 0 else 1, reqKind := fun _ => kind_t_IndT.evalPrint,
    reqSession := fun _ => 0, focus := 5 } (sequential := true)

set_option veil.violationIsError false in
#model_check { conn := Fin 2, req := Fin 4, session := Fin 2 }
  { reqConn := fun r => if r.val < 2 then 0 else 1, reqKind := fun _ => kind_t_IndT.evalPrint,
    reqSession := fun _ => 0, focus := 5 } (sequential := true)

-- N6: two sessions on one connection.
#guard_msgs (drop error) in
#model_check { conn := Fin 2, req := Fin 4, session := Fin 2 }
  { reqConn := fun _ => 0,
    reqKind := fun r => if r.val = 0 then kind_t_IndT.evalOk else kind_t_IndT.evalStar1,
    reqSession := fun r => if r.val = 0 then 0 else 1, focus := 6 } (sequential := true)

set_option veil.violationIsError false in
#model_check { conn := Fin 2, req := Fin 4, session := Fin 2 }
  { reqConn := fun _ => 0,
    reqKind := fun r => if r.val = 0 then kind_t_IndT.evalOk else kind_t_IndT.evalStar1,
    reqSession := fun r => if r.val = 0 then 0 else 1, focus := 6 } (sequential := true)

#gen_executable

end Nrepl
