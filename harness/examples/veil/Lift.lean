import Veil

/-!
# A lift

A lift in a building with floors 0 to 3. It moves only with its door closed
and carries at most 4 people. An express trip goes down two floors at once.

Shows: counters kept within bounds (`level`, `riders`), an enum, `Nat`
subtraction, an action with a `Bool` argument, and an `if` statement.
-/

veil module Lift

enum door_t = { opened, closed }

-- The floor the lift is at, and how many people are in it.
individual level : Nat
individual riders : Nat
individual door : door_t

#gen_state

after_init {
  level := 0
  riders := 0
  door := closed
}

action up {
  require door = closed ∧ level < 3
  level := level + 1
}

-- From floor 1, an express trip ends at floor 0: `1 - 2` is 0 for a `Nat`.
action down (express : Bool) {
  require door = closed ∧ 0 < level
  if express then
    level := level - 2
  else
    level := level - 1
}

action open_door {
  require door = closed
  door := opened
}

action close_door {
  require door = opened
  door := closed
}

action step_in {
  require door = opened ∧ riders < 4
  riders := riders + 1
}

action step_out {
  require door = opened ∧ 0 < riders
  riders := riders - 1
}

safety [in_building] level ≤ 3
safety [not_overfull] riders ≤ 4

#gen_spec

-- The harness needs this line: it builds the model's executable definitions.
#gen_executable

-- The model has no `type`, so the instance is empty. 40 states.
#model_check {}

end Lift
