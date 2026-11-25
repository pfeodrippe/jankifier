# The namespace docstring of `elle.closed-predicate`

Lines 1 to 95 of `closed_predicate.clj` (Elle, under its license, `LICENSE`), as they are:

```clojure
(ns elle.closed-predicate
  "A test for predicate safety. Uses a closed-universe assumption to
  infer the version set selected for transactions based not only on what the
  predicate matches, but based on what it *doesn't* match.

  In Adya's formalism, predicate dependencies cover the versions a transaction
  reads/writes which match the predicate. However, any read or write of these
  versions also appears as a non-predicate read or write in the history: these
  are *item* dependencies. But predicate dependencies *also* cover versions a
  transaction does *not* read or write. Indeed, any predicate operation a
  transaction performs captures a 'Version Set' (vset) including some version
  of (basically) every object in the database. Even unborn and dead ones. How
  are we going to infer these additional predicate dependencies, given they
  cover records which do not match the predicate, and hence do not appear in
  the transaction itself?

  How do you take a photograph of something invisible?

  Let us assume that we know every version of some object x. Let us then assume
  there are at most *two* versions of x: x0, x1. Now assume we have a predicate
  transaction which performs a predicate read covering x, and it reads nothing:

    T1: r(VSet(P))

  Now evaluate P(x0) and P(x1) to see whether those versions match the
  predicate. Note that unborn and dead versions do not match predicates. There
  are four possible cases:

  1. Both x0 and x1 match. *Any* choice of VSet(P) should have returned
  something. This is illegal; something is terribly wrong in the DB.

  2. x0 matches, x1 doesn't. VSet(P) must have selected x1.

  3. x1 matches, x0 doesn't. VSet(P) must have selected x0.

  4. Neither match. We cannot tell which VSet(P) chose.

  This allows us to infer a subset of VSet(P) *even when values are unread*.
  From this we can infer the additional dependency edges in the Adya formalism!

  ## Predicates

  We need a structure to describe a predicate. These are:

  :true. The trivial predicate, which matches everything. This is still
  useful--predicates never match unborn or dead versions.

  [:= 2]. Matches every object whose value which is equal to 2.

  [:mod 2 0] Matches every object whose value, modulo two, is zero.

  ## Operations

  We perform an initial *universe-constructing* operation which establishes the
  state of the universe. We're trusting the database positively, definitely has
  this state--perhaps by writing it to a healthy cluster, waiting, and reading
  the state back on every replica to ensure it's definitively present. We
  choose to believe that the database will not return prior (e.g. unborn)
  states. The value for this operation is a map of keys (e.g. :x) to initial
  versions (e.g. 1).

    {:f :init, :value {:x 1, :y 2, ...}}

  Then we perform transactions whose values are (as usual) sequences of
  micro-operations:

    {:f :txn, :value [mop1, mop2, ...]}

  These micro-operations are of the following forms:

    [:insert :x 1]

  Inserts key x with value 1.

    [:delete :x]

  Deletes key x.

    [:w :x 2]

  Sets x's value to 2.

    [:r :x 2]

  A normal object read of key :x, observing version 2.

    [:rp :true {:x 1, :y 2}]

  A predicate read. The predicate :true matches everything. This read observed
  key x's value as 1 and key y's value as 2.

  ## Representations

  We represent the unborn version as :elle/unborn, and the dead version as
  :elle/dead."
```
