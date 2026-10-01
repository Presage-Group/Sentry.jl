# Tracing

Turn tracing on with `traces_sample_rate` (or `traces_sampler`):

```julia
Sentry.init(dsn; traces_sample_rate=1.0)
```

## Transactions and spans

A transaction is the root of the work done in this process for one
operation; spans are the steps inside it.

```julia
start_transaction(name="GET /users", op="http.server", source="route") do txn
    Sentry.set_tag(txn, "tenant", "acme")
    users = start_span(op="db.query", name="SELECT * FROM users") do span
        Sentry.set_data(span, "db.system", "postgresql")
        query_users()
    end
    render(users)
end
```

The function forms finish the span when the function returns, and mark it as
failed (`internal_error`) when it throws. Spans started in tasks spawned
inside the block become children of the active span.

Without a function, a transaction or span stays active until it is
finished:

```julia
txn = start_transaction(name="import")
span = start_span(op="parse")
# ...
finish_span(span)
finish_transaction(txn)
```

Useful span functions: `Sentry.set_tag`, `Sentry.set_data`,
`Sentry.set_status`, `Sentry.set_http_status`, [`set_measurement`](@ref),
[`set_transaction_name`](@ref), [`Sentry.update_current_span`](@ref) and
[`get_current_span`](@ref).

## `@trace`

Record every call to a function as a span:

```julia
Sentry.@trace function load_rows(path)
    CSV.read(path, DataFrame)
end

Sentry.@trace op="db" function fetch_user(id) ... end
Sentry.@trace "expensive step" compute()   # or an expression
```

## Sampling

- `traces_sample_rate` samples that fraction of transactions;
- `traces_sampler` decides per transaction. It receives a sampling context
  with the `"transaction_context"` (name, op, ...), the `"parent_sampled"`
  decision, and any `custom_sampling_context` given to `start_transaction`:

```julia
Sentry.init(dsn; traces_sampler=ctx -> begin
    ctx["transaction_context"]["name"] == "healthcheck" && return 0.0
    ctx["parent_sampled"] !== nothing && return ctx["parent_sampled"]
    0.25
end)
```

Incoming traces keep the decision of the service that started them.

## Distributed tracing

Continue a trace from the headers of an incoming request (`sentry-trace` and
`baggage`, or a W3C `traceparent`):

```julia
continue_trace(request_headers; name="process order", op="queue.task") do txn
    process(order)
end
```

Send the trace on with outgoing requests. [`Sentry.http_request`](@ref) does
this for HTTP.jl; for other clients, use [`Sentry.add_trace_headers`](@ref)
or [`get_traceparent`](@ref) and [`get_baggage`](@ref):

```julia
headers = Sentry.add_trace_headers(["Accept" => "application/json"], url)
```

`trace_propagation_targets` controls which URLs get the headers.
[`Sentry.traced`](@ref) wraps a function so that it continues the current
trace wherever it runs, such as on a Distributed.jl worker:

```julia
pmap(Sentry.traced(process_chunk; op="chunk"), chunks)
```

## Filtering

- `before_send_transaction` can change or drop finished transactions;
- `ignore_spans` drops spans by name or attributes;
- `trace_ignore_status_codes` drops transactions of requests with those
  status codes;
- `max_spans` limits the spans kept per transaction.

## Streaming spans

With `trace_lifecycle="stream"`, spans are sent (in batches) as they finish,
rather than with their transaction. This is new in Sentry, and in the other
SDKs.
