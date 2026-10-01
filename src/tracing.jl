##############################
# * Spans
#----------------------------

# Where a transaction name came from; sentry treats url names as low quality.
const TRANSACTION_SOURCES = ("custom", "url", "route", "view", "component", "task")
const LOW_QUALITY_TRANSACTION_SOURCES = ("url",)

const _UNSET = :__sentry_unset

"""
    Span

A timed operation within a trace. The root span of a trace in this process is
a transaction; it collects the spans started within it and is sent to sentry
when it finishes.

Use [`start_transaction`](@ref) and [`start_span`](@ref) to create spans, and
`set_tag`, `set_data`, `set_status` and friends to
annotate them.
"""
mutable struct Span
    trace_id::String
    span_id::String
    parent_span_id::Union{Nothing,String}
    same_process_as_parent::Bool
    op::Union{Nothing,String}
    description::Union{Nothing,String}
    status::Union{Nothing,String}
    origin::String
    start_timestamp::Float64
    start_ns::UInt64
    timestamp::Union{Nothing,Float64}
    tags::Dict{String,Any}
    data::Dict{String,Any}
    measurements::Dict{String,Any}
    flags::Dict{String,Any}
    sampled::Union{Nothing,Bool}
    containing_transaction::Union{Nothing,Span}
    scope::Any
    previous_span::Any
    lock::ReentrantLock

    # Only used for transactions
    is_transaction::Bool
    name::Union{Nothing,String}
    source::String
    baggage::Union{Nothing,Baggage}
    sample_rate::Union{Nothing,Float64}
    sample_rand::Float64
    parent_sampled::Union{Nothing,Bool}
    recorder::Union{Nothing,Vector{Span}}
    max_spans::Int
    dropped_spans::Int
    contexts::Dict{String,Any}
    profile::Any
end

function Base.show(io::IO, s::Span)
    kind = s.is_transaction ? "Transaction" : "Span"
    print(io, "Sentry.", kind, "(")
    s.is_transaction && print(io, "name=", repr(s.name), ", ")
    print(io, "op=", repr(s.op), ", trace_id=", s.trace_id, ", span_id=", s.span_id, ", sampled=", s.sampled, ")")
end

function _new_span(; trace_id=nothing, span_id=nothing, parent_span_id=nothing, same_process_as_parent=true,
                   op=nothing, description=nothing, name=nothing, status=nothing, origin="manual",
                   start_timestamp=nothing, sampled=nothing, containing_transaction=nothing,
                   tags=nothing, data=nothing, is_transaction=false, source="custom", baggage=nothing,
                   parent_sampled=nothing, max_spans=DEFAULT_MAX_SPANS)
    tid = trace_id === nothing ? generate_uuid4() : String(trace_id)
    s = Span(tid, span_id === nothing ? generate_span_id() : String(span_id),
             parent_span_id === nothing ? nothing : String(parent_span_id), same_process_as_parent,
             op === nothing ? nothing : string(op),
             description === nothing ? (is_transaction ? nothing : (name === nothing ? nothing : string(name))) : string(description),
             status, string(origin),
             start_timestamp === nothing ? time() : to_unix(start_timestamp), time_ns(), nothing,
             tags === nothing ? Dict{String,Any}() : _string_dict(tags),
             data === nothing ? Dict{String,Any}() : _string_dict(data),
             Dict{String,Any}(), Dict{String,Any}(), sampled, containing_transaction,
             nothing, _UNSET, ReentrantLock(),
             is_transaction, is_transaction && name !== nothing ? string(name) : nothing, string(source),
             baggage, nothing, 0.0, parent_sampled, nothing, max_spans, 0, Dict{String,Any}(), nothing)
    if is_transaction
        s.containing_transaction = s
        rand_ = baggage === nothing ? nothing : baggage_sample_rand(baggage)
        s.sample_rand = rand_ === nothing ? generate_sample_rand(tid) : rand_
    end
    return s
end

"""
    Transaction(; name, op=nothing, trace_id=nothing, parent_span_id=nothing, ...)

Creates a transaction without starting it; pass it to
[`start_transaction`](@ref) with the `transaction` keyword.
"""
Transaction(; name=nothing, kwargs...) = _new_span(; name=name, is_transaction=true, kwargs...)

"""Starts a child of `parent`, recorded in the parent's transaction."""
function start_child(parent::Span; op=nothing, description=nothing, name=nothing, kwargs...)
    child = _new_span(; trace_id=parent.trace_id, parent_span_id=parent.span_id,
                      op=op, description=something(description, name, Some(nothing)),
                      sampled=parent.sampled, containing_transaction=parent.containing_transaction,
                      kwargs...)
    txn = parent.containing_transaction
    if txn !== nothing && txn.recorder !== nothing
        @lock txn.lock begin
            if length(txn.recorder) >= txn.max_spans
                txn.dropped_spans += 1
            else
                push!(txn.recorder, child)
            end
        end
    end
    return child
end

set_tag(s::Span, key, value) = (@lock s.lock s.tags[string(key)] = value; nothing)
function set_tags(s::Span, tags)
    for (k, v) in pairs(tags)
        set_tag(s, k, v)
    end
    return nothing
end
set_data(s::Span, key, value) = (@lock s.lock s.data[string(key)] = value; nothing)
function update_data(s::Span, data)
    for (k, v) in pairs(data)
        set_data(s, k, v)
    end
    return nothing
end
set_attribute(s::Span, key, value) = set_data(s, key, format_attribute(value))
set_attributes(s::Span, attrs) = (for (k, v) in pairs(attrs); set_attribute(s, k, v); end; nothing)
remove_attribute(s::Span, key) = (@lock s.lock delete!(s.data, string(key)); nothing)
set_status(s::Span, status) = (s.status = string(status); nothing)
set_op(s::Span, op) = (s.op = string(op); nothing)
set_description(s::Span, d) = (s.description = string(d); nothing)
function set_name(s::Span, name; source=nothing)
    if s.is_transaction
        s.name = string(name)
        source === nothing || (s.source = string(source))
    else
        s.description = string(name)
    end
    return nothing
end
function set_flag(s::Span, flag, result::Bool)
    @lock s.lock begin
        if length(s.flags) < SPAN_FLAG_CAPACITY || haskey(s.flags, flag)
            s.flags[string(flag)] = result
        end
    end
    return nothing
end

"""
    set_measurement(span, name, value, unit="")

Records a measurement (such as a count or duration) on a transaction.
"""
function set_measurement(s::Span, name, value, unit="")
    txn = something(s.containing_transaction, s)
    @lock txn.lock txn.measurements[string(name)] = Dict{String,Any}("value" => value, "unit" => string(unit))
    return nothing
end

"""Sets a context (such as `"response"`) on a transaction."""
set_context(s::Span, key, value) = (@lock s.lock something(s.containing_transaction, s).contexts[string(key)] = value; nothing)

"""Sets the HTTP status of the request the span represents, and its status to match."""
function set_http_status(s::Span, status::Integer)
    set_tag(s, "http.status_code", string(status))
    set_data(s, "http.response.status_code", status)
    set_status(s, span_status_from_http_code(status))
    s.is_transaction && set_context(s, "response", Dict{String,Any}("status_code" => status))
    return nothing
end

is_success(s::Span) = s.status == "ok"

function span_status_from_http_code(code::Integer)
    code < 400 && return "ok"
    if code < 500
        code == 401 && return "unauthenticated"
        code == 403 && return "permission_denied"
        code == 404 && return "not_found"
        code == 409 && return "already_exists"
        code == 413 && return "failed_precondition"
        code == 429 && return "resource_exhausted"
        return "invalid_argument"
    elseif code < 600
        code == 501 && return "unimplemented"
        code == 503 && return "unavailable"
        code == 504 && return "deadline_exceeded"
        return "internal_error"
    end
    return "unknown_error"
end

function to_traceparent(s::Span)
    tp = "$(s.trace_id)-$(s.span_id)"
    s.sampled === nothing && return tp
    return tp * (s.sampled ? "-1" : "-0")
end

"""The baggage of the span's transaction, populated (and frozen) on first use."""
function get_baggage(s::Span)
    txn = s.containing_transaction
    txn === nothing && return nothing
    if txn.baggage === nothing || txn.baggage.mutable
        txn.baggage = baggage_from_transaction(txn)
    end
    return txn.baggage
end

function iter_headers(s::Span)
    s.containing_transaction === nothing && return Pair{String,String}[]
    out = Pair{String,String}[SENTRY_TRACE_HEADER => to_traceparent(s)]
    b = serialize_baggage(get_baggage(s))
    isempty(b) || push!(out, BAGGAGE_HEADER => b)
    return out
end

function span_trace_context(s::Span)
    rv = Dict{String,Any}("trace_id" => s.trace_id, "span_id" => s.span_id, "origin" => s.origin)
    s.parent_span_id === nothing || (rv["parent_span_id"] = s.parent_span_id)
    s.op === nothing || (rv["op"] = s.op)
    s.description === nothing || (rv["description"] = s.description)
    s.status === nothing || (rv["status"] = s.status)
    if s.containing_transaction !== nothing
        rv["dynamic_sampling_context"] = dynamic_sampling_context(get_baggage(s))
    end
    if s.is_transaction && !isempty(s.data)
        rv["data"] = copy(s.data)
    end
    return rv
end

function span_to_json(s::Span)
    rv = Dict{String,Any}(
        "trace_id" => s.trace_id,
        "span_id" => s.span_id,
        "same_process_as_parent" => s.same_process_as_parent,
        "start_timestamp" => s.start_timestamp,
        "timestamp" => s.timestamp,
        "origin" => s.origin,
    )
    s.parent_span_id === nothing || (rv["parent_span_id"] = s.parent_span_id)
    s.op === nothing || (rv["op"] = s.op)
    s.description === nothing || (rv["description"] = s.description)
    if s.status !== nothing
        rv["status"] = s.status
        s.tags["status"] = s.status
    end
    isempty(s.measurements) || (rv["measurements"] = copy(s.measurements))
    isempty(s.tags) || (rv["tags"] = copy(s.tags))
    data = merge(s.flags, s.data)
    isempty(data) || (rv["data"] = data)
    return rv
end

"""
Converts a span to the streamed (v2) span format, where tags, data and the
other properties become attributes.
"""
function span_to_v2_json(s::Span, options)
    txn = s.containing_transaction
    attrs = Dict{String,Any}()
    for (k, v) in s.data
        attrs[k] = format_attribute(v)
    end
    for (k, v) in s.tags
        attrs[k] = format_attribute(v)
    end
    s.op === nothing || (attrs["sentry.op"] = s.op)
    attrs["sentry.origin"] = s.origin
    attrs["sentry.sdk.name"] = SDK_NAME
    attrs["sentry.sdk.version"] = string(VERSION)
    if options !== nothing
        options.release === nothing || (attrs["sentry.release"] = options.release)
        options.environment === nothing || (attrs["sentry.environment"] = options.environment)
    end
    if txn !== nothing
        attrs["sentry.segment.id"] = txn.span_id
        txn.name === nothing || (attrs["sentry.segment.name"] = txn.name)
        s === txn && (attrs["sentry.segment.name.source"] = txn.source)
    end
    name = s.is_transaction ? s.name : s.description
    rv = Dict{String,Any}(
        "trace_id" => s.trace_id,
        "span_id" => s.span_id,
        "name" => something(name, s.op, "<unlabeled span>"),
        "status" => (s.status === nothing || s.status == "ok") ? "ok" : "error",
        "is_segment" => s.is_transaction,
        "start_timestamp" => s.start_timestamp,
        "attributes" => attrs,
    )
    s.timestamp === nothing || (rv["end_timestamp"] = s.timestamp)
    s.parent_span_id === nothing || (rv["parent_span_id"] = s.parent_span_id)
    return rv
end

##############################
# * Baggage population
#----------------------------

function baggage_from_propagation_context(p::PropagationContext)
    client = get_client()
    client === nothing && return Baggage()
    items = Dict{String,String}("trace_id" => trace_id!(p))
    opts = client.options
    opts.environment === nothing || (items["environment"] = opts.environment)
    opts.release === nothing || (items["release"] = opts.release)
    if client.dsn !== nothing
        items["public_key"] = client.dsn.public_key
    end
    org = effective_org_id(client)
    org === nothing || (items["org_id"] = org)
    if opts.traces_sample_rate !== nothing && opts.traces_sample_rate > 0
        items["sample_rate"] = string(opts.traces_sample_rate)
    end
    return Baggage(items; mutable=false)
end

function baggage_from_transaction(txn::Span)
    client = get_client()
    client === nothing && return Baggage()
    items = Dict{String,String}("trace_id" => txn.trace_id, "sample_rand" => format_sample_rand(txn.sample_rand))
    opts = client.options
    opts.environment === nothing || (items["environment"] = opts.environment)
    opts.release === nothing || (items["release"] = opts.release)
    client.dsn === nothing || (items["public_key"] = client.dsn.public_key)
    org = effective_org_id(client)
    org === nothing || (items["org_id"] = org)
    if txn.name !== nothing && !(txn.source in LOW_QUALITY_TRANSACTION_SOURCES)
        items["transaction"] = txn.name
    end
    txn.sample_rate === nothing || (items["sample_rate"] = string(txn.sample_rate))
    txn.sampled === nothing || (items["sampled"] = txn.sampled ? "true" : "false")
    # Items the user put into a mutable baggage take precedence.
    if txn.baggage !== nothing
        merge!(items, txn.baggage.sentry_items)
    end
    return Baggage(items; mutable=false)
end

##############################
# * Sampling
#----------------------------

# Samplers from before traces_sampler received a sampling context.
struct NoSamples end
Base.@kwdef struct RatioSampler
    ratio::Float64
    function RatioSampler(x)
        @assert 0 <= x <= 1
        new(x)
    end
end

sample_rate_from(::NoSamples, ctx) = 0.0
sample_rate_from(s::RatioSampler, ctx) = s.ratio
sample_rate_from(s::Real, ctx) = s
sample_rate_from(f, ctx) = call_flexible(f, ctx)

function is_valid_sample_rate(rate)
    rate isa Bool && return true
    rate isa Real || return false
    return isfinite(rate) && 0 <= rate <= 1
end

"""
Decides whether a transaction is sampled, by (in order of precedence) an
explicit `sampled` argument, `traces_sampler`, the parent's decision, or
`traces_sample_rate`.
"""
function set_initial_sampling_decision!(txn::Span, sampling_context::Dict{String,Any})
    client = get_client()
    if client === nothing || !has_tracing_enabled(client.options)
        txn.sampled = false
        return nothing
    end
    opts = client.options
    if txn.sampled !== nothing
        txn.sample_rate = Float64(txn.sampled)
        return nothing
    end

    rate = try
        if opts.traces_sampler !== nothing
            sample_rate_from(opts.traces_sampler, sampling_context)
        elseif txn.parent_sampled !== nothing
            txn.parent_sampled
        else
            opts.traces_sample_rate
        end
    catch exc
        sdk_warn("traces_sampler raised; unsampling trace")
        _report_internal_exception(exc, catch_backtrace())
        txn.sampled = false
        return nothing
    end

    if !is_valid_sample_rate(rate)
        sdk_warn("Discarding transaction because of invalid sample rate: ", repr(rate))
        txn.sampled = false
        return nothing
    end

    txn.sample_rate = Float64(rate)
    if client.monitor !== nothing
        txn.sample_rate /= 2.0^client.monitor.downsample_factor
    end
    if txn.sample_rate == 0
        sdk_debug("Discarding transaction ", repr(txn.name), " because the sample rate is 0")
        txn.sampled = false
        return nothing
    end
    txn.sampled = txn.sample_rand < txn.sample_rate
    txn.sampled || sdk_debug("Discarding transaction ", repr(txn.name), " because it is not in the random sample")
    return nothing
end

##############################
# * Starting and finishing
#----------------------------

function _sampling_context(txn::Span, custom)
    ctx = Dict{String,Any}(
        "transaction_context" => Dict{String,Any}("name" => txn.name, "op" => txn.op,
                                                  "trace_id" => txn.trace_id, "source" => txn.source,
                                                  "parent_sampled" => txn.parent_sampled),
        "parent_sampled" => txn.parent_sampled,
    )
    custom === nothing || merge!(ctx, _string_dict(custom))
    return ctx
end

"""
    start_transaction(f; name, op=nothing, kwargs...)
    start_transaction(; name, op=nothing, kwargs...) -> Span

Starts a transaction, the root of the spans in this process for one unit of
work. With a function, the transaction is active while `f(transaction)` runs,
is marked as failed if it throws, and finishes when it returns. Without one,
the transaction becomes the active span until [`finish_transaction`](@ref finish_span) is
called on it.

Keywords:
- `name`, `op`, `description`, `source` (one of `"custom"`, `"url"`, `"route"`,
  `"view"`, `"component"`, `"task"`), `origin`
- `sampled`: force the sampling decision
- `trace_id`, `parent_span_id`: continue an existing trace (see also
  [`continue_trace`](@ref)); `trace_id=nothing` means "do not trace"
- `tags`, `data`: initial tags and data
- `custom_sampling_context`: passed to `traces_sampler`
- `transaction`: a transaction made with [`Transaction`](@ref) or
  [`continue_trace`](@ref), started instead of a new one

For compatibility with earlier versions of Sentry.jl, calling it without a
`name` inside an active span starts a child span instead.
"""
function start_transaction(f::Function; kwargs...)
    return new_scope() do scope
        span = start_transaction(; kwargs..., activate=false)
        scope.span = span
        run_in_span(f, span)
    end
end

function run_in_span(f, span::Span)
    try
        return call_flexible(f, span)
    catch
        span.status === nothing && set_status(span, "internal_error")
        rethrow()
    finally
        finish(span)
    end
end

function start_transaction(; name=nothing, op=nothing, description=nothing, source=nothing,
                           origin="manual", sampled=nothing, trace_id=:auto, parent_span_id=nothing,
                           parent_sampled=nothing, baggage=nothing, tags=nothing, data=nothing,
                           custom_sampling_context=nothing, start_timestamp=nothing,
                           transaction=nothing, force_new=nothing, activate::Bool=true)
    scope = get_current_scope()

    # Legacy behaviour: a nameless transaction inside an active span is a child span.
    if transaction === nothing && name === nothing && force_new !== true && scope.span isa Span
        return start_span(; op=op, description=description, tags=tags, data=data,
                          origin=origin, start_timestamp=start_timestamp, activate=activate)
    end

    client = get_client()
    txn = if transaction !== nothing
        transaction
    else
        inhibit = trace_id === nothing
        Transaction(; name=something(name, Some(nothing)), op=op, description=description,
                    source=something(source, "custom"), origin=origin,
                    trace_id=(trace_id === :auto || trace_id === nothing) ? nothing : trace_id,
                    parent_span_id=parent_span_id, parent_sampled=parent_sampled, baggage=baggage,
                    sampled=inhibit ? false : sampled, tags=tags, data=data,
                    start_timestamp=start_timestamp,
                    max_spans=client === nothing ? DEFAULT_MAX_SPANS : client.options.max_spans)
    end
    name === nothing || (txn.name = string(name))
    op === nothing || (txn.op = string(op))
    source === nothing || (txn.source = string(source))

    custom = custom_sampling_context
    if custom === nothing
        p = active_propagation_context(scope)
        custom = p.custom_sampling_context
    end
    set_initial_sampling_decision!(txn, _sampling_context(txn, custom))

    if txn.sampled === true
        txn.recorder = Span[]
        client === nothing || maybe_start_profile!(txn, client)
    end
    txn.scope = scope

    if activate
        txn.previous_span = scope.span
        scope.span = txn
    end
    return txn
end

"""
    start_span(f; op=nothing, name=nothing, description=nothing, kwargs...)
    start_span(; op=nothing, name=nothing, description=nothing, kwargs...) -> Span

Starts a child of the active span. With a function, the span is active while
`f(span)` runs and finishes when it returns; without one, it stays active
until [`finish_span`](@ref) is called on it.

When no span is active, the span still records timing and propagates the
trace, but is not sent anywhere.
"""
function start_span(f::Function; kwargs...)
    return new_scope() do scope
        span = start_span(; kwargs..., activate=false)
        scope.span = span
        run_in_span(f, span)
    end
end

function start_span(; op=nothing, name=nothing, description=nothing, tags=nothing, data=nothing,
                    attributes=nothing, origin="manual", start_timestamp=nothing, activate::Bool=true)
    scope = get_current_scope()
    parent = scope.span
    desc = something(description, name, Some(nothing))
    span = if parent isa Span
        start_child(parent; op=op, description=desc, tags=tags, data=data, origin=origin,
                    start_timestamp=start_timestamp)
    else
        p = active_propagation_context(scope)
        _new_span(; trace_id=trace_id!(p), parent_span_id=p.span_id, op=op, description=desc,
                  tags=tags, data=data, origin=origin, start_timestamp=start_timestamp)
    end
    attributes === nothing || set_attributes(span, attributes)
    client = get_client()
    if client !== nothing && is_ignored_span(client.options, span)
        # Ignored spans are timed but never recorded.
        txn = span.containing_transaction
        if txn !== nothing && txn.recorder !== nothing
            @lock txn.lock filter!(s -> s !== span, txn.recorder)
        end
        span.sampled = false
    end
    span.scope = scope
    if activate
        span.previous_span = scope.span
        scope.span = span
    end
    return span
end

"""
Whether a span matches `ignore_spans`: strings and regexes are matched
against its name, and dicts with `"name"` and/or `"attributes"` keys against
its name and data.
"""
function is_ignored_span(opts::Options, span::Span)
    isempty(opts.ignore_spans) && return false
    name = something(span.description, span.op, "")
    matches(rule, value) = rule isa Regex ? (value isa AbstractString && occursin(rule, value) &&
                                             match(rule, value).match == value) : rule == value
    for rule in opts.ignore_spans
        if rule isa Union{AbstractString,Regex}
            matches(rule, name) && return true
        elseif rule isa AbstractDict || rule isa NamedTuple
            r = _string_dict(rule)
            name_ok = !haskey(r, "name") || matches(r["name"], name)
            attrs_ok = true
            for (k, v) in get(r, "attributes", Dict())
                if !haskey(span.data, string(k)) || !matches(v, span.data[string(k)])
                    attrs_ok = false
                    break
                end
            end
            name_ok && attrs_ok && return true
        end
    end
    return false
end

"""
    finish(span; end_timestamp=nothing)

Ends a span. Finishing a transaction sends it, along with its finished
spans, if it was sampled. Returns the event id when a transaction was sent.
"""
function finish(span::Span; end_timestamp=nothing, scope=nothing)
    @lock span.lock begin
        if span.timestamp !== nothing
            sdk_debug("Span attempted to be completed twice")
            return nothing
        end
        span.timestamp = end_timestamp === nothing ?
            span.start_timestamp + (time_ns() - span.start_ns) / 1e9 : to_unix(end_timestamp)
    end

    # Restore the span that was active before this one was started.
    if span.previous_span !== _UNSET && span.scope isa Scope && span.scope.span === span
        span.scope.span = span.previous_span
    end
    span.previous_span = _UNSET

    client = get_client()
    client === nothing && return nothing

    if has_span_streaming_enabled(client.options)
        span.sampled === true && capture_span(client, span)
        span.is_transaction && stop_profile!(span, client)
        return nothing
    end

    span.is_transaction || return nothing
    return finish_transaction_event(span, client, scope)
end

function finish_transaction_event(txn::Span, client, scope)
    profile = stop_profile!(txn, client)

    if txn.recorder === nothing
        if txn.sampled === false && has_tracing_enabled(client.options)
            reason = client.monitor !== nothing && client.monitor.downsample_factor > 0 ? "backpressure" : "sample_rate"
            record_lost_event(client, reason, "transaction")
            record_lost_event(client, reason, "span")
        end
        return nothing
    end

    if txn.name === nothing || isempty(txn.name)
        sdk_warn("Transaction has no name, falling back to `<unlabeled transaction>`.")
        txn.name = "<unlabeled transaction>"
    end

    status_code = get(txn.data, "http.response.status_code", nothing)
    if status_code !== nothing && status_code in client.options.trace_ignore_status_codes
        sdk_debug("Discarding transaction because of its status code ", status_code)
        record_lost_event(client, "event_processor", "transaction")
        record_lost_event(client, "event_processor", "span"; quantity=length(txn.recorder) + 1)
        txn.sampled = false
        return nothing
    end

    finished = Dict{String,Any}[]
    for s in txn.recorder
        s.timestamp === nothing && continue
        push!(finished, span_to_json(s))
    end
    unfinished = length(txn.recorder) - length(finished)
    if unfinished > 0 && client.options.debug
        @warn "At least one span didn't complete before the transaction completed"
    end
    dropped = unfinished + txn.dropped_spans
    txn.recorder = nothing

    contexts = copy(txn.contexts)
    contexts["trace"] = span_trace_context(txn)
    if profile !== nothing
        contexts["profile"] = Dict{String,Any}("profile_id" => profile.event_id)
    end

    event = Dict{String,Any}(
        "type" => "transaction",
        "transaction" => txn.name,
        "transaction_info" => Dict{String,Any}("source" => txn.source),
        "contexts" => contexts,
        "tags" => copy(txn.tags),
        "timestamp" => txn.timestamp,
        "start_timestamp" => txn.start_timestamp,
        "spans" => finished,
    )
    isempty(txn.measurements) || (event["measurements"] = copy(txn.measurements))
    dropped > 0 && (event["_dropped_spans"] = dropped)
    profile === nothing || (event["_profile"] = profile)

    use = scope === nothing ? (txn.scope isa Scope ? txn.scope : nothing) : scope
    return capture_event(event; scope=use)
end

"""
    finish_span(span)
    finish_transaction(span)

Finishes a span or transaction started without a function, restoring the span
that was active before it.
"""
finish_span(span::Span) = finish(span)
finish_span(::Nothing) = nothing
finish_transaction(span::Span) = finish(span)
finish_transaction(::Nothing) = nothing
# The two argument form of earlier versions of Sentry.jl.
finish_transaction(span, previous) = finish_transaction(span)

"""
    get_current_span(scope=get_current_scope())

The active span, or `nothing`.
"""
get_current_span(scope::Scope=get_current_scope()) = scope.span

"""
    update_current_span(; op=nothing, name=nothing, attributes=nothing, data=nothing)

Changes the active span.
"""
function update_current_span(; op=nothing, name=nothing, attributes=nothing, data=nothing)
    span = get_current_span()
    span === nothing && return nothing
    op === nothing || set_op(span, op)
    name === nothing || set_name(span, name)
    attributes === nothing || set_attributes(span, attributes)
    data === nothing || update_data(span, data)
    return nothing
end

##############################
# * Trace propagation
#----------------------------

"""
    continue_trace(headers; name=nothing, op=nothing, source=nothing, origin="manual") -> Span
    continue_trace(f, headers; kwargs...)

Continues a trace from incoming `sentry-trace` and `baggage` headers (or a W3C
`traceparent` header). Without a function, returns a transaction to pass to
`start_transaction(; transaction=...)`; with one, runs `f(transaction)` in a
new isolation scope with the transaction active.
"""
function continue_trace(headers; name=nothing, op=nothing, source=nothing, origin="manual")
    p = propagation_context_from_incoming(headers)
    get_isolation_scope().propagation_context = p
    return _transaction_from_propagation_context(p; name, op, source, origin)
end

function continue_trace(f::Function, headers; kwargs...)
    return isolation_scope() do iso
        iso.propagation_context = propagation_context_from_incoming(headers)
        txn = _transaction_from_propagation_context(iso.propagation_context; kwargs...)
        start_transaction(f; transaction=txn)
    end
end

function _transaction_from_propagation_context(p::PropagationContext; name=nothing, op=nothing,
                                               source=nothing, origin="manual")
    client = get_client()
    return Transaction(; name=name, op=op, source=something(source, "custom"), origin=origin,
                       baggage=p.baggage, parent_sampled=p.parent_sampled, trace_id=trace_id!(p),
                       parent_span_id=p.parent_span_id, same_process_as_parent=false,
                       max_spans=client === nothing ? DEFAULT_MAX_SPANS : client.options.max_spans)
end

"""Outgoing trace headers for the active span, or the propagation context."""
function trace_propagation_headers(scope::Scope=get_current_scope())
    client = get_client()
    client === nothing && return Pair{String,String}[]
    client.options.propagate_traces || return Pair{String,String}[]
    span = scope.span
    if has_tracing_enabled(client.options) && span isa Span
        return iter_headers(span)
    end
    return iter_headers(active_propagation_context(scope))
end

"""
    get_traceparent() -> String

The `sentry-trace` header value for the active span or trace.
"""
function get_traceparent(scope::Scope=get_current_scope())
    client = get_client()
    span = scope.span
    if client !== nothing && has_tracing_enabled(client.options) && span isa Span
        return to_traceparent(span)
    end
    return to_traceparent(active_propagation_context(scope))
end

"""
    get_baggage() -> String

The `baggage` header value for the active span or trace.
"""
function get_baggage(scope::Scope=get_current_scope())
    client = get_client()
    span = scope.span
    if client !== nothing && has_tracing_enabled(client.options) && span isa Span
        b = get_baggage(span)
        b === nothing || return serialize_baggage(b)
    end
    return serialize_baggage(get_baggage(active_propagation_context(scope)))
end

"""
    trace_propagation_meta() -> String

HTML `<meta>` tags carrying the trace, for continuing it in a browser SDK.
"""
function trace_propagation_meta(scope::Scope=get_current_scope())
    return join(("<meta name=\"$k\" content=\"$v\">" for (k, v) in trace_propagation_headers(scope)))
end

"""
    should_propagate_trace(url) -> Bool

Whether requests to `url` get trace headers, according to
`trace_propagation_targets`. Requests to sentry itself never do.
"""
function should_propagate_trace(client, url::AbstractString)
    client === nothing && return false
    if client.dsn !== nothing && occursin(client.dsn.host, url) && occursin("/api/", url)
        return false
    end
    return match_any(url, client.options.trace_propagation_targets)
end
should_propagate_trace(url::AbstractString) = should_propagate_trace(get_client(), url)

"""
    add_trace_headers(headers, url) -> headers

Adds the trace headers to a vector of pairs or a dict of outgoing request
headers, when `url` should be traced. Existing sentry baggage is replaced,
and other baggage kept.
"""
function add_trace_headers(headers::AbstractVector, url::AbstractString)
    should_propagate_trace(url) || return headers
    for (k, v) in trace_propagation_headers()
        if k == BAGGAGE_HEADER
            idx = findfirst(p -> lowercase(string(first(p))) == BAGGAGE_HEADER, headers)
            if idx === nothing
                push!(headers, k => v)
            else
                existing = strip_sentry_baggage(string(last(headers[idx])))
                headers[idx] = first(headers[idx]) => (isempty(existing) ? v : existing * "," * v)
            end
        else
            filter!(p -> lowercase(string(first(p))) != k, headers)
            push!(headers, k => v)
        end
    end
    return headers
end

function add_trace_headers(headers::AbstractDict, url::AbstractString)
    pairs_ = Pair{String,String}[string(k) => string(v) for (k, v) in headers]
    add_trace_headers(pairs_, url)
    empty!(headers)
    for (k, v) in pairs_
        headers[k] = v
    end
    return headers
end

##############################
# * @trace
#----------------------------

"""
    @trace function f(args...) ... end
    @trace op="db" function f(args...) ... end
    @trace "name" expr

Runs a function (or an expression) inside a span named after it, so that
calls to it show up in the trace of the active transaction.
"""
macro trace(args...)
    isempty(args) && throw(ArgumentError("@trace needs a function definition or an expression"))
    kws = Pair{Symbol,Any}[]
    rest = Any[]
    for (i, a) in enumerate(args)
        # Any `key=value` before the last argument configures the span.
        if i < length(args) && a isa Expr && a.head == :(=) && a.args[1] isa Symbol
            push!(kws, a.args[1] => a.args[2])
        else
            push!(rest, a)
        end
    end
    haskw(k) = any(p -> p.first == k, kws)
    haskw(:op) || push!(kws, :op => "function")
    # Everything below is escaped as a whole, so it is all in the caller's scope.
    start = GlobalRef(@__MODULE__, :start_span)
    sentry_arg = gensym("span")

    if length(rest) == 1 && _is_function_def(rest[1])
        def = rest[1]
        haskw(:name) || push!(kws, :name => string(__module__, ".", _function_name(def.args[1])))
        params = Expr(:parameters, (Expr(:kw, k, v) for (k, v) in kws)...)
        wrapped = Expr(:block, Expr(:call, start, params, Expr(:->, Expr(:tuple, sentry_arg), def.args[2])))
        return esc(Expr(def.head, def.args[1], wrapped))
    elseif length(rest) == 2
        name, ex = rest
        params = Expr(:parameters, Expr(:kw, :name, name), (Expr(:kw, k, v) for (k, v) in kws)...)
        return esc(Expr(:call, start, params, Expr(:->, Expr(:tuple, sentry_arg), ex)))
    end
    throw(ArgumentError("@trace needs a function definition, or a name and an expression"))
end

function _is_function_def(ex)
    ex isa Expr || return false
    ex.head == :function && length(ex.args) == 2 && return true
    if ex.head == :(=) && ex.args[1] isa Expr
        sig = ex.args[1]
        while sig isa Expr && sig.head in (:where, :(::))
            sig = sig.args[1]
        end
        return sig isa Expr && sig.head == :call
    end
    return false
end

function _function_name(sig)
    while sig isa Expr && sig.head in (:where, :(::))
        sig = sig.args[1]
    end
    if sig isa Expr && sig.head == :call
        f = sig.args[1]
        return f isa Expr && f.head == :. ? string(f.args[end] isa QuoteNode ? f.args[end].value : f.args[end]) : string(f)
    end
    return "anonymous"
end
