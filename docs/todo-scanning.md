# Cooperative todo scanning

`require("auto-core.todo").scan()` remains a synchronous, read-only scan
returning `{ tasks = {...}, malformed = {...} }`. It does not reconcile
files, validate references, or perform auto-archiving; those maintenance
operations belong to `refresh()`.

UI consumers can use `scan_async(callback)` instead:

```lua
local cancel = require("auto-core.todo").scan_async(function(result, done, err)
  if err then
    -- Report the failure; result is nil and done is true.
    return
  end
  -- Render result.tasks and result.malformed without scanning again.
  -- done=false: all non-archived buckets have been read.
  -- done=true: archives have also been read.
end)

-- On close or location change:
cancel()
```

The resolved task directory is captured at invocation. No files are read
before returning. The scanner yields between batches of at most 32 files
or approximately 8ms, delivers active buckets first, then enumerates and
reads archives. Both phases reuse the same decode/schema-validation path
and canonical walk as `scan()`, including malformed files. A missing
directory produces two empty deliveries, ending with `done=true`.

The result table accumulates across deliveries; copy it if retaining an
intermediate snapshot. Cancellation suppresses future callbacks. Consumers
must reject results if their buffer or selected directory has changed.

This is cooperative main-loop scheduling, not worker-thread I/O: directory
enumeration and each individual read/decode remain synchronous. A single
large file or slow filesystem operation may still exceed the batch budget.
It avoids an uninterrupted decode of the entire store; it is not a
persistent index or cache.

AutoFinder uses this API to mount a loading placeholder immediately,
avoid a duplicate first-focus scan, display active tasks before archives,
and coalesce visible task-event bursts. With older auto-core versions it
still mounts first but falls back to a deferred synchronous scan. Manual
`R` retains the explicit reconciliation behavior of `refresh()`.