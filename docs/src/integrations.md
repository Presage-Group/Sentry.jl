# Integrations

Integrations connect Sentry to the runtime and to other packages. The default
ones are enabled by `init`; those for optional packages are enabled once the
package is loaded (as a package extension). List them with
`keys(get_client().integrations)`, and leave some out with
`disabled_integrations`.

## Default integrations

| Integration | What it does |
|:--|:--|
| [`Sentry.LoggingIntegration`](@ref) | Log messages become breadcrumbs, events and (with `enable_logs`) Sentry logs. |
| [`Sentry.ExcepthookIntegration`](@ref) | Reports the uncaught error that ends a script, as fatal and unhandled. |
| [`Sentry.AtexitIntegration`](@ref) | Sends what is queued when the program exits. |
| [`Sentry.DedupeIntegration`](@ref) | Drops an exception captured twice in a row. |
| [`Sentry.ModulesIntegration`](@ref) | Adds the loaded packages and their versions to error events. |
| [`Sentry.ArgvIntegration`](@ref) | Adds the command line to events. |
| [`Sentry.RuntimeContextIntegration`](@ref) | Adds the `runtime`, `os` and `device` contexts. |
| [`Sentry.TasksIntegration`](@ref) | Scopes and the active span are inherited by tasks. |
| [`Sentry.CloudResourceContextIntegration`](@ref) | Adds the `cloud_resource` context on AWS, GCP, Azure and Kubernetes. |
| [`Sentry.HTTPIntegration`](@ref) | Instruments HTTP.jl (see below). |

## HTTP.jl

**Outgoing requests.** [`Sentry.http_request`](@ref) takes the same arguments
as `HTTP.request`, records the request as an `http.client` span and a
breadcrumb, and adds the trace headers:

```julia
response = Sentry.http_request("GET", "https://api.example.com/users"; readtimeout=10)
```

**Servers.** [`Sentry.http_middleware`](@ref) wraps a request handler: each
request runs in its own isolation scope, continues the caller's trace, is
recorded as an `http.server` transaction, adds the request to events, counts
towards release health, and has its errors reported.

```julia
router = HTTP.Router()
HTTP.register!(router, "GET", "/users", list_users)
HTTP.serve!(Sentry.http_middleware(router), "0.0.0.0", 8080)
```

It has the shape of an [Oxygen.jl](https://github.com/OxygenFramework/Oxygen.jl)
middleware too: `serve(; middleware=[Sentry.http_middleware])`.

## Databases (DBInterface.jl)

[`Sentry.traced_connection`](@ref) wraps any DBInterface connection (SQLite.jl,
LibPQ.jl, MySQL.jl, DuckDB.jl, ODBC.jl, ...). Queries run through it are
recorded as `db` spans and breadcrumbs, and slow ones point at the code that
made them:

```julia
using SQLite, DBInterface
db = Sentry.traced_connection(SQLite.DB("app.sqlite"))
DBInterface.execute(db, "SELECT * FROM users WHERE id = ?", (42,))
```

Instrument other database clients with [`Sentry.db_span`](@ref).

## Distributed.jl

Once Distributed is loaded, events carry a `distributed` context with the
worker id. Errors from workers (`RemoteException`s) are reported with the
original error and its stack trace. Set up Sentry on workers with the current
settings, and continue traces on them:

```julia
using Distributed
addprocs(4)
Sentry.init_workers()
pmap(Sentry.traced(process; op="chunk"), chunks)
```

## Tasks

Scopes are inherited by tasks, so tags, users and the active span carry over
into `@async` and `Threads.@spawn`. Errors that end a task are usually only
seen when it is waited on; [`Sentry.errormonitor`](@ref) reports them as soon
as they happen:

```julia
Sentry.errormonitor(Threads.@spawn background_job())
```

## Spotlight

[Spotlight](https://spotlightjs.com) shows your Sentry data locally while you
develop. Run it (`npx @spotlightjs/spotlight`) and initialise with
`spotlight=true` (or set `SENTRY_SPOTLIGHT=1`). Without a DSN, everything is
sampled and sent to Spotlight only.

## Writing an integration

```julia
struct MyLibIntegration <: Sentry.Integration end

function Sentry.setup_once(::Type{MyLibIntegration})
    Sentry.add_global_event_processor() do event, hint
        Sentry.integration_enabled(MyLibIntegration) || return event
        event["tags"] = merge(get(event, "tags", Dict()), Dict("mylib" => "yes"))
        event
    end
end

Sentry.init(dsn; integrations=[MyLibIntegration()])
```

`setup_once` runs once per process; `Sentry.setup!(integration, client)` and
`Sentry.teardown!(integration, client)` run for each client. A package
extension can call [`Sentry.register_auto_integration`](@ref) in its
`__init__` to be enabled by default.

## Transports

To send envelopes somewhere else, pass a function or an
[`Sentry.AbstractTransport`](@ref) as `transport`:

```julia
Sentry.init(dsn; transport=envelope -> println(Sentry.describe(envelope)))
```
