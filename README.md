# Berylx

[![CI](https://github.com/minamorl/berylx/actions/workflows/ci.yml/badge.svg)](https://github.com/minamorl/berylx/actions/workflows/ci.yml)
[![Ruby 3.2+](https://img.shields.io/badge/Ruby-3.2%2B-CC342D.svg)](https://www.ruby-lang.org/)

**Failures carry the state they reached.**

Every step in a berylx workflow returns `Ok(lay)` or `Err(partial_lay, error)`. When a step fails,
the error envelope holds the exact immutable state the workflow had produced up to that point — so
compensation is written against data you actually have, not against a trail of lost locals:

```ruby
charge = Berylx::Task[:charge] do |lay|
  lay[:charged].set(true).reject(:payment_failed, 'card declined')
end

refund = Berylx::Catch[:refund] do |error, lay|
  # `lay` is the partial state at the failure: charged is already true here,
  # so the compensation knows a refund is actually owed.
  lay[:refunded].set(error.message)
end

notify = Berylx::Task[:notify] { |lay| lay[:notified].set(true) }

workflow = charge >> refund >> notify

root = Berylx::Root[charged: false]
result = root | workflow

result.focus.to_h # => { charged: true, refunded: "card declined", notified: true }
root.state        # => committed only because the workflow recovered to Ok
```

Without the `Catch`, the run returns `Err` with `charged: true` in its partial lay while
`root.state` stays at the last committed state — failure state remains available as data without
silently becoming committed application state.

The rest of the gem exists to make that guarantee compositional:

```ruby
Task : Lay -> Result[Lay]
```

One `Root` owns committed state. Named tasks observe and immutably transform snapshots of it through
`Lay`. Tasks compose with `>>` (sequence), `&` (parallel), `When`/`Else` (branch), and
`Catch`/`rescue_with` (recovery), and the composed workflow is an inspectable value that compiles to
a graph.

## Laws

The behavioral contract is stated as laws, and every law is enforced by a named test file — if a law
below stops holding, the suite is red. This section is the API contract; read it before generating
code against berylx.

| Law                            | Statement                                                                                                                                                                               | Enforced by                                         |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| **PutGet**                     | `at(lay.at(p).set(v), p).get == v` — a set value reads back at the same path                                                                                                            | `test/lay_lens_laws_test.rb`                        |
| **GetPut**                     | `lay.at(p).set(lay.at(p).get)` is identity on `to_h` (for present keys)                                                                                                                 | `test/lay_lens_laws_test.rb`                        |
| **PutPut**                     | Setting twice at a path keeps only the second value                                                                                                                                     | `test/lay_lens_laws_test.rb`                        |
| **Key presence**               | `{}` and `{ k: nil }` are distinct states: `present?`/strict `get` distinguish them and set/get round-trips never conflate them                                                         | `test/lay_lens_laws_test.rb`                        |
| **Immutability**               | Stored state is deeply frozen; construction takes a defensive copy; a captured lay's `to_h` is value-identical forever; mutation attempts raise `FrozenError`                           | `test/lay_lens_laws_test.rb`                        |
| **Kleisli identity**           | `Task.identity` is a two-sided unit for `>>`                                                                                                                                            | `test/category_laws_test.rb`                        |
| **Associativity**              | `(f >> g) >> h == f >> (g >> h)` — structurally (flattened steps) and semantically, including chains containing `Catch`                                                                 | `test/category_laws_test.rb`                        |
| **Functor law**                | `compile(f >> g)` equals the Kleisli composition of `compile(f)` and `compile(g)`                                                                                                       | `test/category_laws_test.rb`                        |
| **Short-circuit**              | A sequence skips ordinary steps after an `Err`; the partial lay travels in the envelope                                                                                                 | `test/category_laws_test.rb`, `test/berylx_test.rb` |
| **Reducer determinism**        | Parallel results fold in branch **definition order**, never completion order; `Merge.deep` is right-biased and non-commutative; `Merge.strict` diffs against the common parent snapshot | `test/parallel_determinism_test.rb`                 |
| **Recovery is an effect**      | A failing rescue body dispatches `RECOVER` through the current handler map: aspects observe recovery, and recovery bodies can perform effects                                           | `test/recovery_effect_test.rb`                      |
| **KeyError on unhandled tags** | An effect tag with no handler raises `KeyError` — "never ran" is never confused with "returned nothing"                                                                                 | `test/effectful_task_test.rb`                       |

## Replace vs merge — the vocabulary, once

These are distinct operations with distinct laws. Docs and code use them consistently:

- `Lay#set`, `Lay#update`, `Lay#put` — **pure replacement** of the focused value. No merging, ever.
  (`set` returns a new lay refocused at the root; the lens laws above are stated with an explicit
  refocus.)
- `Root#commit(hash)` — **deep-merge** of a plain Hash into committed state. This is the only
  merging write in the gem. Committing a `Lay`, `Root`, `Ok`, or `Err` adopts that value's focus — a
  replacement.
- `Merge.deep` / `Merge.strict` — explicit **reducers** for combining parallel branch results;
  chosen per parallel group, never implicit in `set`.

## Install

```ruby
gem 'berylx'
```

Berylx requires Ruby 3.2 or newer and is tested through Ruby 4.0.
[darkcore](https://github.com/minamorl/darkcore-ruby) is a required runtime dependency.

## Execution substrate

The surface API is all you write. Under it, every workflow runs on a single substrate: the darkcore
Effect tree (a Freer monad). Berylx compiles `Task`, sequence, parallel, branch, and rescue into
tagged effects and interprets them with `Berylx::EffectTree` on darkcore's trampoline. There is no
second, native execution path — a combinator's `#call` delegates to the interpreter, and a bare
`Task#call` is the leaf semantics the interpreter itself invokes.

Because execution is an effect tree interpreted by a handler map, cross-cutting aspects (retry,
dry-run, audit) are added by **swapping the handler map** — the workflow itself is never rewritten:

```ruby
timings = Thread::Queue.new # parallel branches run on their own threads — stay thread-safe

handlers = Berylx::EffectTree.around do |tag, payload, inner|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = inner.call(payload)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  timings << [payload.first.name, elapsed] if tag == Berylx::EffectTree::TASK
  result
end

Berylx::EffectTree.run(workflow, Berylx::Lay[], handlers: handlers)
```

`around` passes the wrapped map down into subtrees, so the aspect also applies inside `parallel`,
`branch`, and `rescue`. Recovery is itself an effect: when a body fails, a `RECOVER` effect is
dispatched through the current handler map, so an aspect observes the body of a rescue, the recovery
itself, and any effects performed inside the recovery. Wrapping `real_handlers` by hand does not
propagate — build aspects through `around`.

## Quick start

Define named state transitions, compose them first, then run the complete workflow from the root:

```ruby
strip_name = Berylx::Task[:strip_name] do |lay|
  lay[:name].update(&:strip)
end

greet = Berylx::Task[:greet] do |lay|
  lay[:greeting].set("hello #{lay[:name].get}")
end

workflow = strip_name >> greet
root = Berylx::Root[name: '  mina  ']
result = root | workflow

result.focus.to_h # => { name: 'mina', greeting: 'hello mina' }
root.state        # => { name: 'mina', greeting: 'hello mina' }
```

The whole sequence commits once because it ran as `root | workflow`. If any step returns `Err`, the
root stays at its last committed state while the result keeps the partial `Lay`.

## Tasks that perform effects

A task body that takes a second argument receives a performer. `io.perform(tag, payload)` dispatches
into the handler map the workflow is currently running under, so the body stays straight-line Ruby —
no effect type, no `bind`:

```ruby
load_user = Berylx::Task[:load_user] do |lay, io|
  lay[:user].set(io.perform(:db_query, lay[:id].get))
end
```

Supply the vocabulary when you run it. The same workflow runs against a real database or against
fixed values, and the workflow itself never changes:

```ruby
real = Berylx::EffectTree.real_handlers(db_query: ->(id) { DB.fetch_user(id) })
Berylx::Root[id: 7].call(workflow, handlers: real)

fixed = Berylx::EffectTree.real_handlers(db_query: ->(_id) { { name: 'mina' } })
Berylx::Root[id: 7].call(workflow, handlers: fixed) # no database, no mocks, deterministic
```

An unhandled tag raises `KeyError` rather than returning `nil`. Effects performed from task bodies
and from recovery bodies pass through `around`, so an audit or timing aspect observes them.

## Documentation

| Guide                                         | What it covers                                                                             |
| --------------------------------------------- | ------------------------------------------------------------------------------------------ |
| [Root and Lay](docs/root-and-lay.md)          | State ownership, focus operations, immutability, commits, standalone lays, subscriptions   |
| [Composing workflows](docs/workflows.md)      | Tasks, sequencing, branching, parallel execution, reducers, thread-safety, graphs          |
| [Errors and recovery](docs/error-handling.md) | Domain failures, raised exceptions, partial state, Catch scoping, rescue, and fatal errors |

## Scope

Berylx is in-process workflow composition — not a job queue, durable scheduler, or distributed saga
coordinator. It fits checkout, onboarding, provisioning, API orchestration, and local saga-style
flows where steps have names, partial progress matters, and recovery should be visible in the
workflow. For work that must survive process restarts, use a durable workflow engine.

## License

MIT.
