# Sentry.jl

[![Build Status](https://github.com/Presage-group/Sentry.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Presage-group/Sentry.jl/actions/workflows/CI.yml?query=branch%3Amain)

## Acknowledgement

This is a update on [SentryIntegration.jl](https://github.com/synchronoustechnologies/SentryIntegration.jl) that works in modern julia without relying on unregistered packages. 

## Basic Sentry Functionality

The [Sentry Developer Documentation](https://develop.sentry.dev/sdk/overview/) states:

> At its core an SDK is a set of utilities for capturing data about an exceptional state in an application. Given this data, it then builds and sends a JSON payload to the Sentry server.

> The following items are expected of production-ready SDKs:

> - DSN configuration
> - Graceful failures (e.g. Sentry server is unreachable)
> - Setting attributes (e.g. tags and extra data)
> - Support for Linux, Windows and OS X (where applicable)

### DSN Configuration

Call `Sentry.init()` with the ENV variable `SENTRY_DSN` set to your DSN, or pass the DSN as a variable, as in: 

```julia
Sentry.init("https://0000000000000000000000000000000000000000.ingest.sentry.io/0000000")
```

### Setting Attributes

You can set tags using the `set_tag` function. 

```julia
Sentry.set_tag("customer", customer)
Sentry.set_tag("release", string(VERSION))
Sentry.set_tag("environment", get(ENV, "RUN_ENV", "unset"))
```


### Capturing Exceptional State

Messages are sent out via `capture_exception` and `capture_message`:

```julia
# At a high level in your app/tasks (to catch as many unhandled exceptions as
# possible)
try
    core_loop()
catch exc
    capture_exception(exc)
    # Maybe rethrow here
end
```

You can control the priority level of the message using the second argument to `capture_message`: 

```julia
capture_message("Boring info message")
capture_message("An external REST request was received for an API ($api_name) that is unknown",
                Warn)
capture_message("Should not have got here!", Error)
```

Attachments can be included along with the message using the `attachments` argument: 

```julia
capture_message("Noticed an 'errors' field in the GQL REST return:",
                Warn,
                attachments=[(;command, response)])
```

### Graceful Failures

Work in progress...

### Supported Operating Systems

Should work anywhere julia does! 