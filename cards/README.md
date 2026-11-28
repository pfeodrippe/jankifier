# cards

A window that follows a jank REPL: each evaluation becomes a card, drawn by
what its value is. Dear ImGui, from
[jank-lang/commons](https://github.com/jank-lang/commons). The process is the
REPL (jank's nREPL server), so there is nothing to call: connect an editor, or
an agent with an nREPL client, and the window shows what either evaluates.

The mechanism comes from determinismo's `jank-viz`; this is the part of it
that isn't about determinismo, with ways for a project to add its own cards.
`inkling/viz` is a project built on it.

```sh
./cards.sh                                  # the window; its nREPL port in .nrepl-port
./cards.sh --hidden --scale 2               # drawn as a Retina screen draws (for pictures, videos)
./cards.sh --hidden --record take.mp4       # no window: its frames to a video
```

`tutorial.jank` goes through all of the below a form at a time: read and
evaluate it in the REPL.

Connect once the window is open. `lein run` first starts a bare `jank` to
check the executable, and that process serves a REPL of its own and writes
`.nrepl-port` too; the window's REPL writes the file again when it starts.

## How a value is drawn

| Value | Card |
|---|---|
| text, or anything not below | as it prints, in lines |
| a map of plain values | its keys and values |
| a sequence of such maps | a table (the first 12 rows) |
| a sequence of numbers, or `{:shape [n] :values [...]}` | bars with their values up to 48, a series beyond; the value under the mouse is named |
| `{:shape [rows cols] :values [...]}` (with `:name`, `:row-labels`, `:row-name`, `:column-name`), or rows of numbers | a heat map, blue above zero and red below; the cell under the mouse is named |
| an atom | what it holds now, drawn as above |
| nil, a function | none |

The newest card is last and whole; older ones roll up, and the mouse wheel
looks back. `(c/show "name" value)` puts a value on a card and returns nil, for
a value too long to print in the editor; `(c/clear!)` removes the cards.

## A value saying how it is drawn

```clojure
(require '[cards.core :as c])
```

**Metadata.** A value's own metadata chooses its kind of card and its title:

```clojure
(with-meta rows {:cards/view :table :cards/title "tensors"})
(c/as :table "tensors" rows)               ; the same
```

**Layouts.** A layout is data: nodes around any values, each value drawn by
its own kind of card.

```clojure
[:row {:widths [1 2]}
 [:col [:text {:size :big :color :blue} "Next"]
       [:text "wrapped text"]
       (fn [] (current-state))]             ; called when the card is made
 {:shape [24 13] :values weights}]
```

| Node | |
|---|---|
| `[:col & parts]` | one under the other |
| `[:row & parts]`, `[:row {:widths [2 1]} a b]` | side by side, the width shared equally or by weights |
| `[:text "..."]`, `[:text {:size :big :color :red} "..."]` | sizes `:small :mono :big :serif :title`; colours `:ink :muted :red :green :blue :orange :purple` |
| `[:space points]` | room |
| `[:draw height (fn [x y width] ...)]` | drawing of one's own, with the primitives below |
| a function of no arguments | called when the card is made; what it returns (a value or a tree) is drawn in its place |
| anything else | a value, drawn by its kind |

A vector that starts with a node's keyword is a layout wherever it is
evaluated; `(c/layout tree)` marks any other vector as one.

**Handlers.** A handler is a map saying how the values it matches are drawn.

```clojure
;; By an attribute: a key of the value's metadata, or a key of a map.
(c/handle! {:attr :dtype
            :render (fn [tensor] [:row [:text {:size :big} (:name tensor)] (:shape tensor)])})

;; The attribute must equal something.
(c/handle! {:attr :kind :equals :route
            :render (fn [route] [:text (str "to expert " (:expert route))])})

;; By a filter: any function of the value, so any data can be matched.
(c/handle! {:id :long-text
            :filter (fn [v] (and (string? v) (> (count v) 500)))
            :render (fn [text] [:text {:size :small} text])})

;; Painting the card itself instead of returning data.
(c/handle! {:attr :rgb
            :height (fn [v width] 40)
            :draw (fn [v x y width] (c/rect! x y (+ x width) (+ y 32) (:rgb v) 1.0 6.0))})

(c/unhandle! :dtype)
```

| Key | |
|---|---|
| `:attr` | a keyword the value has, in its metadata or, for a map, among its keys |
| `:equals` | what that attribute must equal (without it: be there, and not false) |
| `:filter` | `(fn [value])` returning true for the values to draw; with `:attr`, both must hold |
| `:render` | `(fn [value])` returning what is drawn in the value's place: a value or a layout. Called once when the card is made |
| `:draw`, `:height` | `(fn [value x y width])` and `(fn [value width])`: paint the card with the primitives, every frame |
| `:id` | its name: registering the same id again replaces the handler. Without it, the `:attr` (or `[attr equals]`); a handler with no `:attr` needs one |

The newest handler is asked first. A handler's functions get the value itself:
an attribute that is in its metadata is read with `(c/attr-of value :rgb)`.
Drawing that throws is said in its card, in red, and the other cards are
drawn as usual. A card whose `:draw` handler was removed shows its value as
it prints.

## ImGui itself

A draw function (a `[:draw ...]` node, a handler's or a kind's `:draw`, a
header's) runs inside the window's ImGui frame, in a window that covers
everything. So it can call anything of ImGui's through jank's C++ interop,
next to the library's primitives. `(c/cursor! x y)` says where ImGui's next
widget goes.

```clojure
(def clicks (atom 0))

[:draw 60 (fn [x y width]
            (c/cursor! x y)
            (when (cpp/ImGui.Button "Count a click")        ; widgets answer as anywhere
              (swap! clicks inc))
            (c/text! (+ x 130) (+ y 4) c/ink c/mono (str @clicks " clicks"))
            (c/cursor! x (+ y 30))
            (cpp/ImGui.ProgressBar 0.6 (cpp/ImVec2 300.0 18.0)))]

;; A widget that keeps its state through a pointer: a native value in a box.
(def level (cpp/box (cpp/new cpp/float 0.25)))

[:draw 30 (fn [x y width]
            (c/cursor! x y)
            (cpp/ImGui.SetNextItemWidth 300.0)
            (cpp/ImGui.SliderFloat "level" (cpp/unbox (:* float) level) 0.0 1.0))]

(cpp/* (cpp/unbox (:* float) level))                        ; where the slider is
```

Tried this way: `Text`, `SmallButton`, `Button`, `ProgressBar`, `Checkbox`
and `SliderFloat`, the last three answering clicks.

`cards.core` includes ImGui's header, so its names are there in the REPL (the
tutorial's namespace includes nothing). A namespace of one's own can include
it itself: `(ns my.cards (:include "imgui.h") ...)`.

## Pinned cards

A pinned card stays first while the others scroll under it. Pinning the same
name again replaces it in place.

```clojure
(c/pin! "summary" {:done 3 :of 10})                        ; a value

(def progress (atom {:done 0 :of 100}))                    ; an atom: the card follows it
(c/pin! "progress" progress
        (fn [p] [:text {:size :big} (str (:done p) " of " (:of p))]))
(future (dotimes [i 100] (work!) (swap! progress update :done inc)))

(c/pin! "next" (fn [] (expensive-read)))                   ; a function: called again after every evaluation
(c/unpin! "progress")
```

The window looks at a pinned atom every frame and makes its card again when it
holds another value, whoever changed it; nothing is called. A pinned function
is called on the REPL's thread (now, after each evaluation, and at
`(c/refresh!)`), for what only that thread may read.

## A project's own cards

```clojure
(c/defview! :my/kind
  {:shape  (fn [value] (when (mine? value) {:rows (summarize value)}))   ; REPL's thread
   :height (fn [card width] (* 22 (count (:rows card))))                 ; main thread, every frame
   :draw   (fn [card x y width] ...)})

(c/header! {:height (fn [width] 120) :draw (fn [x y width] ...)})        ; above the cards
(c/overlay! {:shown? (fn [] @open) :draw (fn [width height] ...)})       ; over everything: a modal
(c/on-evaluation! (fn [code value error] ...))                           ; after each evaluation
```

While an overlay is shown, what is under it doesn't answer the mouse.
`(c/escape?)` says whether Esc was pressed in the frame.

A kind defined later is asked first. A card holds plain data: it is made on
the REPL's thread and drawn on the main one. Thousands of numbers go to the
native side once (`c/array!`) and are drawn from there (`c/heat!`,
`c/series!`).

Numbers that change every frame (a scope, a spectrum) stay in C++ memory and
are drawn from there in one call: `cards::polyline_of(values, n, x, y, w, h,
lo, hi, color, thickness)` (a line, anti-aliased) and `cards::area_of(values,
n, x, y, w, h, lo, hi, top, bottom)` (the area under it, `top` fading to
`bottom`), with colours from `cards::color(rgb, alpha)`. A C++ helper of one's
own calls them, or jank through its interop (`cpp/cards.polyline_of`).

Drawing is in points from the window's top left: `text!`, `text-width`,
`line!`, `curve!`, `rect!`, `frame!`, `circle!`, `ring!`, `triangle!`,
`gradient!`, `clip-begin!`, `clip-end!`, `cursor!`, `mouse-x`, `mouse-y`, `wheel`,
`inside?`, `clicked?` (a rectangle of the drawing that answers the mouse),
`seconds`; `clip` and `wrap` cut text to a width; `fixed` and `said` print numbers; `build`, `height-of` and
`draw-built!` place values and layouts inside a `:draw` function. A draw
function evaluated again is used by the next frame.

To use it in a project (see `inkling/viz`):

```clojure
;; project.clj
:dependencies [[io.github.pfeodrippe/cards "0.1.0-SNAPSHOT"]]   ; from Clojars
:main my.viz.main

;; src/my/viz/main.jank
(ns my.viz.main
  (:require [cards.main :as main] [my.cards]))             ; my.cards defines the kinds
(defn -main [& args]
  (main/run! (assoc (main/options args) :title "mine")))
```

## Pictures and video

`(cards.core/snapshot! "frame.ppm")` writes the next frame as an image. An
agent checking its own drawing starts the window with `--hidden` and takes
snapshots: that is how this library was tested. `--record a.mp4` writes the
frames to a video, 30 a second (needs `ffmpeg`); the first frame's wall-clock
time is printed as `[cards] capture <ms>`, to align the video with another
recording.

For a script that drives the REPL (a test, a video's take):

| | |
|---|---|
| `--announce`, `(c/announce! true)` | each evaluation said on stderr as `[cards] evaluated <n>`, with ` error` when it threw |
| `(c/evaluations)` | how many evaluations the window was told of |
| `(c/pointer! x y)`, `(c/click! x y)`, `(c/button! held)`, `(c/wheel! amount)`, `(c/pointer-off!)` | a scripted mouse, drawn as an arrow: what is under it answers as to a real one (the value under the cursor, ImGui's widgets, `clicked?`). For a hidden window; a window in front follows the real mouse |
| `(c/newest-box)` | where the newest card's body was drawn, to point at something in it |

The two tutorial videos (this library's and inkling's) were made this way:
Emacs driven in a terminal on the left, the hidden window recording itself on
the right. The scripts are in `~/Documents/jankifier/takes` (`take.py`).

Not tried here: snapshots of a visible window, and the real mouse (the wheel,
the value under the cursor): the scripted one was.

## The REPL's evaluation

Loading the window (`cards.main`, or `cards.repl` alone, which needs no
window) replaces jank's nREPL eval operation with the same one, changed in two
ways. Both are for a process that does more than one thing at a time, and both
were found by running into them:

- **A large stack.** jank's nREPL evaluates on threads with the system's
  default stack for a thread that is not the first: 512 KB on macOS. jank's
  compiled frames are large, so a function calling itself thirty deep
  overflows it: `(fib 30)` evaluated from an editor ended the process
  (SIGBUS), while `jank run` computed it. Evaluations now run on a thread with
  a 256 MB stack (`cards.repl/stack-megabytes`), its memory taken only as it
  is used. `(cards.repl/on-big-stack f)` does the same for any function.
- **Output captured safely.** jank captures an evaluation's output by pointing
  the process's stdout and stderr at a file for its time and back afterwards.
  Two evaluations that overlap without one being inside the other (two
  editors, a person and an agent) restore in the wrong order, and the process
  is left writing to a file that is gone. The captures in progress are now
  kept together: when one ends, output goes to the newest one still going, or
  back to where it went before any.

Everything else of the operation is jank's own.

## Needs

`lein`, `jank`, `bb`, `cmake`, `glfw` (Homebrew). The first start compiles
Dear ImGui's packages; `cards.sh` sets what that needs on macOS (the Command
Line Tools' compiler, C++17, no build sandbox). The fonts are macOS's Menlo
and Georgia.
