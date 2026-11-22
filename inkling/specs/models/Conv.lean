module
public import Veil

/-!
# The short convolutions' history

Every visit has four causal convolutions over time (keys, values, attention
output, feed-forward output), each over the current input and the three before
it (`conv_taps = 4`). A session keeps the last three inputs of each
(`visit_cache::conv`), so that a chunk's first tokens see the inputs of the
chunks before.

Two implementations:

- `window` (`native/cpu.cpp`, `short_conv_apply`): builds `history ++ chunk`,
  computes the output of token `t` from entries `t .. t + 3` of it, then stores
  its last three entries as the history.
- `rolling` (`native/kernels.metal`, `conv_fixed` and `conv_dyn`): one thread
  per channel loads the history into three registers, and for each token
  computes the output from the registers and the input, then shifts them; it
  writes the registers back at the end.

An input is identified by its position plus one, and 0 is the zero a new
session's history holds: with truncated subtraction, the inputs of position
`p`'s output are `p - 2, p - 1, p, p + 1` in that numbering, and a session at
position `pos` has the history `pos - 2, pos - 1, pos`.

The model says which inputs each output reads. Which coefficient multiplies
which of them (the fixed convolutions store their taps oldest first, the
projected ones by lag) is the same expression in both implementations; the
conformance test compares their results.
-/

set_option veil.smt.trust false

veil module Conv

type sess
enum phase_t = { idle, running }
enum impl_t = { window, rolling }

immutable individual impl : impl_t
immutable individual maxChunk : Nat
immutable individual context : Nat

function pos : sess → Nat
function phase : sess → phase_t
/- Tokens of the chunk computed so far. -/
function done : sess → Nat
/- The history, oldest first. -/
function h0 : sess → Nat
function h1 : sess → Nat
function h2 : sess → Nat
/- The Metal kernel's registers. -/
function g0 : sess → Nat
function g1 : sess → Nat
function g2 : sess → Nat
/- Ghost: the inputs the last output read, oldest first, and that output's
input (0: none yet). -/
function u0 : sess → Nat
function u1 : sess → Nat
function u2 : sess → Nat
function u3 : sess → Nat
function last : sess → Nat

#gen_state

after_init {
  pos S := 0
  phase S := idle
  done S := 0
  h0 S := 0
  h1 S := 0
  h2 S := 0
  g0 S := 0
  g1 S := 0
  g2 S := 0
  u0 S := 0
  u1 S := 0
  u2 S := 0
  u3 S := 0
  last S := 0
}

/- A chunk's convolution starts: the kernel loads the history. -/
action begin (s : sess) {
  require phase s = idle ∧ pos s < context
  phase s := running
  done s := 0
  g0 s := h0 s
  g1 s := h1 s
  g2 s := h2 s
}

/- The output of the chunk's next token. -/
action token (s : sess) {
  require phase s = running ∧ done s < maxChunk ∧ pos s + done s < context
  let d := done s
  let x := pos s + d + 1
  if impl = window then
    -- Entry i of history ++ chunk: the history, then the chunk's inputs.
    u0 s := if d = 0 then h0 s else if d = 1 then h1 s else if d = 2 then h2 s else pos s + d - 2
    u1 s := if d = 0 then h1 s else if d = 1 then h2 s else pos s + d - 1
    u2 s := if d = 0 then h2 s else pos s + d
    u3 s := x
  else
    let a := g0 s
    let b := g1 s
    let c := g2 s
    u0 s := a
    u1 s := b
    u2 s := c
    u3 s := x
    g0 s := b
    g1 s := c
    g2 s := x
  last s := x
  done s := d + 1
}

/- The chunk is done: the history is the last three entries of
history ++ chunk, or the registers. -/
action finish (s : sess) {
  require phase s = running ∧ 0 < done s
  let d := done s
  if impl = window then
    let a := if d = 1 then h1 s else if d = 2 then h2 s else pos s + d - 2
    let b := if d = 1 then h2 s else pos s + d - 1
    h0 s := a
    h1 s := b
    h2 s := pos s + d
  else
    let a := g0 s
    let b := g1 s
    let c := g2 s
    h0 s := a
    h1 s := b
    h2 s := c
  pos s := pos s + d
  done s := 0
  phase s := idle
}

/- `reset` zeroes the histories. -/
action reset (s : sess) {
  require phase s = idle
  pos s := 0
  h0 s := 0
  h1 s := 0
  h2 s := 0
  last s := 0
}

/- `copy` copies them. -/
action copy (d : sess) (s : sess) {
  require d ≠ s ∧ phase d = idle ∧ phase s = idle
  pos d := pos s
  h0 d := h0 s
  h1 d := h1 s
  h2 d := h2 s
  last d := 0
}

/- An output reads its own input and the three before it, however the tokens
were split into chunks. -/
safety [taps] 0 < last S →
  u3 S = last S ∧ u2 S = last S - 1 ∧ u1 S = last S - 2 ∧ u0 S = last S - 3
/- Between chunks the history is the last three inputs. -/
safety [history] phase S = idle → h2 S = pos S ∧ h1 S = pos S - 1 ∧ h0 S = pos S - 2

/-! Auxiliary invariants. -/

invariant [history_kept] h2 S = pos S ∧ h1 S = pos S - 1 ∧ h0 S = pos S - 2
invariant [registers] impl = rolling ∧ phase S = running →
  g2 S = pos S + done S ∧ g1 S = pos S + done S - 1 ∧ g0 S = pos S + done S - 2
invariant [idle_done] phase S = idle → done S = 0

#gen_spec

-- For the checks driven from jank (veil/model-check, veil/system).
#gen_executable

#check_invariants

/-! ## Model checking: two sessions, chunks of up to 3, 7 positions. -/

#model_check { sess := Fin 2 } { impl := window, maxChunk := 3, context := 7 }
#model_check { sess := Fin 2 } { impl := rolling, maxChunk := 3, context := 7 }

end Conv
