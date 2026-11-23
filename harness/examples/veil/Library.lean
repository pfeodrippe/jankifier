import Veil

/-!
# A library's loans

Members ask for books and borrow them, at most 2 books each. When several
members ask for the same book, the one with the lowest card number gets it.
A member who leaves the library gives back every book they hold.

Shows: two `type`s, a relation over two things (`lent`, `wants`), a number per
thing (`loans`), assignments to every point of one argument
(`lent B m := false`), and Veil's `TotalOrder` for a fixed order.
-/

veil module Library

type book
type member

-- A fixed order on members (their card numbers): `le a b` is "a's number is
-- at most b's". With `member := Fin 3` it is the order of 0, 1, 2.
instantiate tot : TotalOrder member
open TotalOrder

relation lent : book → member → Bool
relation wants : book → member → Bool
function loans : member → Nat

#gen_state

after_init {
  lent B M := false
  wants B M := false
  loans M := 0
}

action ask (b : book) (m : member) {
  require ¬ lent b m ∧ ¬ wants b m
  wants b m := true
}

action lend (b : book) (m : member) {
  require wants b m ∧ loans m < 2
  require ∀ o, ¬ lent b o
  require ∀ o, wants b o → le m o
  wants b m := false
  lent b m := true
  loans m := loans m + 1
}

action give_back (b : book) (m : member) {
  require lent b m
  lent b m := false
  loans m := loans m - 1
}

-- `B` is every book; `m` is the one member who leaves.
action leave (m : member) {
  lent B m := false
  wants B m := false
  loans m := 0
}

safety [one_borrower] lent B M ∧ lent B N → M = N
safety [at_most_two] loans M ≤ 2
safety [lent_counted] lent B M → loans M > 0

#gen_spec
#gen_executable

#model_check { book := Fin 2, member := Fin 2 }

end Library
