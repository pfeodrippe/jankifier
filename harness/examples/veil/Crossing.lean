import Veil

/-!
# Traffic lights at a crossing

Two roads cross. Each has a light: red, amber or green. Cars arrive and wait
at a red light. A light turns green only when every other light is red and a
car waits there. A power cut turns every light red and forgets who waited.

Shows: enums, a value per thing (`light`), a set of things (`waiting`), `∀`
and `∃` in a `require` and in properties, assignments to every point at once.
-/

veil module Crossing

enum road = { north_south, east_west }
enum colour = { red, amber, green }

function light : road → colour
relation waiting : road → Bool

#gen_state

after_init {
  light R := red
  waiting R := false
}

action arrive (r : road) {
  require light r = red
  waiting r := true
}

action go (r : road) {
  require light r = red ∧ waiting r
  require ∀ o, o ≠ r → light o = red
  light r := green
  waiting r := false
}

action slow (r : road) {
  require light r = green
  light r := amber
}

action stop (r : road) {
  require light r = amber
  light r := red
}

action power_cut {
  light R := red
  waiting R := false
}

-- `A` and `B` stand for every pair of roads.
safety [one_road_moves] light A ≠ red ∧ light B ≠ red → A = B
safety [some_red] ∃ r, light r = red
safety [no_wait_on_green] light R = green → ¬ waiting R

#gen_spec
#gen_executable

#model_check {}

end Crossing
