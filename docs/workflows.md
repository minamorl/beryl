# Composing workflows

Berylx workflows are named Ruby values that compose into sequences, branches, parallel groups, and
recovery scopes.

## Tasks and sequencing

A task is a named transition from `Lay` to `Result[Lay]`:

```ruby
validate = Berylx::Task[:validate] do |lay|
  lay[:account_id].present? ? lay : lay.reject(:missing_account)
end

load_account = Berylx::Task[:load_account] do |lay|
  lay[:account].set(Account.find(lay[:account_id].get))
end

workflow = validate >> load_account
```

`>>` is short-circuiting. An `Ok` passes its lay to the next task; an `Err` skips ordinary steps
until a matching recovery boundary is reached or the workflow returns.

Run a complete workflow from a committing root:

```ruby
result = root | workflow
```

Or evaluate it from a standalone lay:

```ruby
result = workflow.call(Berylx::Lay[account_id: 42])
```

## Tasks that perform effects

`load_account` above reaches straight for `Account.find`, so the task can only ever run against a
real database. Give the block a second parameter and it receives a performer instead:

```ruby
load_account = Berylx::Task[:load_account] do |lay, io|
  lay[:account].set(io.perform(:find_account, lay[:account_id].get))
end
```

`io.perform(tag, payload)` dispatches into the handler map the workflow is currently running under.
The body stays straight-line Ruby — a tag and plain data, never an effect value and never `bind`.

Supply the vocabulary when you run the workflow:

```ruby
real = Berylx::EffectTree.real_handlers(find_account: ->(id) { Account.find(id) })
root.call(workflow, handlers: real)

fixed = Berylx::EffectTree.real_handlers(find_account: ->(_id) { Account.new(name: 'mina') })
root.call(workflow, handlers: fixed)
```

The workflow is identical in both runs; only the map changed. The second run touches no database and
needs no mocks.

An unhandled tag raises `KeyError` rather than returning `nil`, so "the effect never ran" is never
confused with "the effect returned nothing". Effect tags may not collide with berylx's own tags, and
effects performed from task bodies pass through `EffectTree.around`, so an audit or timing aspect
observes them alongside the tasks themselves.

One-argument task bodies are unaffected and keep taking the existing path.

## Branching

Use `When` and `Else` for predicate-based choice:

```ruby
paid = Berylx::Task[:paid] { |lay| lay[:status].set(:paid) }
trial = Berylx::Task[:trial] { |lay| lay[:status].set(:trial) }

branch =
  (Berylx::When[:paid] { |lay| lay[:plan].get == :paid } >> paid) |
  (Berylx::Else >> trial)

result = branch.call(Berylx::Lay[plan: :paid])
result.focus[:status].get
# => :paid
```

Branch `Else` is a predicate fallback. It is not an error handler; use `Catch` or `rescue_with` for
failures.

## Parallel workflows

`&` starts sibling branches from the same input snapshot. A reducer combines their returned lays:

```ruby
left = Berylx::Task[:left] do |lay|
  lay[:left].set(lay[:base].get + 1)
end

right = Berylx::Task[:right] do |lay|
  lay[:right].set(lay[:base].get + 2)
end

workflow = (left & right).reduce(Berylx::Merge.deep)
result = workflow.call(Berylx::Lay[base: 10])

result.focus.to_h
# => { base: 10, left: 11, right: 12 }
```

Parallel branches never mutate a shared lay. Choose the merge policy explicitly:

| Reducer                    | Behavior                                                                     |
| -------------------------- | ---------------------------------------------------------------------------- |
| `Berylx::Merge.keep_left`  | Keep the accumulated left focus                                              |
| `Berylx::Merge.keep_right` | Keep the right branch focus                                                  |
| `Berylx::Merge.deep`       | Deep-merge hashes; the right value wins scalar conflicts                     |
| `Berylx::Merge.strict`     | Merge independent changes and return `:merge_conflict` for conflicting paths |

### Reducer determinism

The reducer folds branch results in **branch definition order, never completion order**. Each branch
runs on its own thread, but the interpreter joins the threads in the order the branches were
declared and reduces in that same order, so a parallel group is deterministic even when branch
timings vary (pinned in `test/parallel_determinism_test.rb`).

That determinism is what makes the merge policies meaningful:

- `Merge.deep` is **right-biased and non-commutative** — on a scalar conflict the later-declared
  branch wins, deterministically. `left & right` and `right & left` are different workflows.
- `Merge.strict` diffs both sides against the **common parent snapshot** (the lay the parallel group
  started from), not mere key presence. A key initialized to `nil` in the parent and moved to two
  different values by two branches is a `:merge_conflict`; a branch that leaves it at the parent
  value does not conflict with one that changes it.

### Thread-safety of handlers and aspects

Parallel branches run on separate threads, and every branch dispatches through the **same handler
map**. Handler lambdas, `around` wrappers, and anything they close over must therefore be
thread-safe. The norm for collecting observations from an aspect is a `Thread::Queue`:

```ruby
timings = Thread::Queue.new # safe: Queue is thread-safe

handlers = Berylx::EffectTree.around do |tag, payload, inner|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = inner.call(payload)
  timings << [tag, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  result
end
```

A plain shared `Array` is **not safe** — two branches appending concurrently can lose or interleave
writes:

```ruby
timings = [] # unsafe: Array#<< is not atomic across threads
handlers = Berylx::EffectTree.around do |tag, payload, inner|
  result = inner.call(payload)
  timings << [tag] # racy under parallel branches
  result
end
```

The same rule applies to effect handlers themselves (`db_query: ->(payload) { ... }`): if two
parallel branches can perform the same effect, the handler body must tolerate concurrent calls.

```ruby
left = Berylx::Task[:left] { |lay| lay[:status].set(:paid) }
right = Berylx::Task[:right] { |lay| lay[:status].set(:trial) }

result = (left & right)
  .reduce(Berylx::Merge.strict)
  .call(Berylx::Lay[status: nil])

result.code
# => :merge_conflict
```

Parallel failure information is available through `result.parallel_errors`. See
[Errors and recovery](error-handling.md).

## Named workflows and graphs

Wrap a composition in `Workflow` when the whole procedure deserves a name:

```ruby
workflow = Berylx::Workflow[:checkout] do
  validate >> (reserve_inventory & authorize_payment).reduce(Berylx::Merge.strict) >> confirm
end
```

Named tasks survive compilation:

```ruby
graph = workflow.compile

graph.nodes
# => named workflow nodes

graph.to_dot
# => digraph "checkout" {
#      "validate#0";
#      "split#1";
#      "join#2";
#      "split#1" -> "reserve_inventory#3";
#      "reserve_inventory#3" -> "join#2";
#      "split#1" -> "authorize_payment#4";
#      "authorize_payment#4" -> "join#2";
#      "confirm#5";
#      "validate#0" -> "split#1";
#      "join#2" -> "confirm#5";
#    }
```

Consecutive steps chain with edges, a parallel group fans out through a synthetic `split`/`join`
pair, and branch arms carry the predicate name (or `else`) as an edge label. Node ids are
index-suffixed so repeated task names stay distinct.

This makes the executable workflow shape available for documentation, visualization, and
instrumentation without a second declarative DSL.

## The `|` operator by receiver

`|` is overloaded, and its meaning depends on the value on the left:

| Receiver | `left \| right` | Meaning                                                                  |
| -------- | --------------- | ------------------------------------------------------------------------ |
| `Root`   | `root \| flow`  | Run `flow` from committed state and commit the result back into the root |
| `State`  | `state \| flow` | Run `flow` from a standalone state (`flow` must be a task/workflow node) |
| `Ok`     | `ok \| node`    | Bind: pass the focus into `node.call` and continue                       |
| `Err`    | `err \| node`   | Short-circuit: return the `Err` unchanged and ignore `node`              |
| `Task`   | `task \| other` | Sequence, identical to `task >> other`                                   |
| `Branch` | `arm \| arm`    | Combine branch arms into one branch (see [Branching](#branching))        |

The running forms (`Root`, `State`) execute a workflow; the result forms (`Ok`, `Err`) thread a
single value through the railway; the composition forms (`Task`, `Branch`) build larger nodes.

## Recovery is composition

`Catch` can sit inline in a sequence, while `rescue_with` wraps an explicit subgraph:

```ruby
inline = charge >> Berylx::Catch[:refund] { |error, lay| compensate(error, lay) } >> notify

scoped =
  (charge >> create_subscription)
    .rescue_with(:refund) { |error, lay| compensate(error, lay) } >>
  notify
```

### The exact scoping rule for `Catch`

A `Catch` is history-dependent: it is not a standalone step but a boundary whose meaning depends on
what reached it.

- It applies to **the nearest preceding failure within the same flattened sequence** — whatever
  `Err` arrives at its position, produced by any earlier step that no earlier boundary already
  recovered.
- When the incoming result is `Ok`, the `Catch` is skipped entirely.
- A fatal error skips the `Catch` unless it was built with `fatal: true` (see
  [Errors and recovery](error-handling.md#fatal-errors)).
- Standing alone (`catch.call(lay)`), a `Catch` is the identity — there is no preceding failure, so
  it passes the lay through as `Ok`.

Because `>>` flattens nested sequences into one step list, grouping does not change which failures
reach a `Catch`: `(a >> catch) >> b` and `a >> (catch >> b)` normalize to the same steps, so `>>`
stays associative even with `Catch` in the chain (pinned in `test/category_laws_test.rb`). What
changes scope is `rescue_with`, which binds recovery to an explicit body: only failures raised
inside that body reach its handler.

Recovery itself runs inside the effect tree: when a body fails, a `RECOVER` effect dispatches
through the current handler map, so aspects observe it and recovery bodies can perform effects. See
[Errors and recovery](error-handling.md#recovery-runs-in-the-effect-tree).

Read [Errors and recovery](error-handling.md) for propagation, partial state, fatal errors, and
handler behavior.
