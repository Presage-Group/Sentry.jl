##############################
# * Client management
#----------------------------

const _CLIENT = Ref{Union{Nothing,Client}}(nothing)

"""
    get_client() -> Union{Client,Nothing}

The active client, or `nothing` before [`init`](@ref) (or without a DSN).
"""
function get_client()
    s = _CURRENT_SCOPE[]
    s !== nothing && s.client !== nothing && return s.client
    s = _ISOLATION_SCOPE[]
    s !== nothing && s.client !== nothing && return s.client
    return _CLIENT[]
end

"""
    is_initialized() -> Bool

Whether [`init`](@ref) has set up a client.
"""
is_initialized() = (c = get_client(); c !== nothing && is_active(c))

"""
    init(dsn=nothing; kwargs...) -> Union{Client,Nothing}

Sets up sentry. The DSN is taken from the `SENTRY_DSN` environment variable
when it is not given; without one (and without `spotlight` or a custom
`transport`) nothing is sent, and `init` does nothing. Calling `init` again
replaces the client, after sending what the previous one had queued.

# Common options
- `release`, `environment` (default `"production"`), `dist`, `server_name`:
  describe the deployment. The release defaults to `SENTRY_RELEASE`, the commit
  ids that CI providers set, or the git commit of the working directory.
- `debug`: print what the SDK does to stderr.
- `sample_rate`: the fraction of error events to send; `error_sampler(event, hint)`
  may return a rate per event instead.
- `before_send(event, hint)`, `before_breadcrumb(crumb, hint)`,
  `before_send_transaction(event, hint)`, `before_send_log(log, hint)`,
  `before_send_metric(metric, hint)`, `before_send_span(span, hint)`: change or
  (by returning `nothing`) drop data before it is sent.
- `ignore_errors`: exception types (or names, or predicates) not to report.
- `max_breadcrumbs` (100), `attach_stacktrace` (false), `send_default_pii` (false),
  `in_app_include`, `in_app_exclude`, `project_root`, `include_source_context`,
  `max_stack_frames`, `max_value_length`, `max_request_body_size`, `custom_repr`,
  `event_scrubber`.
- `shutdown_timeout` (10 seconds): how long to wait at exit for queued events.

# Tracing and profiling
- `traces_sample_rate`, or `traces_sampler(sampling_context)`: turn on tracing.
- `trace_propagation_targets`, `strict_trace_continuation`, `org_id`,
  `ignore_spans`, `trace_ignore_status_codes`, `max_spans`,
  `trace_lifecycle` (`"static"` or `"stream"`).
- `profiles_sample_rate` or `profiles_sampler`: profile sampled transactions;
  `profile_session_sample_rate` and `profile_lifecycle` for continuous profiling.

# Other data
- `enable_logs` (false), `enable_metrics` (true), `auto_session_tracking` (true).

# Transport and integrations
- `transport`, `transport_queue_size`, `http_proxy`, `https_proxy`, `ca_certs`,
  `cert_file`, `key_file`, `send_client_reports`, `enable_backpressure_handling`,
  `spotlight`.
- `integrations`, `default_integrations`, `auto_enabling_integrations`,
  `disabled_integrations`.
"""
function init(dsn=nothing; kwargs...)
    options = make_options(dsn; kwargs...)
    if options.dsn === nothing && spotlight_url(options.spotlight) === nothing && options.transport === nothing
        options.debug && @warn "No DSN for Sentry.jl"
        return nothing
    end

    old = _CLIENT[]
    if old !== nothing
        end_session()
        close_client(old)
    end

    _debug_enabled[] = options.debug
    if !isempty(options.functions_to_trace)
        # Julia functions can not be wrapped after they are defined.
        @warn "Sentry: functions_to_trace is not supported; mark the functions with `Sentry.@trace` instead"
    end
    client = Client(options)
    _CLIENT[] = client
    setup_integrations!(client)
    register_atexit!()

    if options.auto_session_tracking && options.release !== nothing
        start_session()
    end
    sdk_debug("Initialised ", client)
    return client
end

"""
    flush(; timeout=nothing) -> Bool

Waits (up to `timeout` seconds, or `shutdown_timeout`) for everything captured
so far to be sent. Not exported, so call it as `Sentry.flush()`.
"""
function flush(; timeout=nothing)
    c = get_client()
    c === nothing && return true
    return flush_client(c; timeout=timeout)
end
flush(io::IO) = Base.flush(io)

"""
    close(; timeout=nothing)

Sends what is queued, and shuts sentry down. Not exported, so call it as
`Sentry.close()`.
"""
function close(; timeout=nothing)
    c = _CLIENT[]
    c === nothing && return nothing
    end_session()
    close_client(c; timeout=timeout)
    _CLIENT[] === c && (_CLIENT[] = nothing)
    return nothing
end
close(x) = Base.close(x)

##############################
# * Capturing
#----------------------------

"""
    capture_event(event; hint=nothing, scope=nothing, kwargs...) -> event id or nothing

Sends a ready-made event (a dict in sentry's event format). `scope` (a
[`Scope`](@ref), or a function changing the merged scope) and keyword
arguments (`tags`, `extras`, `contexts`, `user`, `level`, `fingerprint`,
`attachments`) add data to this event only.
"""
function capture_event(event::AbstractDict; hint=nothing, scope=nothing, kwargs...)
    client = get_client()
    (client === nothing || !is_active(client)) && return nothing
    _DISABLE_CAPTURE[] && return nothing
    ev = event isa Dict{String,Any} ? event : _string_dict(event)
    h = hint === nothing ? Dict{String,Any}() : _string_dict(hint)
    merged = merge_scopes(scope; kwargs...)
    id = try
        with(_DISABLE_CAPTURE => true) do
            capture_event(client, ev, h, merged)
        end
    catch exc
        _report_internal_exception(exc, catch_backtrace())
        nothing
    end
    if id !== nothing && get(ev, "type", nothing) != "transaction"
        get_isolation_scope().last_event_id = id
    end
    return id
end

# Set while an event is being processed, so that anything the processing logs
# or captures does not recurse into sentry.
const _DISABLE_CAPTURE = ScopedValue(false)

"""
    capture_message(message, level=Info; kwargs...) -> event id or nothing

Sends a message. The level is a `Logging` level (`Info`, `Warn`, `Error`) or
a sentry level name (`"debug"`, `"info"`, `"warning"`, `"error"`, `"fatal"`).
Keyword arguments add data to this event only (see [`capture_event`](@ref));
`attachments` may hold [`Attachment`](@ref)s, or values sent as JSON.
"""
function capture_message(message, level=nothing; scope=nothing, kwargs...)
    event = Dict{String,Any}(
        "message" => Dict{String,Any}("formatted" => string(message)),
        "level" => level === nothing ? "info" : sentry_level(level),
    )
    return capture_event(event; scope=scope, kwargs...)
end

"""
    capture_exception(exc=nothing, backtrace=nothing; handled=true, kwargs...) -> event id or nothing

Sends an exception. Inside a `catch` block, `capture_exception()` and
`capture_exception(exc)` report the exception together with any it was
raised while handling. An exception stack (as from `current_exceptions()`)
can be passed too. Keyword arguments add data to this event only.
"""
function capture_exception(exc=nothing, backtrace=nothing; handled::Bool=true,
                           mechanism_type::String="generic", scope=nothing, kwargs...)
    client = get_client()
    client === nothing && return nothing
    stack = _capture_stack(exc, backtrace)
    isempty(stack) && return nothing
    event, hint = event_from_exception(stack, client.options; handled, mechanism_type)
    return capture_event(event; hint=hint, scope=scope, kwargs...)
end

function _capture_stack(exc, bt)
    if exc === nothing
        return collect(current_exceptions())
    elseif exc isa Base.ExceptionStack || (exc isa AbstractVector && all(x -> x isa Tuple || x isa NamedTuple, exc))
        return [(x[1], x[2]) for x in exc]
    elseif bt !== nothing
        return [(exc, bt)]
    end
    stack = current_exceptions()
    if !isempty(stack) && last(stack)[1] === exc
        return [(x[1], x[2]) for x in stack]
    end
    return [(exc, catch_backtrace())]
end

"""
    last_event_id() -> Union{String,Nothing}

The id of the last event captured in the isolation scope.
"""
last_event_id() = get_isolation_scope().last_event_id

##############################
# * Scope data
#----------------------------

"""
    add_breadcrumb(crumb=nothing; hint=nothing, kwargs...)

Records a breadcrumb, sent with later events. Give a dict, or keywords such as
`message`, `category`, `level`, `type` and `data`.
"""
add_breadcrumb(crumb=nothing; hint=nothing, kwargs...) = add_breadcrumb(get_isolation_scope(), crumb; hint=hint, kwargs...)

"""
    set_tag(key, value)

Sets a tag on the isolation scope, applied to all events captured in it.
"""
function set_tag(key, value)
    if string(key) == "release"
        @warn "A 'release' tag is ignored by sentry upstream. You should instead set the release in the `init` call"
    end
    return set_tag(get_isolation_scope(), key, value)
end

"""
    set_tags(tags)

Sets several tags (a dict or named tuple) on the isolation scope.
"""
set_tags(tags) = set_tags(get_isolation_scope(), tags)
remove_tag(key) = remove_tag(get_isolation_scope(), key)

"""
    set_extra(key, value)

Adds extra data to events captured in the isolation scope.
"""
set_extra(key, value) = set_extra(get_isolation_scope(), key, value)
remove_extra(key) = remove_extra(get_isolation_scope(), key)

"""
    set_context(key, value)

Sets a context (a dict of values, such as `"app"` or `"character"`) on the
isolation scope.
"""
set_context(key, value) = set_context(get_isolation_scope(), key, value)
remove_context(key) = remove_context(get_isolation_scope(), key)

"""
    set_user(user)

Sets the user (a dict or named tuple with `id`, `username`, `email`,
`ip_address`, ...), or clears it with `nothing`.
"""
set_user(user) = set_user(get_isolation_scope(), user)

"""
    set_level(level)

Overrides the level of events captured in the isolation scope.
"""
set_level(level) = set_level(get_isolation_scope(), level)

"""
    set_fingerprint(fingerprint)

Sets the grouping fingerprint (a vector of strings) of events captured in the
isolation scope.
"""
set_fingerprint(fp) = set_fingerprint(get_isolation_scope(), fp)

"""
    add_attachment(; bytes=nothing, path=nothing, json=nothing, filename=nothing, content_type=nothing, add_to_transactions=false)
    add_attachment(attachment::Attachment)

Adds a file to the events captured in the isolation scope.
"""
add_attachment(; kwargs...) = add_attachment(get_isolation_scope(); kwargs...)
add_attachment(a::Attachment) = add_attachment(get_isolation_scope(), a)

"""
    add_event_processor(f)

Adds `f(event, hint)` to the isolation scope. It may change the event, or
drop it by returning `nothing`.
"""
add_event_processor(f) = add_event_processor(get_isolation_scope(), f)

"""
    add_error_processor(f)

Adds `f(event, exception)` for error events to the isolation scope.
"""
add_error_processor(f) = add_error_processor(get_isolation_scope(), f)
clear_breadcrumbs() = clear_breadcrumbs(get_isolation_scope())

"""
    set_attribute(key, value)
    set_attributes(attributes)

Sets attributes that are added to the logs and metrics sent from the
isolation scope.
"""
set_attribute(key, value) = set_attribute(get_isolation_scope(), key, value)
set_attributes(attrs) = set_attributes(get_isolation_scope(), attrs)
remove_attribute(key) = remove_attribute(get_isolation_scope(), key)

"""
    set_transaction_name(name; source=nothing)

Renames the active transaction (and the transaction events are grouped by).
"""
set_transaction_name(name; source=nothing) = set_transaction_name(get_current_scope(), name; source=source)

"""
    set_measurement(name, value, unit="")

Records a measurement on the active transaction.
"""
function set_measurement(name, value, unit="")
    span = get_current_span()
    span isa Span && set_measurement(span, name, value, unit)
    return nothing
end

##############################
# * Sessions
#----------------------------

"""
    start_session(; session_mode="application")

Starts a release health session on the isolation scope, ending any that was
running. `init` starts one for the application when `auto_session_tracking`
is on and a release is known.
"""
function start_session(; session_mode="application")
    end_session()
    client = get_client()
    client === nothing && return nothing
    iso = get_isolation_scope()
    iso.session = Session(; release=client.options.release, environment=client.options.environment,
                          user=iso.user, session_mode=session_mode)
    return nothing
end

"""
    end_session(; status=nothing)

Ends the isolation scope's session and queues it to be sent.
"""
function end_session(; status=nothing)
    iso = get_isolation_scope()
    session = iso.session
    session === nothing && return nothing
    iso.session = nothing
    close!(session, status)
    client = get_client()
    client === nothing || capture_session(client, session)
    return nothing
end

##############################
# * Legacy API
#----------------------------

"""
    set_task_transaction(transaction)

Makes `transaction` (as returned by `start_transaction` without a function)
the active span of the current task. Only needed for transactions started
without a function: scopes, and so the active span, are inherited by tasks
automatically.
"""
function set_task_transaction(t::Span)
    get_current_scope().span = t
    return nothing
end
set_task_transaction(::Nothing) = nothing
