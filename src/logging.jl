##############################
# * Sentry logs and metrics
#----------------------------

# OpenTelemetry severity numbers for the sentry log levels.
const LOG_SEVERITIES = (trace=1, debug=5, info=9, warn=13, error=17, fatal=21)

function log_severity(level::LogLevel)
    level >= LogLevel(Logging.Error.level + 1) && return ("fatal", 21)
    level >= Logging.Error && return ("error", 17)
    level >= Logging.Warn && return ("warn", 13)
    level >= Logging.Info && return ("info", 9)
    level >= Logging.Debug && return ("debug", 5)
    return ("trace", 1)
end

"""Attributes that every log and metric carries."""
function default_telemetry_attributes(c::Client)
    attrs = Dict{String,Any}("sentry.sdk.name" => SDK_NAME, "sentry.sdk.version" => string(VERSION),
                             "process.runtime.name" => "julia",
                             "process.runtime.version" => string(Base.VERSION))
    o = c.options
    o.server_name === nothing || (attrs["server.address"] = o.server_name)
    o.environment === nothing || (attrs["sentry.environment"] = o.environment)
    o.release === nothing || (attrs["sentry.release"] = o.release)
    return attrs
end

"""Substitutes `{name}` placeholders in a log template."""
function format_template(template::AbstractString, params)
    isempty(params) && return String(template)
    lookup = Dict(string(k) => v for (k, v) in pairs(params))
    return replace(template, r"\{(\w+)\}" => s -> begin
        key = s[2:end-1]
        haskey(lookup, key) ? string(lookup[key]) : s
    end)
end

"""
    capture_log(level, severity_number, template; attributes=nothing, kwargs...)

Sends a structured log to sentry (when `enable_logs=true`). Keyword arguments
fill `{name}` placeholders in the template and are recorded as parameters.
Usually called through [`Sentry.Logs`](@ref).
"""
function capture_log(level::AbstractString, severity_number::Integer, template;
                     attributes=nothing, _origin=nothing, kwargs...)
    client = get_client()
    (client === nothing || !client.options.enable_logs) && return nothing
    attrs = Dict{String,Any}()
    if attributes !== nothing
        for (k, v) in pairs(attributes)
            attrs[string(k)] = format_attribute(v)
        end
    end
    for (k, v) in kwargs
        attrs["sentry.message.parameter.$k"] = format_attribute(v)
    end
    body = string(template)
    if !isempty(kwargs)
        attrs["sentry.message.template"] = body
        body = try
            format_template(body, kwargs)
        catch
            body
        end
    end
    _origin === nothing || (attrs["sentry.origin"] = _origin)
    for (k, v) in default_telemetry_attributes(client)
        haskey(attrs, k) || (attrs[k] = v)
    end
    log = Dict{String,Any}(
        "severity_text" => String(level),
        "severity_number" => Int(severity_number),
        "attributes" => attrs,
        "body" => body,
        "time_unix_nano" => round(Int, time() * 1e9),
        "trace_id" => nothing,
        "span_id" => nothing,
    )
    client.options.debug && sdk_debug("[Sentry Logs] [", level, "] ", body)
    capture_telemetry(client, log, :log, merge_scopes())
    return nothing
end

"""
    capture_metric(name, type, value; unit=nothing, attributes=nothing)

Sends a metric (`type` one of `"counter"`, `"gauge"`, `"distribution"`).
Usually called through [`Sentry.Metrics`](@ref).
"""
function capture_metric(name::AbstractString, type::AbstractString, value::Real; unit=nothing, attributes=nothing)
    client = get_client()
    (client === nothing || !client.options.enable_metrics) && return nothing
    attrs = Dict{String,Any}()
    if attributes !== nothing
        for (k, v) in pairs(attributes)
            attrs[string(k)] = format_attribute(v)
        end
    end
    for (k, v) in default_telemetry_attributes(client)
        haskey(attrs, k) || (attrs[k] = v)
    end
    metric = Dict{String,Any}(
        "timestamp" => time(),
        "trace_id" => nothing,
        "span_id" => nothing,
        "name" => String(name),
        "type" => String(type),
        "value" => Float64(value),
        "unit" => unit === nothing ? nothing : string(unit),
        "attributes" => attrs,
    )
    client.options.debug && sdk_debug("[Sentry Metrics] [", type, "] ", name, ": ", value)
    capture_telemetry(client, metric, :metric, merge_scopes())
    return nothing
end

"""
    Sentry.Logs

Structured logs, sent when `init` is called with `enable_logs=true`:

```julia
Sentry.Logs.info("User {user} logged in"; user="ada", attributes=(; plan="pro"))
```

Functions: `trace`, `debug`, `info`, `warn` (also `warning`), `error`, `fatal`.
"""
module Logs
const Sentry = parentmodule(@__MODULE__)
for (fname, level) in ((:trace, "trace"), (:debug, "debug"), (:info, "info"), (:warn, "warn"),
                       (:warning, "warn"), (:error, "error"), (:fatal, "fatal"))
    num = getfield(Sentry.LOG_SEVERITIES, Symbol(level))
    @eval $fname(template; attributes=nothing, kwargs...) =
        Sentry.capture_log($level, $num, template; attributes=attributes, kwargs...)
end
end

"""
    Sentry.Metrics

Metrics, attached to the active trace:

```julia
Sentry.Metrics.count("checkout.completed", 1; attributes=(; region="eu"))
Sentry.Metrics.gauge("queue.depth", 42)
Sentry.Metrics.distribution("request.duration", 0.25; unit="second")
```
"""
module Metrics
const Sentry = parentmodule(@__MODULE__)
count(name, value=1; unit=nothing, attributes=nothing) = Sentry.capture_metric(name, "counter", value; unit, attributes)
gauge(name, value; unit=nothing, attributes=nothing) = Sentry.capture_metric(name, "gauge", value; unit, attributes)
distribution(name, value; unit=nothing, attributes=nothing) = Sentry.capture_metric(name, "distribution", value; unit, attributes)
end

##############################
# * Logging integration
#----------------------------

"""
    LoggingIntegration(; level=Logging.Info, event_level=Logging.Error, sentry_logs_level=Logging.Info)

Connects Julia's logging to sentry by wrapping the global logger: messages at
`level` or above become breadcrumbs, messages at `event_level` or above are
sent as events (with the stack trace when an `exception` is attached), and,
when `enable_logs=true`, messages at `sentry_logs_level` or above are sent as
sentry logs. Set a level to `nothing` to turn that part off.
"""
Base.@kwdef struct LoggingIntegration <: Integration
    level::Union{Nothing,LogLevel} = Logging.Info
    event_level::Union{Nothing,LogLevel} = Logging.Error
    sentry_logs_level::Union{Nothing,LogLevel} = Logging.Info
end

"""
A logger that feeds sentry, and passes every message on to the logger it wraps.
"""
struct SentryLogger <: AbstractLogger
    parent::AbstractLogger
end

const _IGNORED_LOGGERS = Set{String}()

"""
    ignore_logger(mod)

Stops the logging integration from recording messages logged from the module
`mod` (a `Module` or its name).
"""
ignore_logger(mod) = (push!(_IGNORED_LOGGERS, string(mod)); nothing)

function setup!(::LoggingIntegration, ::Client)
    current = global_logger()
    current isa SentryLogger || global_logger(SentryLogger(current))
    return nothing
end

function teardown!(::LoggingIntegration, ::Client)
    current = global_logger()
    current isa SentryLogger && global_logger(current.parent)
    return nothing
end

function _logging_config()
    client = get_client()
    client === nothing && return nothing
    return get_integration(client, LoggingIntegration)
end

function Logging.min_enabled_level(l::SentryLogger)
    parent = Logging.min_enabled_level(l.parent)
    cfg = _logging_config()
    cfg === nothing && return parent
    levels = LogLevel[parent]
    cfg.level === nothing || push!(levels, cfg.level)
    cfg.event_level === nothing || push!(levels, cfg.event_level)
    client = get_client()
    if cfg.sentry_logs_level !== nothing && client !== nothing && client.options.enable_logs
        push!(levels, cfg.sentry_logs_level)
    end
    return minimum(levels)
end

Logging.shouldlog(::SentryLogger, level, _module, group, id) = true
Logging.catch_exceptions(l::SentryLogger) = Logging.catch_exceptions(l.parent)

function Logging.handle_message(l::SentryLogger, level, message, _module, group, id, file, line; kwargs...)
    if level isa LogLevel && !(_module isa Module && (_module === Sentry || parentmodule(_module) === Sentry))
        try
            _record_log_message(level, message, _module, file, line, kwargs)
        catch exc
            _report_internal_exception(exc, catch_backtrace()) # COV_EXCL_LINE
        end
    end
    parent = l.parent
    if level >= Logging.min_enabled_level(parent) && Logging.shouldlog(parent, level, _module, group, id)
        Logging.handle_message(parent, level, message, _module, group, id, file, line; kwargs...)
    end
    return nothing
end

const _LOGGING_SKIP_KWARGS = (:exception, :maxlog, :_id, :_file, :_line, :_group, :_module)

function _record_log_message(level::LogLevel, message, _module, file, line, kwargs)
    cfg = _logging_config()
    cfg === nothing && return nothing
    modname = _module === nothing ? "Main" : string(_module)
    (modname in _IGNORED_LOGGERS) && return nothing
    msg = message isa AbstractString ? String(message) : safe_repr(message)
    data = Dict{String,Any}(string(k) => v for (k, v) in kwargs if !(k in _LOGGING_SKIP_KWARGS))
    client = get_client()

    if cfg.event_level !== nothing && level >= cfg.event_level
        exc = get(kwargs, :exception, nothing)
        if exc !== nothing
            stack = _exception_stack(exc)
            event, hint = event_from_exception(stack, client.options; handled=true, mechanism_type="logging")
        else
            event, hint = Dict{String,Any}(), Dict{String,Any}()
        end
        event["level"] = sentry_level(level)
        event["logger"] = modname
        event["logentry"] = Dict{String,Any}("message" => msg, "formatted" => msg)
        isempty(data) || (event["extra"] = copy(data))
        capture_event(event; hint=hint)
    elseif cfg.level !== nothing && level >= cfg.level
        crumb = Dict{String,Any}("type" => "log", "level" => sentry_level(level), "category" => modname,
                                 "message" => msg)
        isempty(data) || (crumb["data"] = copy(data))
        add_breadcrumb(crumb; hint=Dict{String,Any}("log_record" => (; level, message, _module, file, line)))
    end

    if client.options.enable_logs && cfg.sentry_logs_level !== nothing && level >= cfg.sentry_logs_level
        text, num = log_severity(level)
        attrs = Dict{String,Any}("logger.name" => modname)
        file === nothing || (attrs["code.file.path"] = string(file))
        line === nothing || (attrs["code.line.number"] = line)
        for (k, v) in data
            attrs[k] = v
        end
        capture_log(text, num, msg; attributes=attrs, _origin="auto.log.julia")
    end
    return nothing
end

function _exception_stack(exc)
    if exc isa Tuple && length(exc) == 2
        return [exc]
    elseif exc isa Exception
        stack = current_exceptions()
        if !isempty(stack) && last(stack)[1] === exc
            return stack
        end
        return [(exc, nothing)]
    elseif exc isa Base.ExceptionStack || exc isa AbstractVector
        return exc
    end
    return [(ErrorException(safe_repr(exc)), nothing)]
end
