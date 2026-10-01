# Release health, crons and feature flags

## Release health

With `auto_session_tracking=true` (the default) and a known release, `init`
starts a session for the program. It ends when the program exits: as
`exited`, as `crashed` when an uncaught error ends it, or as `abnormal` for
another failing exit code. Errors captured during the session are counted.

The [`Sentry.http_middleware`](@ref) tracks one session per request, which
are sent as aggregates.

Sessions can be managed by hand with [`start_session`](@ref) and
[`end_session`](@ref).

## Crons

Monitor scheduled jobs with check-ins:

```julia
Sentry.@monitor "nightly-import" begin
    run_import()
end

# or, with the monitor's configuration (created or updated in Sentry):
config = (; schedule=(; type="crontab", value="0 3 * * *"), checkin_margin=5, max_runtime=30,
          timezone="Europe/Vienna")
Sentry.monitor(run_import, "nightly-import"; monitor_config=config)
```

For jobs that span processes, send the check-ins yourself:

```julia
id = capture_checkin(; monitor_slug="nightly-import", status="in_progress")
# ...
capture_checkin(; monitor_slug="nightly-import", check_in_id=id, status="ok", duration=elapsed)
```

## Feature flags

Record flag evaluations, so that errors show which flags were on:

```julia
add_feature_flag("new-checkout", true)
```

The latest 100 evaluations of the isolation scope are sent with error events,
and the active span records up to 10.
