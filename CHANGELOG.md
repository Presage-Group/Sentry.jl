# Changelog

## 0.3.0

Brings Sentry.jl up to the features of sentry-python. See the
[migration guide](https://presage-group.github.io/Sentry.jl/dev/migration/)
for the (few) changes in behaviour.

### Added

- Scopes: global, isolation and current scopes (`new_scope`, `isolation_scope`,
  `get_*_scope`), carried into tasks by scoped values.
- Event data: `set_tags`, `set_extra`, `set_context`, `set_user`, `set_level`,
  `set_fingerprint`, `add_breadcrumb`, `add_attachment` (bytes, files, JSON),
  `capture_event`, `last_event_id`, event and error processors.
- Options: every language independent option of sentry-python, including
  `sample_rate`, `error_sampler`, `before_send`, `before_breadcrumb`,
  `ignore_errors`, `attach_stacktrace`, `send_default_pii`, `in_app_*`,
  `max_value_length`, `event_scrubber`, `environment` and `release` defaults
  from the environment.
- Exceptions: chained exceptions, task failures, composite, captured and remote
  exceptions, `mechanism` data, in-app frames, source context.
- Default integrations: logging, uncaught errors at exit, dedupe, loaded
  modules, command line, runtime/os/device contexts, cloud resource context.
- Transport: rate limits (`X-Sentry-Rate-Limits`, `Retry-After`), client
  reports, a bounded queue, backpressure handling, proxies, TLS options,
  Spotlight, custom transports.
- Tracing: `start_span`, `@trace`, sampling contexts and parent sampling,
  `continue_trace`, `sentry-trace`/`baggage`/`traceparent` propagation, dynamic
  sampling context, `before_send_transaction`, `ignore_spans`,
  `trace_ignore_status_codes`, `max_spans`, measurements, span streaming.
- Profiling: transaction and continuous profiling.
- Structured logs (`Sentry.Logs`) and metrics (`Sentry.Metrics`).
- Release health sessions, cron check-ins (`Sentry.@monitor`), feature flags.
- HTTP.jl client instrumentation (`Sentry.http_request`) and server middleware
  (`Sentry.http_middleware`).
- Package extensions for DBInterface.jl (`Sentry.traced_connection`) and
  Distributed.jl (`Sentry.init_workers`).
- Documentation.

### Changed

- `init` can be called again to replace the client.
- `start_transaction` returns a `Sentry.Span`.
- Tags live on the isolation scope; `Sentry.global_tags` and `Sentry.main_hub`
  are gone.
- Any 2xx response counts as a successful send.
