# Jankifier

NOTE This README and the user APIs are designed by me, but the code is LLM-aided
, so take it more as an API exercise.

My own utils (here Paulo) for jank so I can write more jank than C++, no deps (other than
jank ofc) and also so I can have convenient dev-environment, e.g. extend jank nrepl ops
so I can do proper autocompletion or call tests from nrepl \o

Most of the things here will likely be, in the future, deprecated
as some form may be supported officialy from jank, this is just useful for what
I want to build and also to show that jank (like clj) allow us to do whatever we
need to do (even if with some non-pretty macros).

And when you have some macro error, it will be horrible! As we basically just
concatenate strings for cpp/raw usage.

## How to use it

Git submodule it into your project (on your own peril) and use it.

## TODOs

I also own todo.md for some jank improvements or for what I want next o/

## Example

### C++ (flecs)

```cpp
#include <flecs.h>
#include <cstdio>

struct Position { double x, y; };
struct Velocity { double x, y; };

int main(int, char *[])
{
  flecs::world world;

  // The Move system: moves each entity by its velocity.
  world.system<Position, Velocity const>("Move")
    .each([](Position &p, Velocity const &v)
          {
            p.x += v.x;
            p.y += v.y;
          });

  flecs::entity bob = world.entity("Bob");

  // We set bob position using the C++ api ...
  bob.set(Position{ 10.0, 20.0 });

  // ... but the C API works as well. In C++, the 3 lines below would be
  // simply bob.set(Velocity{ 1.0, 2.0 });
  ecs_world_t *w_ptr = world.c_ptr();
  ecs_entity_t velocity_comp = world.component<Velocity>().id();
  ecs_size_t size = ecs_get_type_info(w_ptr, velocity_comp)->size;
  Velocity velocity{ 1.0, 2.0 };
  ecs_set_id(w_ptr, bob.id(), velocity_comp, size, &velocity);

  for(int i = 0; i < 5; i++)
  {
    world.progress();
    Position const &position = bob.get<Position>();
    std::printf("%s %g %g\n", bob.name().c_str(), position.x, position.y);
  }
}
```

### jank with flecs-sys

```clojure
(ns flecs-sys.example
  (:include "flecs.h"))

(cpp/raw "struct Position { double x, y; };
          struct Velocity { double x, y; };

          void add_move_system(flecs::world &world)
          {
            world.system<Position, Velocity const>(\"Move\")
              .each([](Position &p, Velocity const &v)
                    {
                      p.x += v.x;
                      p.y += v.y;
                    });
          }

          Position const &position_of(flecs::entity e)
          { return e.get<Position>(); }")

(defn -main [& args]
  (let [world (cpp/flecs.world)
        _ (cpp/add_move_system world)

        bob (.entity world "Bob")

        ;; We set bob position using the C++ api ...
        _ (.set bob (cpp/Position 10.0 20.0))

        ;; ... but the C API works as well.
        ;; In cpp, the 3 lines below would be simply (.set bob (cpp/Velocity 1.0 2.0))
        w-ptr (.c_ptr world)
        velocity-comp (.id (#cpp (cpp/flecs.component Velocity) w-ptr))
        size (.-size (cpp/ecs_get_type_info w-ptr velocity-comp))
        _ (cpp/ecs_set_id w-ptr (.id bob) velocity-comp size (cpp/& (cpp/Velocity 1.0 2.0)))]
    (dotimes [_ 5]
      (.progress world)
      (let [position (cpp/position_of bob)]
        (println (format "{} {} {}" (.c_str (.name bob)) (.-x position) (.-y position)))))))
```

### jank with flecs-sys and jankifier

```clojure
(ns flecs-sys.example
  (:include "flecs.h")
  (:require [jankifier.core :refer [cpp-cast cpp-fn cpp-type defcfn defcstruct]]))

(defcstruct Position
  [[:x :f64]
   [:y :f64]])

(defcstruct Velocity
  [[:x :f64]
   [:y :f64]])

(defcfn move :void
  "The Move system: moves each entity by its velocity."
  [[p [:& Position]]
   [v [:& [:const Velocity]]]]
  (cpp/= (.-x p) (+ (:x p) (:x v)))
  (cpp/= (.-y p) (+ (:y p) (:y v))))

(defn -main [& args]
  (let [world (cpp/flecs.world)
        w-ptr (.c_ptr world)

        ;; world.system<Position, Velocity const>("Move").each(move)
        _ (-> ((cpp-type (flecs.system_builder Position [:const Velocity])) w-ptr "Move")
              (.each (cpp-fn move)))

        bob (.entity world "Bob")

        ;; We set bob position using the C++ api ...
        _ (.set bob (Position {:x 10.0 :y 20.0}))

        ;; ... but the C API works as well.
        ;; In C++, the 3 lines below would be simply bob.set(Velocity{1.0, 2.0})
        velocity-comp (-> ((cpp-type (flecs.component Velocity)) w-ptr) .id)
        size (-> (cpp/ecs_get_type_info w-ptr velocity-comp) .-size)
        _ (cpp/ecs_set_id w-ptr (.id bob) velocity-comp size (cpp/& (Velocity {:x 1.0 :y 2.0})))
        position-comp (-> ((cpp-type (flecs.component Position)) w-ptr) .id)]
    (dotimes [_ 5]
      (.progress world)
      (let [position (->> (cpp/ecs_get_mut_id w-ptr (.id bob) position-comp)
                          (cpp-cast [:* Position]))]
        (println (format "{} {} {}" (.c_str (.name bob)) (:x position) (:y position)))))))
```
