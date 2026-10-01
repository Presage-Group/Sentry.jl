# API reference

## Setup

```@docs
Sentry.init
Sentry.flush
Sentry.close
get_client
is_initialized
Sentry.Client
Sentry.Options
```

## Capturing

```@docs
capture_event
capture_message
capture_exception
last_event_id
```

## Scope data

```@docs
set_tag
set_tags
set_extra
set_context
set_user
set_level
set_fingerprint
add_breadcrumb
add_attachment
Attachment
Sentry.add_event_processor
Sentry.add_error_processor
Sentry.add_global_event_processor
Sentry.set_attribute
```

## Scopes

```@docs
Sentry.Scope
new_scope
isolation_scope
Sentry.use_scope
Sentry.use_isolation_scope
get_current_scope
get_isolation_scope
get_global_scope
Sentry.configure_scope
Sentry.push_scope
```

## Tracing

```@docs
start_transaction
start_span
Sentry.Span
Sentry.Transaction
Sentry.finish
finish_span
get_current_span
Sentry.update_current_span
set_transaction_name
set_measurement
Sentry.set_measurement(::Sentry.Span, ::Any, ::Any, ::Any)
Sentry.set_http_status
Sentry.set_context(::Sentry.Span, ::Any, ::Any)
continue_trace
get_traceparent
get_baggage
Sentry.trace_propagation_meta
Sentry.should_propagate_trace
Sentry.add_trace_headers
Sentry.@trace
set_task_transaction
```

## Logs and metrics

```@docs
Sentry.Logs
Sentry.Metrics
Sentry.capture_log
Sentry.capture_metric
Sentry.LoggingIntegration
Sentry.SentryLogger
Sentry.ignore_logger
```

## Release health, crons and flags

```@docs
start_session
end_session
capture_checkin
Sentry.monitor
Sentry.@monitor
add_feature_flag
```

## Profiling

```@docs
Sentry.start_profiler
Sentry.stop_profiler
```

## Integrations

```@docs
Sentry.Integration
Sentry.register_auto_integration
Sentry.DedupeIntegration
Sentry.ArgvIntegration
Sentry.ModulesIntegration
Sentry.RuntimeContextIntegration
Sentry.TasksIntegration
Sentry.AtexitIntegration
Sentry.ExcepthookIntegration
Sentry.CloudResourceContextIntegration
Sentry.HTTPIntegration
Sentry.http_request
Sentry.http_middleware
Sentry.traced_connection
Sentry.db_span
Sentry.init_workers
Sentry.errormonitor
Sentry.traced
```

## Transport and data

```@docs
Sentry.AbstractTransport
Sentry.HttpTransport
Sentry.PrintTransport
Sentry.SpotlightTransport
Sentry.Envelope
Sentry.Item
Sentry.EventScrubber
Sentry.serialize_value
```
