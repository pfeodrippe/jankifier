import Veil

/-!
# A parking lot

The Veil model of examples/parking.jank: spots are taken and left; a spot is
taken by one car at a time, and `parked` counts the cars. harness.verify checks
the jank code against it (VERIFY.md).
-/

veil module ParkingLot

type spot
relation taken : spot → Bool
individual parked : Nat

#gen_state

after_init {
  taken S := false
  parked := 0
}

action park (s : spot) {
  require ¬ taken s
  taken s := true
  parked := parked + 1
}

action leave (s : spot) {
  require taken s
  taken s := false
  parked := parked - 1
}

safety [a_car_a_spot] parked ≤ 2

#gen_spec

#gen_executable

-- Checked with two spots (harness.verify checks it the same way, from the jank file).
#model_check { spot := Fin 2 }

end ParkingLot
