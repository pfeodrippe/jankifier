# Writing a Veil model

Veil is a language for describing a system as a set of states and the steps
between them. It is written inside Lean 4. You describe:

- the state: a few named fields;
- the initial state;
- the actions: the steps the system can take, each with its arguments and the
  condition under which it is allowed;
- properties: facts that must be true in every state.

Veil's model checker then tries every action, with every argument, from every
state it can reach, and checks the properties in each state.

For the harness, the model is a `.lean` file next to your jank code, and its
actions are your code's operations. This guide covers the Veil that the harness
uses. Every rule here was checked on that version. If something is not in this
guide, assume it is untested and keep to what is.

Worked examples, each checked and model-checked:

| File | What it shows |
|---|---|
| `examples/parking.lean` | The smallest complete model, paired with `examples/parking.jank` |
| `examples/veil/Lift.lean` | Counters with bounds, an enum, `Nat` subtraction, a `Bool` argument, `if` |
| `examples/veil/Crossing.lean` | Enums, a value per thing, a set of things, `∀` and `∃`, updating every point |
| `examples/veil/Library.lean` | Two types, relations over two things, a number per thing, `TotalOrder` |
| `examples/veil/Ladder.lean` | Ranks, and shifting the other ranks when one player moves |

## How the harness uses the file

The harness:

1. Loads the file into Veil. It leaves out the `#model_check` lines and the
   `module` and `import` lines.
2. Model-checks it, with each `type` given the number of values in `:instance`,
   for at least `:max-depth` steps from the initial state.
3. Runs your real code at random: at each step it picks one of the model's
   actions with arguments, does it on the real code, and compares the real
   state (your `:view`) with the model's state, field by field.

So the file must follow these rules:

- Put `#gen_executable` on the line after `#gen_spec`. Without it the harness
  fails with `has no executable definitions: add #gen_executable to it`.
- Write `#gen_spec` alone on its line. The harness adds its `:sometimes`
  properties just before that line.
- Give every property a name: `safety [name] ...`. The harness checks the real
  states against the named ones.
- Each `type` needs an entry in `:instance` with the same name:
  `type spot` needs `{:spot 3}`.
- The harness gives values only to types. Don't use `immutable` fields or
  `param`. Write constants as numbers in the model (`require level < 3`).
- Write one `veil module` per file.

## The shape of a file

```lean
import Veil

veil module Lamps

-- A kind of thing. `:instance {:lamp 3}` makes three lamps: 0, 1 and 2.
type lamp

-- The state: which lamps are lit, and how many times a switch was pressed.
relation lit : lamp → Bool
individual presses : Nat

#gen_state

-- The initial state. Give every field a value.
after_init {
  lit L := false
  presses := 0
}

-- An action: something the real code does. `l` is its argument.
action press (l : lamp) {
  require presses < 5
  lit l := !lit l
  presses := presses + 1
}

action all_off {
  lit L := false
}

-- A property that must hold in every reachable state.
safety [few_presses] presses ≤ 5

#gen_spec
#gen_executable

#model_check { lamp := Fin 3 }

end Lamps
```

The parts, in this order:

1. `import Veil`. (`module` and then `public import Veil` also work.)
2. `veil module Name`. Give it a name that says what it models, such as
   `Lift`: a module named `W` fails with errors about `wp`.
3. Types: `type` and `enum`.
4. State fields: `individual`, `relation`, `function`.
5. `#gen_state`.
6. `after_init { ... }`: the initial state.
7. Actions: `action name (args) { ... }`.
8. Properties: `safety [name] term` and `invariant [name] term`.
9. `#gen_spec`, then `#gen_executable`.
10. `#model_check ...`, for checking the file yourself. The harness skips it.
    Keep it on one line.
11. `end Name`.

Comments are `-- to the end of the line` and `/- a block -/`. `//` is an error.

## Types

### `type`: a kind of thing

```lean
type spot
```

A set of things with no structure. The harness makes `n` of them, numbered
`0` to `n - 1`, from `:instance`. In the model you can only compare two of
them with `=` and `≠`. There are no literals (`best := 0` is an error), no
`<`, and no arithmetic on them. For a fixed order among them, see
[TotalOrder](#a-fixed-order-totalorder).

### `enum`: named values

```lean
enum colour = { red, amber, green }
```

Write the values in lower case, and use them without the type's name:
`light r := red`. `colour.red` is an error. A value in capitals such as `RED`
is a trap: used as an index on the left of `:=`, it is read as "every point"
(Veil warns `capitalized index RED is a universal index`).

### `Nat`, `Bool`, `Option`

- `Nat`: 0, 1, 2, ... There are no negative numbers.
  [Subtraction stops at 0](#nat-subtraction).
- `Bool`: `true` and `false`.
- `Option spot`: `none`, or `some s`. Use it for "a thing, or nothing":
  `individual holder : Option spot`, `holder := some s`, `require holder = none`.

## State fields

```lean
individual parked : Nat          -- one value
individual door : door_t         -- one value of an enum
relation taken : spot → Bool     -- true or false for each spot: a set of spots
relation lent : book → member → Bool   -- for each pair: a set of pairs
function loans : member → Nat    -- a value for each member
function light : road → colour   -- an enum value for each road
```

A relation's or function's arguments should be types, enums or `Bool`. A
function from `Nat` elaborates, but you can't set it at every point (see
[Assignments](#assignments)), so avoid it.

How the harness sees each field, as jank data:

| Field | jank value | Example |
|---|---|---|
| `individual parked : Nat` | the number | `2` |
| `individual is_open : Bool` | the boolean | `true` |
| `individual door : door_t` | a keyword | `:closed` |
| `individual holder : Option spot` | `nil`, or the value | `1` |
| `relation taken : spot → Bool` | the set of spots where it is true | `#{0 2}` |
| `relation lent : book → member → Bool` | the set of pairs where it is true | `#{[0 1]}` |
| `function loans : member → Nat` | a map from each point set so far to its value | `{0 0, 1 2}` |
| `function rank : player → Nat` (an enum argument) | the same, keyed by keywords | `{:ann 0 :ben 1}` |

A value of a `type` is its number (`0`, `1`, ...). An action's arguments come
as a map keyed by the parameter names: `action lend (b : book) (m : member)`
gives `{:b 0 :m 1}`.

A function holds only the points that were set. If `after_init` doesn't set a
function, its map is `{}`; after `loans m := 1` it is `{0 1}`. So set every
function at every point in `after_init` (`loans M := 0`); then its map always
has every key.

## The initial state: `after_init`

```lean
after_init {
  taken S := false
  parked := 0
  door := closed
  holder := none
}
```

Give every field a value here. A field you leave out keeps a default (`0`,
`false`, the first enum value, `none`, an empty relation, an empty function),
and the empty function map rarely matches your view. An empty
`after_init { }` is an error.

## Actions

```lean
action lend (b : book) (m : member) {
  require wants b m ∧ loans m < 2
  require ∀ o, ¬ lent b o
  wants b m := false
  lent b m := true
  loans m := loans m + 1
}

action all_off {
  lit L := false
}
```

- An action has a name, then zero or more arguments, each with its type:
  `(b : book) (m : member)`, or `(a b : player)` for two of one type.
- Argument types must be types, enums or `Bool`. A `Nat` argument fails with
  `failed to synthesize instance of type class Enumeration Nat`. If an
  operation takes a number, list the few values it can take as an `enum`, or
  use a `type` when the model only compares them with `=`.
- Name arguments in lower case. A capitalised argument such as `(P : player)`
  breaks `#gen_spec` with confusing errors.
- `require c`: the action can happen only when `c` is true. When `c` is false
  the action doesn't happen at all, and changes nothing.
- The statements run in order, and each one sees what the earlier ones wrote.
  A `require` after an assignment reads the new value: with
  `n := n + 1` then `require n ≤ 2`, the action is allowed only when the new
  `n` is at most 2.
- Several statements can share a line with `;`: `{ taken s := true; parked := parked + 1 }`.
- Two actions can't have the same name.

### `if` and `let` in actions

```lean
action down (express : Bool) {
  require door = closed ∧ 0 < level
  if express then
    level := level - 2
  else
    level := level - 1
}

action leave (s : spot) {
  require taken s
  let before := parked
  taken s := false
  parked := before - 1
}
```

- The statements of a branch go on the following lines, indented further than
  the `if`. `else` is optional for a statement. `else if` works.
- `let x := e` names a value. It is fixed at that point: a later assignment to
  a field doesn't change `x`. That is how you keep an old value (see
  [Ladder](examples/veil/Ladder.lean)).

### Procedures

A `procedure` is a helper that actions call. It is not a step of its own: the
harness never picks it.

```lean
procedure free (s : spot) {
  taken s := false
  parked := parked - 1
}

action leave (s : spot) {
  require taken s
  free s
}
```

## Assignments

| Assignment | Meaning |
|---|---|
| `parked := parked + 1` | an individual |
| `taken s := true` | a relation at one point |
| `lent b m := true` | a relation of two arguments at one pair |
| `loans m := loans m + 1` | a function at one point |
| `taken S := false` | a relation at every point |
| `loans M := 0` | a function at every point |
| `lent B M := false` | every pair |
| `lent B m := false` | every book, for the one member `m` |

Use `:=`. `parked = parked + 1` is a comparison, not an assignment, and is an
error.

### Capitalised variables

A capitalised variable is a name made only of capital letters and digits: `K`,
`S`, `B`, `M1`. (`N'` is not one.) On the left of `:=`, in an argument
position, it means "every value". `taken S := false` sets `taken` to false at
every spot.

On the right of `:=`, the same variable stands for the point being set, and
every field means its value before this statement. The new value at each point
is computed from the old values, for all points at once. So this works and
does what it says:

```lean
pos K := if pos K < p then pos K + 1 else pos K
```

For each `K`: if `K`'s old position is below `p`, its new position is one more,
else it stays. A point updated earlier in the same statement doesn't affect
another point: the update is not done one point after another.

The right side can also read the field at other points, and those are old
values too. This was checked: with every `pos` at 1,
`pos K := pos K + pos p` makes every `pos` 2. If the points were updated one
after another, a point updated after `p` would read `p`'s new value, 2, and
become 3.

`retire`, in [Ladder](examples/veil/Ladder.lean), uses this. Every player
ranked below `p` moves up one place, and `rank p` on the right is `p`'s rank
before the line, for every `K`:

```lean
action retire (p : player) {
  require rank p < 3
  rank K := if rank p < rank K then rank K - 1 else rank K
  rank p := 3
}
```

Between statements, the order matters. A later statement sees what an earlier
one wrote. In `win`, from [Ladder](examples/veil/Ladder.lean):

```lean
action win (p : player) (q : player) {
  require rank q < rank p ∧ rank p ≤ rank q + 2
  let place := rank q
  rank K := if place ≤ rank K ∧ rank K < rank p then rank K + 1 else rank K
  rank p := place
}
```

The shift moves `q` down one place, so after it `rank q` is no longer the place
`p` should take. `let place := rank q` keeps it. Writing `rank p := rank q`
instead puts `p` and `q` at the same rank. Writing `rank p := place` before the
shift breaks the shift's condition. The model checker finds both mistakes
through the `ranks_differ` property.

What is allowed and what isn't:

- Allowed: several capitals in one assignment (`lent B M := false`); capitals
  mixed with fixed arguments (`lent B m := false`); any term on the right,
  including `if`, other fields, other points of the same field, and
  quantifiers (`other K := decide (∃ t, taken t ∧ t ≠ K)`).
- Not allowed: the same capital twice on the left (`r X X := true`): error
  `you cannot use the same capitalized identifier more than once`.
- Not allowed: a capital on the right that is not on the left
  (`pos K := pos J`): error `Unknown identifier J`. Use `∀ j, ...` or
  `∃ j, ...` to range over other points.
- A capital name that is already an argument or a field is not "every value":
  Veil warns `this is a point update, not a universal update`. Keep arguments
  in lower case.
- Not possible: setting a function from `Nat` at every point (`f X := 0` with
  `f : Nat → Nat` fails with `Enumeration Nat`). Setting it at one point works.

## Terms

| Write | Meaning | ASCII form that also works |
|---|---|---|
| `a = b`, `a ≠ b` | equal, not equal | `a != b` |
| `a < b`, `a ≤ b`, `a > b`, `a ≥ b` | comparisons (`Nat`) | `<=`, `>=` |
| `a + b`, `a - b`, `a * b`, `a / b`, `a % b` | `Nat` arithmetic | |
| `min a b`, `max a b` | | |
| `c ∧ d`, `c ∨ d`, `¬ c` | and, or, not | `/\`, `\/`, `!c`, `Not c` |
| `c → d`, `c ↔ d` | implies, if and only if | `->`, `<->` |
| `if c then a else b` | a value; `else` is required | |
| `let x := e; t` | names a value inside a term | |
| `∀ s, t`, `∃ s, t` | for every, for some | `forall s, t`, `exists s, t` |
| `∀ (s : spot), t`, `∀ a b : spot, t` | with the type written | |

`and` and `or` as words don't work between terms (`taken s and full` is an
error). `not` works as a function: `not (taken s)`.

Quantifiers range over a type, an enum or `Bool`. Over `Nat` only a bounded
form works: `∀ j, j < 3 → ...` or `∀ j < 3, ...`. An unbounded one, such as
`∃ m : Nat, m = n`, fails with `failed to synthesize ... Decidable`.

To store a condition in a `Bool` field, wrap it in `decide` when it has a
quantifier: `full := decide (∀ t, taken t)`. Without `decide` it fails with
`Application type mismatch ... has type Prop`. A comparison works either way:
`full := parked = 2` and `full := parked == 2` are both fine.

## Properties: `safety` and `invariant`

```lean
safety [one_road_moves] light A ≠ red ∧ light B ≠ red → A = B
safety [some_red] ∃ r, light r = red
invariant [lent_counted] lent B M → loans M > 0
```

- The model checker checks every `safety` and `invariant` in every state it
  reaches. For it, and for the harness, the two words mean the same; a broken
  `invariant` is also reported as `safety_failure`. Use `safety` for what the
  code must guarantee, `invariant` for a helper fact.
- Always give a name in brackets. The name must not be a keyword: `any` and
  `distinct` fail, for example (see [Names to avoid](#names-to-avoid)).
- A capitalised variable in a property means "for every", around the whole
  property. `light A ≠ red ∧ light B ≠ red → A = B` means: for every `A` and
  `B`, if both lights are not red then `A = B`. Beware a negation:
  `¬ (taken S)` means "for every `S`, `S` is not taken", not "some spot is
  not taken". Write `∃ s, ¬ taken s` for that.
- A property made of a relation at a capital and nothing else, such as
  `safety [all_taken] taken S`, fails with `type expected`. Write
  `taken S = true`, or `∀ s, taken s`. With anything around it
  (`taken S ∧ full`, `taken S → parked > 0`) it works.
- The harness's `:sometimes` terms are put in as `safety [sometimes_name] ¬ (term)`.
  Write quantifiers in them explicitly (`∀ s, taken s`), not capitals.

## `Nat` subtraction

`Nat` has no negative numbers. `a - b` is `0` when `b > a`: `0 - 1` is `0`, and
`1 - 2` is `0`. So `parked := parked - 1` at `parked = 0` leaves it at `0`. If
the real code would go below zero, or fail, add a `require` (`require 0 < parked`)
so that the model allows the step only where the code does.
`examples/veil/Lift.lean` (`down` with `express`) relies on this rule.

## Model checking

```lean
#model_check { spot := Fin 3 }
#model_check { book := Fin 2, member := Fin 2 }
#model_check {}
#model_check { spot := Fin 3 } {} (maxDepth := 10)
```

- The first `{ ... }` gives each `type` a size: `spot := Fin 3` is three spots,
  `0`, `1`, `2`. With no types, write `{}`. The harness writes the same from
  `:instance`.
- The second `{}` is for `immutable` fields; leave it empty. It must be there
  when an option such as `(maxDepth := 10)` follows.
- The checker starts from the initial states and tries every action with every
  combination of argument values, breadth first. It checks every property in
  each new state and stops at the first one that fails.
- Small sizes are enough: 2 or 3 of each type. The number of states grows very
  fast with the sizes.
- A `Nat` field that can grow forever makes the search endless: without
  `maxDepth`, `#model_check` never finishes. Bound it with a `require`
  (`require level < 3`), or give `(maxDepth := n)`. The harness always passes
  a depth (`:max-depth`).
- About the depth: measured on this Veil, `#model_check ... (maxDepth := N)`
  checks every state reachable in up to N + 1 steps, and the harness's check
  with `:max-depth N` up to N + 2 steps.
- A state where no action is allowed is fine: no "deadlock" is reported unless
  the file has a `termination` line. Don't write one.

The results:

```
✅ No violation (explored 40 states)
```

This is `examples/veil/Ladder.lean` with `rank p := rank q` in `win` instead
of `rank p := place`:

```
Ladder.lean:55:0: error: ❌ Violation: safety_failure (violates: ranks_differ)
  State 0 (via init):
    rank = {ann ↦ 0, ben ↦ 1, cid ↦ 2, dee ↦ 3}
  State 1 (via win(p=dee, q=cid)):
    rank = {ann ↦ 0, ben ↦ 1, cid ↦ 3, dee ↦ 3}
```

A violation shows the states from the start, and the action and arguments of
each step. A relation prints as a set (`taken = {0, 2}`), a function as a map.
The harness reports the same thing as jank data.

Read every error, not only the last line. An action with an error is dropped,
the rest of the file still elaborates, and `#model_check` can then print `✅`
for a model without that action.

## Errors and what they mean

An error inside an action is reported at the action's first line, as
`Error in action name: ...`. Warnings, such as
`Variable name s is not explicitly referenced` for an argument the action
doesn't use, don't fail the harness: only errors do.

| Message | Usual cause |
|---|---|
| `has no executable definitions: add #gen_executable to it` | no `#gen_executable` after `#gen_spec` (harness only) |
| `Unknown identifier x` | a typo, a field that doesn't exist, or a capital on the right of `:=` that is not on the left |
| `assignment target x is not a mutable state component` | a typo in the field name on the left of `:=` |
| `Type mismatch ... has type Prop ... expected to have type Veil.VeilM` | `=` written for `:=` |
| `mvar(s) exist in the elaborated expression` | a value of the wrong type (`taken s := 1`), or a number used as a value of a `type` (`best := 0`) |
| `type still has mvars after simplification` | `<` between values of a `type` |
| `Application type mismatch ... has type Prop` | a quantified condition stored in a `Bool` without `decide` |
| `unexpected token '}'; expected 'else'` | an `if` term without `else` |
| `unexpected token 'x'; expected identifier` | `x` is a keyword; rename it |
| `unexpected token ')'; expected ':'` | an argument without its type: `(s)` instead of `(s : spot)` |
| `Function expected ... applied to the argument and` | `and` or `or` written as words; use `∧`, `∨` |
| `failed to synthesize instance of type class Enumeration Nat` | an action argument of type `Nat`, or `f X := ...` with `f` from `Nat` |
| `type expected` at a property | the property is only a relation at a capital (`taken S`); write `taken S = true` |
| `failed to synthesize ... Decidable ((veil_term% name) ...)` | property `name` quantifies over `Nat` without a bound |
| `could not extract executable choices for a nondeterministic pick` | `x := *` on a `Nat` field |
| `you cannot use the same capitalized identifier more than once` | `r X X := ...` |
| `unexpected token ':='; expected ')', ',' or ':'` at `#model_check` | an option without the `{}` before it: write `#model_check { spot := Fin 2 } {} (maxDepth := 3)` |
| `x is already declared ... Cannot redeclare it!` | two actions with the same name |
| `no after_init block has been defined` | `after_init` is missing, or had an error |
| `has not been finalized. Please call #gen_spec first!` | `#gen_spec` missing, or an earlier error |
| `This assertion might fail when called from x` | an `assert`; use `require` and `safety` instead |
| `❌ Violation: safety_failure (violates: p)` | the model reaches a state where `p` is false |

## Names to avoid

These failed as field or property names with `expected identifier`. Lean's
keywords: `at`, `break`, `by`, `calc`, `catch`, `continue`, `do`, `else`,
`end`, `exists`, `export`, `finally`, `for`, `from`, `fun`, `have`, `if`,
`import`, `in`, `let`, `local`, `match`, `meta`, `module`, `mut`, `namespace`,
`open`, `private`, `public`, `return`, `section`, `show`, `then`, `try`,
`unless`, `where`, `with`, and the declaration words (`abbrev`, `axiom`,
`class`, `def`, `deriving`, `example`, `instance`, `macro`, `notation`,
`opaque`, `structure`, `syntax`, `theorem`, `universe`). Veil's words:
`action`, `any`, `assert`, `assume`, `distinct`, `enum`, `function`, `ghost`,
`immutable`, `individual`, `instantiate`, `invariant`, `mutable`, `param`,
`pick`, `procedure`, `relation`, `require`, `safety`, `sat`, `termination`,
`theory`, `trace`, `transition`, `type`, `unsat`.

These worked: `state`, `value`, `size`, `count`, `full`, `empty`, `done`,
`id`, `max`, `min`, `index`, `level`, `time`, `mode`, `phase`, `owner`,
`rank`, `order`, `limit`, `total`. When a name fails with `expected
identifier`, add a word to it: `at_floor`, `is_open`.

## Patterns

### A counter

A `Nat` individual, changed by `+ 1` and `- 1`, kept within bounds by
`require`. See `examples/veil/Lift.lean`:

```lean
action step_in {
  require door = opened ∧ riders < 4
  riders := riders + 1
}

action step_out {
  require door = opened ∧ 0 < riders
  riders := riders - 1
}
```

### A set of things

A relation. `taken s := true` adds `s`, `taken s := false` removes it,
`taken s` asks whether it is in, `taken S := false` empties the set. Veil has
no "number of elements"; keep a counter beside the set and change both in
the same action. See `examples/parking.lean` and the `waiting` relation in
`examples/veil/Crossing.lean`. For pairs, use a relation over two types, as
`lent` in `examples/veil/Library.lean`.

### A value per thing

A function. Set it at every point in `after_init` (`loans M := 0`), then at
one point in actions (`loans m := loans m + 1`). See `light` in
`examples/veil/Crossing.lean` and `loans` in `examples/veil/Library.lean`.

### An order that changes: ranks

Keep a rank per thing, a `function rank : player → Nat`, with every rank
different. When one thing moves, shift the ones in between by one, all at
once, with a capitalised variable. Read the old ranks into `let`s first, then
shift, then set the mover's rank. With `a` the mover's old rank and `b` its
new one:

```lean
-- p moves to place q, which is above it (a smaller number).
action move_up (p : player) (q : player) {
  require rank q < rank p
  let a := rank p
  let b := rank q
  rank K := if b ≤ rank K ∧ rank K < a then rank K + 1 else rank K
  rank p := b
}

-- p moves to place q, which is below it (a larger number).
action move_down (p : player) (q : player) {
  require rank p < rank q
  let a := rank p
  let b := rank q
  rank K := if a < rank K ∧ rank K ≤ b then rank K - 1 else rank K
  rank p := b
}

safety [ranks_differ] rank A = rank B → A = B
```

Add the property that no two ranks are equal: the model checker then catches a
shift that is off by one. `examples/veil/Ladder.lean` is a complete model. It
uses an `enum` of players so that `after_init` can give each one a different
rank; a `type`'s values can't be named one by one.

### A fixed order: `TotalOrder`

This Veil has `TotalOrder`: an order on a type that never changes, such as card
numbers or ids. With `member := Fin 3`, it is the order of `0`, `1`, `2`.

```lean
type member
instantiate tot : TotalOrder member
open TotalOrder
```

Then `le a b` means "`a` is at most `b`". From `examples/veil/Library.lean`,
"the member with the lowest card number among those who want the book":

```lean
require ∀ o, wants b o → le m o
```

`TotalOrderWithMinimum` also gives `lt a b` (strictly less), `next a b` (`b`
comes right after `a`) and `zero` (the first value). It suits floors as a
`type`:

```lean
type floor
instantiate ord : TotalOrderWithMinimum floor
open TotalOrderWithMinimum
individual here : floor

after_init {
  here := zero
}

action up (f : floor) {
  require next here f
  here := f
}
```

Use these for an order that is part of the problem and never changes. For an
order that changes as the system runs, use ranks.

## Other things that work

- More than one possible outcome: `x := *` gives `x` any value of its type
  (a `Bool`, an enum, a `type`; not `Nat`), and `let s ← pick spot` picks any
  `spot`. The harness accepts the real state if it matches any of the model's
  outcomes. An argument is easier to match: with `down (express : Bool)` in
  `examples/veil/Lift.lean`, the harness tells your code which case to do.
- `Option` fields, shown above.
- Procedures, shown above.

Not covered here, so keep away from them: `assert`, `immutable`, `param`,
`ghost`, `transition`, `termination`, `assumption`, temporal properties, and
proofs (`#check_invariants`).

## Checklist

- One action per operation of the code, with the same arguments, named in
  lower case, of a `type`, an enum or `Bool`.
- A `require` for each case where the code refuses the operation.
- Every field set in `after_init`; every function set at every point there.
- Every counter bounded by a `require`, or the check given a depth.
- Every property named, with a name that is not a keyword.
- `#gen_spec` alone on its line, then `#gen_executable`.
- No errors in the output, even when the last line says `✅`.
