# Sentry.jl

[![Build Status](https://github.com/Presage-group/Sentry.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Presage-group/Sentry.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![codecov](https://codecov.io/gh/Presage-Group/Sentry.jl/graph/badge.svg?token=O28SVV3R6F)](https://codecov.io/gh/Presage-Group/Sentry.jl)
[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://presage-group.github.io/Sentry.jl/dev/)

A [Sentry](https://sentry.io) SDK for Julia, with the features of the official
SDKs: error monitoring, tracing, profiling, structured logs, metrics, release
health and cron monitoring. Its API and options follow
[sentry-python](https://github.com/getsentry/sentry-python).

## Quick start

```julia
using Sentry

Sentry.init("https://<key>@o<org>.ingest.sentry.io/<project>";   # or set SENTRY_DSN
            release="myapp@1.2.3",
            traces_sample_rate=0.2)

set_user((; id="42"))
set_tag("customer", "acme")

try
    risky()
catch exc
    capture_exception(exc)      # with the full exception chain and source context
end

capture_message("Something noteworthy happened", Warn)

@error "Import failed" file=path  # log messages are captured too

start_transaction(name="nightly-import", op="task") do txn
    start_span(op="db.query", name="load rows") do span
        load_rows()
    end
end
```

Without a DSN, `init` does nothing and the other functions are cheap no-ops.

## Features

- **Errors**: exception chains (including task failures, composite and remote
  exceptions), in-app frames and source context, tags, users, contexts,
  breadcrumbs, attachments, fingerprints, `before_send`, sampling,
  `ignore_errors`, scrubbing of sensitive data.
- **Scopes**: global, isolation and current scopes, inherited by tasks.
- **Tracing**: transactions and spans, `@trace`, sampling (including by the
  parent), distributed tracing with `sentry-trace`, `baggage` and W3C
  `traceparent` headers, span streaming.
- **Profiling**: transaction and continuous profiles, from Julia's sampling
  profiler.
- **Logs and metrics**: `Sentry.Logs` and `Sentry.Metrics`, and Julia's
  logging (`@info`, `@error`) as breadcrumbs, events and logs.
- **Release health**: application and request sessions, crashed sessions for
  uncaught errors.
- **Crons**: `Sentry.@monitor` and check-ins.
- **Feature flags**: `add_feature_flag`.
- **Integrations**: HTTP.jl clients and servers (and Oxygen.jl),
  DBInterface.jl databases (SQLite, LibPQ, MySQL, ...), Distributed.jl, tasks,
  cloud platforms, Spotlight.
- **Transport**: gzip, rate limits, client reports, backpressure handling,
  proxies and TLS settings, flushing at exit.

See the [documentation](https://presage-group.github.io/Sentry.jl/dev/) for
details, including a feature by feature comparison with sentry-python.

## Acknowledgement

This started as an update of
[SentryIntegration.jl](https://github.com/synchronoustechnologies/SentryIntegration.jl)
that works in modern Julia without relying on unregistered packages.
