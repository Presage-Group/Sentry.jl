# Logs and metrics

## Julia's logging

The [`Sentry.LoggingIntegration`](@ref) wraps the global logger when Sentry is
initialised, and passes every message on to the logger it wrapped:

- messages at `Info` or above become breadcrumbs;
- messages at `Error` or above are sent as events. Attach the exception to get
  its stack trace:

```julia
try
    risky()
catch exc
    @error "Import failed" exception=(exc, catch_backtrace()) file=path
end
```

- with `enable_logs=true`, messages at `Info` or above are also sent as
  structured Sentry logs, with their keyword arguments as attributes.

The levels are configurable, and a level of `nothing` turns that part off:

```julia
using Logging
Sentry.init(dsn; integrations=[Sentry.LoggingIntegration(; level=Logging.Warn, event_level=nothing)])
```

Messages from a module can be left out with [`Sentry.ignore_logger`](@ref).
Loggers installed with `with_logger` are not wrapped.

## Structured logs

With `enable_logs=true`, send logs directly with [`Sentry.Logs`](@ref):

```julia
Sentry.Logs.info("User {user} bought {count} items"; user="ada", count=3,
                 attributes=(; plan="pro"))
Sentry.Logs.error("Payment failed")
```

Placeholders are filled from the keyword arguments, which are also recorded
as parameters, so that Sentry can group logs by their template. Logs are
linked to the active trace, carry the attributes set with
[`Sentry.set_attribute`](@ref), and can be changed or dropped by
`before_send_log`. They are sent in batches.

## Metrics

```julia
Sentry.Metrics.count("checkout.completed", 1; attributes=(; region="eu"))
Sentry.Metrics.gauge("queue.depth", length(queue))
Sentry.Metrics.distribution("render.duration", elapsed; unit="second")
```

Metrics are linked to the active trace, and can be changed or dropped by
`before_send_metric`.
