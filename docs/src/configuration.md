# Configuration

All options are keyword arguments to [`Sentry.init`](@ref). They have the same
names and meanings as in the Python SDK. Passing an unknown option is an error,
so that a typo does not go unnoticed.

## Core

| Option | Default | Description |
|:--|:--|:--|
| `dsn` (positional) | `ENV["SENTRY_DSN"]` | Where to send data. Without one, nothing is set up. `"fake"` pretty-prints envelopes instead of sending them. |
| `debug` | `ENV["SENTRY_DEBUG"]` or `false` | Print what the SDK does to stderr. |
| `release` | see below | The version of your program. |
| `environment` | `ENV["SENTRY_ENVIRONMENT"]` or `"production"` | |
| `dist` | `nothing` | A distribution of the release. |
| `server_name` | `gethostname()` | |
| `shutdown_timeout` | `10.0` | Seconds to wait at exit for queued events to be sent. |

The release defaults to the first of `SENTRY_RELEASE`, `HEROKU_SLUG_COMMIT`,
`SOURCE_VERSION`, `CODEBUILD_RESOLVED_SOURCE_VERSION`, `CIRCLE_SHA1`,
`GAE_DEPLOYMENT_ID` and `GITHUB_SHA` that is set, or the git commit of the
working directory.

## Errors

| Option | Default | Description |
|:--|:--|:--|
| `sample_rate` | `1.0` | Fraction of error events to send. |
| `error_sampler` | `nothing` | `(event, hint) -> rate` per event; overrides `sample_rate`. |
| `before_send` | `nothing` | `(event, hint) -> event or nothing` to change or drop events. The hint has the `"exception"`. |
| `before_breadcrumb` | `nothing` | `(crumb, hint) -> crumb or nothing`. |
| `ignore_errors` | `[]` | Exception types, type names (`"ArgumentError"`, `"Core.ArgumentError"`), or predicates. |
| `max_breadcrumbs` | `100` | |
| `attach_stacktrace` | `false` | Add the current stack trace to message events. |
| `send_default_pii` | `false` | Send personal data: user IP addresses, request cookies and client addresses, database parameters, user attributes on logs. |
| `event_scrubber` | `EventScrubber()` | Removes sensitive keys (passwords, tokens, cookies, ...). See [`Sentry.EventScrubber`](@ref). |
| `in_app_include`, `in_app_exclude` | `[]` | Module name prefixes that do or do not belong to your application. |
| `project_root` | `pwd()` | Frames under this path are shown relative to it. |
| `include_source_context` | `true` | Send the lines of source around each frame. |
| `max_stack_frames` | `100` | |
| `max_value_length` | `100000` | Longer strings are cut short. |
| `custom_repr` | `nothing` | `x -> string or nothing`, to represent values in events. |
| `max_request_body_size` | `"medium"` | Request bodies sent by the HTTP middleware: `"never"`, `"small"` (1 kB), `"medium"` (10 kB), `"always"`. |

## Tracing

| Option | Default | Description |
|:--|:--|:--|
| `traces_sample_rate` | `ENV["SENTRY_TRACES_SAMPLE_RATE"]` or `nothing` | Fraction of transactions to record. |
| `traces_sampler` | `nothing` | `sampling_context -> rate or Bool`. Overrides the rate and the parent's decision. |
| `enable_tracing` | `nothing` | `true` samples everything when no rate is given; `false` turns tracing off. |
| `trace_propagation_targets` | `[r".*"]` | Outgoing requests whose URL matches (substring or regex) get trace headers. |
| `propagate_traces` | `true` | |
| `strict_trace_continuation` | `false` | Only continue incoming traces from the same Sentry organization. |
| `org_id` | from the DSN | |
| `before_send_transaction` | `nothing` | `(event, hint) -> event or nothing`. |
| `ignore_spans` | `[]` | Span names (strings or regexes, matched in full) or `Dict("name" => ..., "attributes" => Dict(...))` rules. |
| `trace_ignore_status_codes` | `Set()` | HTTP status codes whose transactions are dropped. |
| `max_spans` | `1000` | Spans kept per transaction. |
| `trace_lifecycle` | `"static"` | `"stream"` sends spans as they finish instead of with their transaction. |
| `before_send_span` | `nothing` | `(span, hint) -> span` for streamed spans (can change the name and attributes). |
| `enable_db_query_source`, `db_query_source_threshold_ms` | `true`, `100` | Record where slow queries were made. |
| `enable_http_request_source`, `http_request_source_threshold_ms` | `true`, `100` | Record where slow HTTP requests were made. |

## Profiling

| Option | Default | Description |
|:--|:--|:--|
| `profiles_sample_rate` | `nothing` | Fraction of sampled transactions to profile. |
| `profiles_sampler` | `nothing` | `sampling_context -> rate`. |
| `profile_session_sample_rate` | `nothing` | Turns on continuous profiling for this fraction of processes. |
| `profile_lifecycle` | `"manual"` | `"manual"` (call [`Sentry.start_profiler`](@ref)) or `"trace"` (profile while transactions run). |

## Logs, metrics, sessions

| Option | Default | Description |
|:--|:--|:--|
| `enable_logs` | `false` | Send structured logs. |
| `before_send_log` | `nothing` | `(log, hint) -> log or nothing`. |
| `enable_metrics` | `true` | |
| `before_send_metric` | `nothing` | `(metric, hint) -> metric or nothing`. |
| `auto_session_tracking` | `true` | Track a release health session for the program (when a release is known). |

## Transport

| Option | Default | Description |
|:--|:--|:--|
| `transport` | `nothing` | A [`Sentry.AbstractTransport`](@ref), or a function taking an [`Sentry.Envelope`](@ref). |
| `transport_queue_size` | `100` | Envelopes waiting to be sent; more are dropped (and reported). |
| `http_proxy`, `https_proxy` | `nothing` | Proxy URLs. Without them the `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` variables are used. |
| `ca_certs`, `cert_file`, `key_file` | `nothing` | TLS settings for the connection to Sentry. |
| `send_client_reports` | `true` | Tell Sentry what the SDK dropped, and why. |
| `enable_backpressure_handling` | `true` | Sample fewer transactions while Sentry is rate limiting or the queue is full. |
| `spotlight` | `ENV["SENTRY_SPOTLIGHT"]` | `true` or a URL: also send everything to a local [Spotlight](https://spotlightjs.com). |

## Integrations

| Option | Default | Description |
|:--|:--|:--|
| `integrations` | `[]` | Extra (or reconfigured) integrations. |
| `default_integrations` | `true` | |
| `auto_enabling_integrations` | `true` | Integrations for loaded packages (HTTP.jl, Distributed, DBInterface). |
| `disabled_integrations` | `[]` | Integrations (types, instances or names) to leave out. |
