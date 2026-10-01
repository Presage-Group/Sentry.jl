# Enriching events

## Tags, users, contexts and extra data

```julia
set_tag("customer", "acme")                  # indexed and searchable
set_tags((; region="eu", tier="gold"))
set_user((; id="42", email="ada@example.com", ip_address="{{auto}}"))
set_context("job", Dict("id" => 17, "attempt" => 2))
set_extra("payload_size", 1024)
set_level("warning")                          # overrides the level of events
set_fingerprint(["{{ default }}", "tenant-a"]) # controls grouping
```

Data can also be given for a single event:

```julia
capture_message("Import finished"; tags=(; rows=10_000), extras=(; file="data.csv"))
capture_exception(exc; user=(; id="42"), fingerprint=["import-failure"])
```

## Breadcrumbs

Breadcrumbs are a trail of what happened before an event. The logging
integration records log messages as breadcrumbs, and the HTTP and database
integrations record requests and queries. Add your own with
[`add_breadcrumb`](@ref):

```julia
add_breadcrumb(category="payment", message="Card charged", level="info",
               data=Dict("amount" => 42))
```

## Attachments

```julia
add_attachment(; path="config.toml")                         # read when an event is sent
add_attachment(; bytes=take!(io), filename="dump.bin")
add_attachment(Attachment(json=result, filename="result.json"))
capture_message("with a file"; attachments=[Attachment(bytes="...", filename="notes.txt")])
```

## Scopes

Data is kept on scopes, which are applied to the events captured while they
are active:

- the **global scope** applies to everything ([`get_global_scope`](@ref));
- the **isolation scope** holds the data of one unit of work, such as a
  request or a job. The top level functions (`set_tag`, `set_user`,
  `add_breadcrumb`, ...) change it. [`isolation_scope`](@ref) starts a new one:

```julia
isolation_scope() do
    set_user((; id=request.user_id))
    handle(request)          # errors captured here carry this user
end                          # ... and the user is gone again here
```

- the **current scope** is the innermost one, and holds the active span.
  [`new_scope`](@ref) forks it for a block:

```julia
new_scope() do scope
    Sentry.set_tag(scope, "phase", "cleanup")
    capture_message("only this event is tagged")
end
```

Scopes are carried into tasks started with `@async` and `Threads.@spawn`, so
work done in child tasks is attributed to the right request and trace.

## Event processors and `before_send`

Event processors run on every event of a scope, and can change or drop it:

```julia
Sentry.add_event_processor() do event, hint
    event["tags"]["processed_by"] = "my-processor"
    event
end
```

`before_send` (an option to `init`) runs last, on the final event:

```julia
Sentry.init(dsn; before_send=(event, hint) -> begin
    hint["exception"] isa MyExpectedError && return nothing   # drop
    event
end)
```

Events are dictionaries in [Sentry's event format](https://develop.sentry.dev/sdk/event-payloads/).

## Sensitive data

Unless `send_default_pii=true`, IP addresses, cookies, client addresses and
database query parameters are left out. An [`Sentry.EventScrubber`](@ref)
additionally replaces the values of sensitive keys (`password`, `token`,
`authorization`, `cookie`, ...) in request data, extra data, the user,
breadcrumb data and span data with `"[Filtered]"`. Pass a configured one as
`event_scrubber` to change the list or scrub nested data.
