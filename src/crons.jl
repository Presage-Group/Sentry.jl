##############################
# * Crons
#----------------------------

"""
    capture_checkin(; monitor_slug, status, check_in_id=nothing, duration=nothing, monitor_config=nothing) -> check_in_id

Sends a cron monitor check-in. `status` is one of `"in_progress"`, `"ok"` or
`"error"`; `duration` is in seconds. `monitor_config` (a dict or named tuple
with `schedule`, `checkin_margin`, `max_runtime`, `timezone`, ...) creates or
updates the monitor. Returns the check-in id, to use for the closing check-in.
"""
function capture_checkin(; monitor_slug=nothing, check_in_id=nothing, status=nothing,
                         duration=nothing, monitor_config=nothing)
    id = check_in_id === nothing ? generate_uuid4() : string(check_in_id)
    client = get_client()
    client === nothing && return id
    event = Dict{String,Any}(
        "type" => "check_in",
        "monitor_slug" => monitor_slug === nothing ? nothing : string(monitor_slug),
        "check_in_id" => id,
        "status" => status === nothing ? nothing : string(status),
        "duration" => duration,
        "environment" => client.options.environment,
        "release" => client.options.release,
    )
    if monitor_config !== nothing
        event["monitor_config"] = serialize_value(monitor_config; databag=false)
    end
    capture_event(event)
    sdk_debug("[Crons] Captured check-in (", id, "): ", monitor_slug, " -> ", status)
    return id
end

"""
    monitor(f, monitor_slug; monitor_config=nothing)

Runs `f()` between an `in_progress` check-in and an `ok` (or, if it throws,
`error`) check-in for the cron monitor `monitor_slug`.
"""
function monitor(f, monitor_slug; monitor_config=nothing)
    start = time()
    id = capture_checkin(; monitor_slug, status="in_progress", monitor_config)
    try
        result = f()
        capture_checkin(; monitor_slug, check_in_id=id, status="ok", duration=time() - start, monitor_config)
        return result
    catch
        capture_checkin(; monitor_slug, check_in_id=id, status="error", duration=time() - start, monitor_config)
        rethrow()
    end
end

"""
    @monitor "slug" expr
    @monitor "slug" monitor_config expr

Runs `expr` as a check-in of the cron monitor `slug`; see [`monitor`](@ref).
"""
macro monitor(slug, args...)
    if length(args) == 1
        return :($monitor(() -> $(esc(args[1])), $(esc(slug))))
    elseif length(args) == 2
        return :($monitor(() -> $(esc(args[2])), $(esc(slug)); monitor_config=$(esc(args[1]))))
    end
    throw(ArgumentError("@monitor takes a slug, an optional config, and an expression"))
end

##############################
# * Feature flags
#----------------------------

"""
    add_feature_flag(flag, result::Bool)

Records the result of a feature flag evaluation. The most recent evaluations
(up to 100) are sent with error events, and the active span records them too.
"""
function add_feature_flag(flag, result::Bool)
    iso = get_isolation_scope()
    @lock iso.lock begin
        iso.flags === nothing && (iso.flags = FlagBuffer())
    end
    set_flag!(iso.flags, string(flag), result)
    span = get_current_span()
    span isa Span && set_flag(span, "flag.evaluation.$flag", result)
    return nothing
end
