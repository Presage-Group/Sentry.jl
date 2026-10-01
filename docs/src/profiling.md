# Profiling

Profiles are recorded with Julia's sampling profiler (the `Profile` standard
library), at about 101 samples per second.

## Transaction profiling

Profile a fraction of the sampled transactions:

```julia
Sentry.init(dsn; traces_sample_rate=1.0, profiles_sample_rate=0.5)
```

The profile is sent with its transaction. Julia has one sampling profiler per
process, so only one transaction is profiled at a time.

## Continuous profiling

Profile the whole program, in chunks sent every minute:

```julia
Sentry.init(dsn; profile_session_sample_rate=1.0)
Sentry.start_profiler()
# ...
Sentry.stop_profiler()
```

With `profile_lifecycle="trace"` the profiler runs automatically while
sampled transactions do. Transactions record the id of the profiler that ran
during them.

Continuous and transaction profiling do not run together; with
`profile_session_sample_rate` set, transaction profiling is off.

!!! note
    Julia is not one of the platforms Sentry's profiling product lists. The
    profiles use Sentry's generic sample format, with the platform `julia`.
