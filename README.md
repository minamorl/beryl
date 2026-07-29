# Berylx

[![CI](https://github.com/minamorl/berylx/actions/workflows/ci.yml/badge.svg)](https://github.com/minamorl/berylx/actions/workflows/ci.yml)
[![Ruby 3.2+](https://img.shields.io/badge/Ruby-3.2%2B-CC342D.svg)](https://www.ruby-lang.org/)

**Graphable Ruby workflows over focused, recoverable state.**

Berylx gives multi-step business workflows a small algebra without turning Ruby into a DSL:

```ruby
Task : Lay -> Result[Lay]
```

One `Root` owns committed state. Named tasks observe and immutably transform that state through
`Lay`. Every step returns `Ok(lay)` or `Err(partial_lay, error)`, so failures retain enough context
for diagnosis and compensation.

```mermaid
flowchart LR
    R["Root<br/>committed state"] -->|"to_lay"| L["Lay<br/>immutable focused state"]
    L --> A["Task: validate"]
    A -->|"Ok(lay)"| B["Task: charge"]
    B -->|"Ok(final_lay)"| C["Commit to Root"]
    A -->|"Err(partial_lay, error)"| E["Catch / rescue_with"]
    B -->|"Err(partial_lay, error)"| E
    E -->|"recovered Ok(lay)"| N["Continue workflow"]
    E -->|"unhandled or fatal Err"| X["Return Err<br/>Root unchanged"]
```

## Why Berylx?

- **One explicit boundary** — `Root` owns the committed state for a workflow run.
- **Focused immutable updates** — `Lay` reads and replaces nested values without shared mutation.
- **Failures keep their state** — compensation receives the partial `Lay`, not a trail of lost
  locals.
- **Composition stays small** — sequence, branch, parallel, merge, and rescue use Ruby operators and
  values.
- **The workflow is inspectable** — named tasks compile into graph objects and DOT output.

Berylx is in-process workflow composition—not a job queue, durable scheduler, or distributed saga
coordinator.

## Install

```ruby
gem 'berylx'
```

```ruby
require 'berylx'
```

Berylx requires Ruby 3.2 or newer and is tested through Ruby 4.0.

## Execution substrate

The surface API above is all you write. Under it, every workflow runs on a single substrate: the
[darkcore](https://github.com/minamorl/darkcore-ruby) Effect tree (a Freer monad). Berylx compiles
`Task`, sequence, parallel, branch, and rescue into one kind of tagged effect and interprets them
with `Berylx::EffectTree` on darkcore's trampoline. There is no second, native execution path.

Because execution is just an effect tree interpreted by a handler map, cross-cutting aspects (retry,
dry-run, audit) are added by **swapping the handler map** — the workflow itself is never rewritten.
`darkcore` is a required runtime dependency.

Build an aspect with `Berylx::EffectTree.around`, which wraps the real interpreter and passes the
wrapped map down into subtrees, so the aspect also applies inside `parallel`, `branch`, and
`rescue`:

```ruby
timings = Queue.new # parallel branches run on their own threads

handlers = Berylx::EffectTree.around do |tag, payload, inner|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = inner.call(payload)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  timings << [payload.first.name, elapsed] if tag == Berylx::EffectTree::TASK
  result
end

Berylx::EffectTree.run(workflow, Berylx::Lay[], handlers: handlers)
```

The payload is inspectable data: `[node, focus]`. Only the `TASK` tag carries a named task — the
combinator tags carry the `Parallel` / `Branch` / `Rescue` node itself.

Wrapping `real_handlers` by hand does not propagate — the subtrees still run on the unwrapped map —
so build aspects through `around`. Recovery handlers (`rescue_with`, `Catch`) are applied outside
the effect tree, so an aspect observes the body of a rescue but not its recovery.

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

result.focus.to_h
# => { name: 'mina', greeting: 'hello mina' }

root.state
# => { name: 'mina', greeting: 'hello mina' }
```

The whole sequence commits once because it ran as `root | workflow`. If any step returns `Err`, the
root stays at its last committed state while the result keeps the partial `Lay`.

## Failure and recovery at a glance

```ruby
charge = Berylx::Task[:charge] do |lay|
  lay[:charged].set(true).reject(:payment_failed, 'card declined')
end

notify = Berylx::Task[:notify] do |lay|
  lay[:notified].set(true)
end

workflow =
  charge >>
  Berylx::Catch[:record_failure] { |error, lay|
    lay[:failure].set(error.message)
  } >>
  notify

root = Berylx::Root[charged: false]
result = root | workflow

result.focus.to_h
# => { charged: true, failure: "card declined", notified: true }

root.state
# => { charged: true, failure: "card declined", notified: true }
```

Without the `Catch`, the result would be `Err` with `charged: true` in its partial lay, and
`root.state` would remain `{ charged: false }`.

## Tasks that perform effects

A task body that takes a second argument receives a performer. `io.perform(tag, payload)` dispatches
into the handler map the workflow is currently running under, so the body stays straight-line Ruby —
no effect type, no `bind`:

```ruby
load_user = Berylx::Task[:load_user] do |lay, io|
  lay[:user].set(io.perform(:db_query, lay[:id].get))
end

greet = Berylx::Task[:greet] do |lay|
  lay[:greeting].set("hello #{lay[:user].get[:name]}")
end

workflow = load_user >> greet
```

Supply the vocabulary when you run it. The same workflow runs against a real database or against
fixed values, and the workflow itself never changes:

```ruby
real = Berylx::EffectTree.real_handlers(db_query: ->(id) { DB.fetch_user(id) })
Berylx::Root[id: 7].call(workflow, handlers: real)

fixed = Berylx::EffectTree.real_handlers(db_query: ->(_id) { { name: 'mina' } })
Berylx::Root[id: 7].call(workflow, handlers: fixed).focus.to_h[:greeting]
# => "hello mina"   (no database, no mocks, deterministic)
```

An unhandled tag raises `KeyError` rather than returning `nil`, so "the effect never ran" is never
confused with "the effect returned nothing". Effects performed from task bodies also pass through
`around`, so an audit or timing aspect observes them.

## Documentation

| Guide                                         | What it covers                                                                            |
| --------------------------------------------- | ----------------------------------------------------------------------------------------- |
| [Root and Lay](docs/root-and-lay.md)          | State ownership, focus operations, commits, standalone lays, and subscriptions            |
| [Composing workflows](docs/workflows.md)      | Tasks, sequencing, branching, parallel execution, reducers, and graphs                    |
| [Errors and recovery](docs/error-handling.md) | Domain failures, raised exceptions, partial state, Catch, scoped rescue, and fatal errors |

## When to use Berylx

Berylx fits checkout, onboarding, provisioning, API orchestration, and local saga-style flows where
steps have names, partial progress matters, and recovery should be visible in the workflow.

For a single method call or transaction, plain Ruby is probably clearer. For work that must survive
process restarts, use a durable workflow engine.

## License

MIT.
