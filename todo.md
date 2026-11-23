- [x] macros
- [ ] play mario
  - [ ] a decision API in inkling (as TypeSafe's Jev): a typed question (a choice among options, yes/no, a score) answered from one forward pass by the options' logits, with their probabilities, reusing the session's cache between steps
  - [ ] its calibration measured on questions with known answers
  - [ ] an NES emulator in the process (a libretro core, fceumm, behind a small C++ frontend): frames stepped, the controller set, RAM read, the picture shown in a card
  - [ ] Super Mario Bros. through it (the ROM from the user): the state decoded from RAM every few frames, the action chosen by the decision API; compare with Jev's World 1-1 in 356 decisions
  - [ ] a turn-based puzzle too, where each move takes reasoning
- [ ] play doom: ViZDoom (a Doom engine made for programs to play it: the player's state, the objects in view with their positions, the map) with Freedoom's free game data, in the process through its C++ API; a level's state as text every few tics, the action chosen by the decision API
- [ ] play nethack: the NetHack Learning Environment's C core (the 24x80 screen, the messages, the player's stats, the inventory), in the process; turn-based, so each move can take a real decision
- [ ] autocompletion and stuff
  - I start a nrepl from core-test, but unable to run tests or check autocompletion
  - [ ] autocompletion
  - [ ] run tests from the repl
- [ ] clj-kondo
- [ ] kaocha can be used here ? guess not, but it's a hell of a test runner and it should be possible to have something like it

## Jank improvements

- [ ] plain defmethod currently fails outside clojure.core, it calls the private defmethod*
  - this happens only when there isn't a associated file path
- [ ] nrepl (at least from the cider PoV)
  - [ ] startup hook so people can add their own plugins/middleware
  - [ ] no autocompletion
  - [ ] no test run
- [ ] outside the REPL (e.g. running tests), printing an exception or calling Throwable->map on one segfaults
- [ ] ex-message on a non-exception throws in jank, Clojure returns nil

## Inkling, after the trials (the GPU is theirs until then)

- [ ] split attention measured alone (2k, 4k, 8k, 20k, 49k tokens of context), a threshold chosen, on by default, tokens/s of a real turn
- [ ] a full agent turn profiled
- [ ] other exact speedups: experts grouped for prefill, speculative decoding, batching
- [ ] context trimming, only if the trials show it does no harm
- [ ] proofs of the engine (inkling/specs): split attention, pool and stream for any size, the router, the session API (in progress)
- [ ] engine bugs the proofs found (fix after the trials: the trials load the engine):
  - [ ] ban_experts takes more than experts - k bans, and then the router chooses banned experts with a normal weight (shown: 121 of 128 banned at layer 8, every route chose one); refuse more, or give banned experts weight 0
  - [ ] generate! isn't atomic: when the context fills before n tokens, the session keeps the tokens evaluated and the exception loses the ids; check pos + n <= context first, or say so
  - [ ] copy of a session onto itself calls memcpy with the same source and destination (undefined behaviour)
  - [ ] eval's id check uses the padded vocabulary (201,024), not the real one (200,058)
- [ ] the harness video

