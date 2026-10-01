# Sentry.jl

A [Sentry](https://sentry.io) SDK for Julia: error monitoring, tracing,
profiling, structured logs, metrics, release health and cron monitoring, with
the same concepts and options as the official SDKs.

## Installation

```julia
using Pkg
Pkg.add("Sentry")
```

## Getting started

Call [`Sentry.init`](@ref) once, as early as possible, with the DSN of your
project (or set the `SENTRY_DSN` environment variable):

```julia
using Sentry

Sentry.init("https://<key>@o<org>.ingest.sentry.io/<project>";
            release="myapp@1.2.3",
            environment="production",
            traces_sample_rate=0.2)
```

From then on:

- errors logged with `@error` are sent as events, and other log messages are
  recorded as breadcrumbs (see [Logs and metrics](logs_metrics.md));
- an uncaught error that ends a script is reported, and everything queued is
  sent before the program exits;
- you can report errors and messages yourself:

```julia
try
    risky()
catch exc
    capture_exception(exc)
end

capture_message("Something noteworthy happened", Warn)
```

- and add context that is sent with every event:

```julia
set_user((; id="42", email="ada@example.com"))
set_tag("customer", "acme")
set_context("job", Dict("id" => 17, "attempt" => 2))
add_breadcrumb(category="auth", message="User logged in")
```

- time the work your program does, and see it in Sentry's performance views:

```julia
start_transaction(name="nightly-import", op="task") do txn
    start_span(op="db.query", name="load rows") do span
        load_rows()
    end
end
```

Without a DSN, `init` does nothing and every other function is a cheap no-op,
so the calls can stay in your code in development and tests.

## Where to go next

- [Configuration](configuration.md) lists every option `init` accepts.
- [Enriching events](enriching.md) covers tags, users, contexts, breadcrumbs,
  attachments, scopes and event processors.
- [Tracing](tracing.md) covers transactions, spans, sampling and distributed tracing.
- [Integrations](integrations.md) covers HTTP.jl clients and servers, databases,
  Distributed.jl, tasks, and writing your own.
- [Parity with sentry-python](parity.md) shows which features of the Python SDK are
  available, and how their names map to Julia.
