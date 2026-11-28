- [x] macros
- [x] play mario
- [x] clj-kondo
- [ ] supercollider
  - [x] sys
  - [x] cpp play
  - [x] viz
  - [ ] autocompletion and stuff
    - [x] autocompletion
    - [ ] pretty print
  - [ ] jank api (overtone-like? guess lower-level)
  - [ ] effects
- [ ] run tests from the repl

## Jank improvements

- [ ] plain defmethod currently fails outside clojure.core, it calls the private defmethod*
  - this happens only when there isn't a associated file path
- [ ] nrepl (at least from the cider PoV)
  - [ ] startup hook so people can add their own plugins/middleware
  - [ ] no autocompletion
  - [ ] no test run
- [ ] outside the REPL (e.g. running tests), printing an exception or calling Throwable->map on one segfaults
- [ ] ex-message on a non-exception throws in jank, Clojure returns nil
