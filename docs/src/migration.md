# Migrating from 0.2

Most code written for Sentry.jl 0.2 keeps working. The differences:

## Behaviour

- **Calling `init` again** replaces the client (after sending what the old
  one had queued) instead of warning and doing nothing.
- **`init` without a DSN** no longer warns, unless `debug=true`.
- **Tags** set with `set_tag` are kept on the isolation scope rather than in
  the global `Sentry.global_tags` dictionary, which is gone. Use
  [`isolation_scope`](@ref) to keep them apart per request.
- **The logging integration** is on by default: `@error` messages are sent as
  events, and `@info` and `@warn` become breadcrumbs. Pass
  `disabled_integrations=[Sentry.LoggingIntegration]` to turn it off.
- **Release health** sessions are tracked when a release is known. Pass
  `auto_session_tracking=false` to turn them off.
- **Exceptions** are reported with the exceptions they were raised while
  handling, and with the lines of source around each frame.
- A transport response of any `2xx` status counts as sent.

## API

- `start_transaction` returns a [`Sentry.Span`](@ref) (the transaction)
  instead of a named tuple. The do-block form is unchanged. As before,
  `start_transaction` without a `name` inside an active span starts a child
  span; prefer [`start_span`](@ref) for that now.
- `set_task_transaction` is only needed for transactions started without a
  function: the active span is inherited by tasks automatically.
- `traces_sampler` receives a sampling context. Zero argument functions,
  `Sentry.RatioSampler` and `Sentry.NoSamples` still work.
- `Sentry.main_hub` and the `Hub` type are gone; use [`get_client`](@ref) and
  the scope functions.
- `capture_message` with `attachments` of plain values still sends them as
  JSON; [`Attachment`](@ref) can send files and bytes too.
- The `"fake"` DSN still prints envelopes instead of sending them.
