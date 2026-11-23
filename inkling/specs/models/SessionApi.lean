module
public import Veil

/-!
# The session API

What the session functions do to a session and when they throw
(`native/cpu.cpp`: `eval`, `reset`, `copy`, `sample`; `src/inkling/core.jank`:
`generate!`), as one action per outcome of a call. A throwing call leaves the
sessions as they were, except `generate!` (see below).

- `eval(s, ids)` throws if `pos + n > context` (checked first), or if an id is
  outside `[0, vocab)` (checked for every id before any is evaluated); else
  the ids are appended, `pos` grows by `n`, and the session has the logits of
  its last token. The model has calls of one and two ids.
- `reset(s)`: position 0, no tokens, no logits.
- `copy(dst, src)` throws if the sessions have different contexts (or
  models); else `dst` gets `src`'s position, tokens and logits.
- `sample(s)` throws if the session has no logits; it changes nothing.
- `generate!(s, n)` is `sample` then `eval!` of the sampled id, `n` times
  (stopping early at the end-of-sampling token, which the model leaves out):
  it throws at once without logits, and when the context fills before `n`
  tokens it has evaluated the tokens that fit when the next `eval!` throws, so
  the session keeps them and the call returns nothing. The model has `n = 2`.

`tok` stands for token ids, `valid t` for an id in `[0, vocab)`. Which
tokens a session holds isn't state here (a function of positions can't go
back and forth between Lean and jank in the conformance runs): the
conformance namespace keeps them as the model's actions say (appended by
`eval` and `generate!`, cleared by `reset`, copied by `copy`) and compares them
with the engine's.

Proved, for any number of sessions, tokens and contexts: a session's position
never passes its context, and a session has logits exactly when its position
isn't 0, so `sample` and `generate!` succeed exactly when the session has
evaluated a token since it was made or reset. `inkling-specs.session-model`
runs the model's steps on the engine and compares.
-/

set_option veil.smt.trust false

veil module SessionApi

type sess
type tok
enum result_t = { ok, threw }

immutable function ctx : sess → Nat
immutable relation valid : tok → Bool

individual result : result_t
function pos : sess → Nat
relation logits : sess → Bool

#gen_state

after_init {
  result := ok
  pos S := 0
  logits S := false
}

/-! ## eval -/

action eval1 (s : sess) (t : tok) {
  require pos s + 1 ≤ ctx s ∧ valid t
  pos s := pos s + 1
  logits s := true
  result := ok
}

action eval2 (s : sess) (t : tok) (u : tok) {
  require pos s + 2 ≤ ctx s ∧ valid t ∧ valid u
  pos s := pos s + 2
  logits s := true
  result := ok
}

/- The context is checked first. -/
action eval1Full (s : sess) (t : tok) {
  require ctx s < pos s + 1
  result := threw
}

action eval2Full (s : sess) (t : tok) (u : tok) {
  require ctx s < pos s + 2
  result := threw
}

action eval1BadId (s : sess) (t : tok) {
  require pos s + 1 ≤ ctx s ∧ ¬ valid t
  result := threw
}

/- Every id is checked before any is evaluated. -/
action eval2BadId (s : sess) (t : tok) (u : tok) {
  require pos s + 2 ≤ ctx s ∧ (¬ valid t ∨ ¬ valid u)
  result := threw
}

/-! ## reset, copy -/

action reset (s : sess) {
  pos s := 0
  logits s := false
  result := ok
}

action copy (d : sess) (s : sess) {
  require ctx d = ctx s
  pos d := pos s
  logits d := logits s
  result := ok
}

action copyBad (d : sess) (s : sess) {
  require ctx d ≠ ctx s
  result := threw
}

/-! ## sample, generate! -/

action sample (s : sess) {
  require logits s
  result := ok
}

action sampleNone (s : sess) {
  require ¬ logits s
  result := threw
}

/- `generate!(s, 2)`, sampling t then u. -/
action generate2 (s : sess) (t : tok) (u : tok) {
  require logits s ∧ pos s + 2 ≤ ctx s ∧ valid t ∧ valid u
  pos s := pos s + 2
  result := ok
}

/- One position left: the first sampled token is evaluated, the second
eval! throws. -/
action generate2Partial (s : sess) (t : tok) {
  require logits s ∧ pos s + 1 = ctx s ∧ valid t
  pos s := pos s + 1
  result := threw
}

/- No position left: the first eval! throws. -/
action generate2Full (s : sess) {
  require logits s ∧ ctx s ≤ pos s
  result := threw
}

action generate2None (s : sess) {
  require ¬ logits s
  result := threw
}

/-! ## Properties -/

safety [within_context] pos S ≤ ctx S
safety [logits_iff_tokens] logits S ↔ 0 < pos S

#gen_spec

#gen_executable

#check_invariants

end SessionApi
