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
| `State`  | `state \| flow` | Run `flow` from a standalone state (raw blocks are coerced into tasks)   |
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

Read [Errors and recovery](error-handling.md) for propagation, partial state, fatal errors, and
handler behavior.
