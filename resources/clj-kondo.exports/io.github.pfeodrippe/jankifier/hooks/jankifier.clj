(ns hooks.jankifier
  "clj-kondo hooks for jankifier's macros. Each expands to plain Clojure
  which clj-kondo can lint like the real expansion: the vars it defines, the
  locals the bodies see, and the struct types it references. The C++ parts
  are left out.")

(defn- split-doc
  "`[doc more]` for `forms` which may start with a docstring."
  [forms]
  (if (string? (first forms))
    [(first forms) (rest forms)]
    [nil forms]))

(defn- local
  "The local a field or argument name (a keyword or symbol) is bound to."
  [n]
  (symbol (name n)))

(defn- position
  "The source position of the form `form`, for a generated symbol standing
  for it, so warnings point at it."
  [form]
  (select-keys (meta form) [:row :col :end-row :end-col]))

(defn- arg-locals
  "The locals of `[[arg type] ...]`, each at its `[arg type]` entry."
  [args]
  (for [arg args]
    (with-meta (local (first arg)) (position arg))))

(defn- types-form
  "A form using every type in `types`, so struct types count as used and
  unknown ones are reported. Keywords and strings are left as they are."
  [types]
  `(do ~@(remove nil? types)))

(defn- fn-body
  "A function `fn-name` taking the locals `locals`, which uses the types of its
  `[[arg type] ...]` `args` and `ret`, then runs `body`."
  [fn-name locals ret args body]
  `(fn ~fn-name [~@locals]
     ~(types-form (cons ret (map second args)))
     ~@body))

(defn- field?
  "Whether the struct member `entry` is an instance field, i.e. not a
  `:const` or `:var` static member."
  [entry]
  (let [props (when (= 3 (count entry)) (second entry))]
    (not (or (contains? props :const) (contains? props :var)))))

(defn- method-locals
  "The fields a struct's methods see: instance fields with keyword types.
  A method doesn't have to use them all, so they're never unused. The ignore
  is placed at the field's own entry, as one without a position would cover
  the whole struct, method bodies included."
  [entries]
  (for [entry entries
        :when (and (field? entry) (keyword? (last entry)))]
    (with-meta (local (first entry))
      (assoc (position entry) :clj-kondo/ignore [:unused-binding]))))

(defmacro defcstruct
  "`(defcstruct Name doc? {attrs}? [members])` defines the macro `Name`,
  called with no arguments or a map of fields. Methods see the instance
  fields with keyword types and their arguments."
  [struct-name & declaration]
  (let [[doc declaration] (split-doc declaration)
        [attrs declaration] (if (map? (first declaration))
                              [(first declaration) (rest declaration)]
                              [nil declaration])
        members (first declaration)
        entries (filter vector? members)
        methods (filter seq? members)
        fields (method-locals entries)]
    `(do
       (defmacro ~struct-name ~@(when doc [doc])
         ([] nil)
         ([~'_fields] nil))
       ~attrs
       ~(types-form (map last entries))
       ~@(for [[_ method-name ret & more] methods
               :let [[_ [args & body]] (split-doc more)]]
           (fn-body method-name (concat fields (arg-locals args)) ret args body)))))

(defmacro defcstructs
  "`(defcstructs [[Name & declaration] ...])`, or a symbol naming a var with
  such a vector, which can only be checked to exist."
  [specs]
  (if (vector? specs)
    `(do ~@(for [spec specs]
             `(jankifier.core/defcstruct ~@spec)))
    specs))

(defn- type-refs
  "The symbols in the type `t` of `cpp-type` and `cpp-cast`, as references.
  They're jank structs, which count as used, or C++ names, which clj-kondo
  can't know, so unresolved ones aren't reported within `t`. A bare symbol
  has no position to scope that to: a dotted one like `flecs.world` is a C++
  name, which is skipped, and any other is referenced as is, so write C++
  types like `int` as keywords (`:i32`) there."
  [t]
  (cond
    (and (symbol? t) (nil? (namespace t)) (some #{\.} (name t))) []
    (symbol? t) [t]
    :else (vec (for [sym (filter symbol? (tree-seq coll? seq t))]
                 (with-meta sym (assoc (position t) :clj-kondo/ignore [:unresolved-symbol]))))))

(defmacro cpp-type
  "`(cpp-type t)` is a C++ type, which can be called to construct it."
  [t]
  `(fn [& ~'_args] ~(type-refs t)))

(defmacro cpp-cast
  "`(cpp-cast t x)` is `x` cast to the C++ type `t`."
  [t x]
  `(let [~'_type ~(type-refs t)] ~x))

(defmacro cpp-fn
  "`(cpp-fn name)` is the C++ function of the `defcfn` `name`."
  [fn-name]
  fn-name)

(defmacro defcfn
  "`(defcfn name ret doc? [[arg type] ...] body...)` defines the macro `name`,
  which calls the C++ function with its arguments."
  [fn-name ret & more]
  (let [[doc [args & body]] (split-doc more)]
    `(do
       (defmacro ~fn-name ~@(when doc [doc]) [& ~'_args] nil)
       ~(fn-body fn-name (arg-locals args) ret args body))))
