import Veil

/-!
# Players' ranks on a ladder

Four players are ranked 0 (top) to 3 (bottom). A player may challenge someone
ranked one or two places above. When the challenger wins, the challenger takes
that place, and everyone from that place down to just above the challenger
moves down one place. A player who retires goes to the bottom, and everyone
who was below moves up one place.

Shows: an order among things kept as ranks (a `Nat` per thing), and how to
shift the other ranks when one moves, with a capitalised variable.
-/

veil module Ladder

enum player = { ann, ben, cid, dee }

function rank : player → Nat

#gen_state

after_init {
  rank ann := 0
  rank ben := 1
  rank cid := 2
  rank dee := 3
}

action win (p : player) (q : player) {
  require rank q < rank p ∧ rank p ≤ rank q + 2
  -- Keep q's place: the next line changes `rank q`.
  let place := rank q
  -- For every player K at once; `rank K` and `rank p` on the right are the
  -- ranks before this line.
  rank K := if place ≤ rank K ∧ rank K < rank p then rank K + 1 else rank K
  rank p := place
}

action retire (p : player) {
  require rank p < 3
  rank K := if rank p < rank K then rank K - 1 else rank K
  rank p := 3
}

-- No two players share a rank, and every rank is 0 to 3.
safety [ranks_differ] rank A = rank B → A = B
safety [on_ladder] rank P ≤ 3

#gen_spec
#gen_executable

-- The 24 orders of four players.
#model_check {}

end Ladder
