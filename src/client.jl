##############################
# * Span streaming batcher
#----------------------------

"""
Collects finished spans when `trace_lifecycle="stream"`, sending them in
batches per trace, since every envelope carries the sampling context of one
trace.
"""
mutable struct SpanBatcher
    capture::Any
    record_lost::Any
    buffers::Dict{String,Vector{Dict{String,Any}}}
    dscs::Dict{String,Dict{String,String}}
    lock::ReentrantLock
    timer::Union{Nothing,Timer}
    running::Bool
    max_before_flush::Int
    max_before_drop::Int
    flush_interval::Float64
end

SpanBatcher(capture, record_lost; flush_interval=5.0) =
    SpanBatcher(capture, record_lost, Dict{String,Vector{Dict{String,Any}}}(), Dict{String,Dict{String,String}}(),
                ReentrantLock(), nothing, true, 1000, 2000, flush_interval)

function add!(b::SpanBatcher, span_json::Dict{String,Any}, dsc)
    should_flush = false
    @lock b.lock begin
        b.running || return nothing
        tid = span_json["trace_id"]
        buf = get!(() -> Dict{String,Any}[], b.buffers, tid)
        if length(buf) >= b.max_before_drop
            b.record_lost("queue_overflow", "span", 1)
            return nothing
        end
        push!(buf, span_json)
        dsc === nothing || (b.dscs[tid] = dsc)
        should_flush = length(buf) >= b.max_before_flush
        if b.timer === nothing
            b.timer = Timer(_ -> @ignore_exception(flush!(b)), b.flush_interval; interval=b.flush_interval)
        end
    end
    should_flush && flush!(b)
    return nothing
end

function flush!(b::SpanBatcher)
    buffers, dscs = @lock b.lock begin
        x, d = b.buffers, b.dscs
        b.buffers = Dict{String,Vector{Dict{String,Any}}}()
        b.dscs = Dict{String,Dict{String,String}}()
        (x, d)
    end
    envs = Envelope[]
    for (tid, spans) in buffers
        for chunk in Iterators.partition(spans, 1000)
            headers = Dict{String,Any}("sent_at" => nowstr())
            haskey(dscs, tid) && (headers["trace"] = dscs[tid])
            env = Envelope(headers)
            items = Any[_span_v2_transport(s) for s in chunk]
            push!(env, json_item("span", Dict{String,Any}("version" => 2, "items" => items);
                                 content_type="application/vnd.sentry.items.span.v2+json",
                                 item_count=length(items)))
            push!(envs, env)
        end
    end
    foreach(b.capture, envs)
    return envs
end

function _span_v2_transport(s::Dict{String,Any})
    out = copy(s)
    attrs = get(s, "attributes", nothing)
    if attrs === nothing || isempty(attrs)
        delete!(out, "attributes")
    else
        out["attributes"] = serialize_attributes(attrs)
    end
    return out
end

function kill!(b::SpanBatcher)
    @lock b.lock begin
        b.running = false
        b.timer === nothing || Base.close(b.timer)
        b.timer = nothing
    end
    return nothing
end

##############################
# * Client
#----------------------------

"""
    Client

Holds the options and the transport, and turns captured data into envelopes.
Created by [`init`](@ref); get the active one with [`get_client`](@ref).
"""
mutable struct Client
    options::Options
    dsn::Union{Nothing,Dsn}
    transport::Union{Nothing,AbstractTransport}
    spotlight::Union{Nothing,SpotlightTransport}
    integrations::Dict{String,Any}
    session_flusher::SessionFlusher
    log_batcher::Batcher
    metrics_batcher::Batcher
    span_batcher::Union{Nothing,SpanBatcher}
    monitor::Union{Nothing,Monitor}
    closed::Bool
end

function Base.show(io::IO, c::Client)
    print(io, "Sentry.Client(dsn=", c.dsn === nothing ? "nothing" : repr(string(c.dsn)),
          ", integrations=", sort!(collect(keys(c.integrations))), c.closed ? ", closed" : "", ")")
end

function Client(options::Options)
    dsn = (options.dsn === nothing || options.dsn == "fake") ? nothing : parse_dsn(options.dsn)
    transport = make_transport(options)

    spotlight = nothing
    url = spotlight_url(options.spotlight)
    if url !== nothing
        spotlight = SpotlightTransport(url)
        if options.dsn === nothing
            # Without a DSN, spotlight shows everything.
            sample_all = (_...) -> 1.0
            options.send_default_pii = true
            options.error_sampler = sample_all
            options.traces_sampler = sample_all
            options.profiles_sampler = sample_all
        end
    end

    client = Client(options, dsn, transport, spotlight, Dict{String,Any}(),
                    SessionFlusher(identity), Batcher(; type="", content_type="", category="",
                                                      capture=identity, record_lost=identity, to_transport=identity),
                    Batcher(; type="", content_type="", category="", capture=identity,
                            record_lost=identity, to_transport=identity),
                    nothing, nothing, false)

    capture = env -> capture_envelope(client, env)
    lost = (reason, category, quantity) -> record_lost_event(client, reason, category; quantity=quantity)
    client.session_flusher = SessionFlusher(capture)
    client.log_batcher = LogBatcher(capture, lost)
    client.metrics_batcher = MetricsBatcher(capture, lost)
    has_span_streaming_enabled(options) && (client.span_batcher = SpanBatcher(capture, lost))
    if transport !== nothing && options.enable_backpressure_handling
        client.monitor = Monitor(transport)
    end
    return client
end

is_active(c::Client) = !c.closed
is_active(::Nothing) = false

should_send_default_pii(c::Client) = c.options.send_default_pii
should_send_default_pii(::Nothing) = false
should_send_default_pii() = should_send_default_pii(get_client())

effective_org_id(c::Client) = c.options.org_id !== nothing ? c.options.org_id :
                              (c.dsn === nothing ? nothing : c.dsn.org_id)

get_integration(c::Client, name::AbstractString) = get(c.integrations, name, nothing)
get_integration(c::Client, ::Type{T}) where {T} = get(c.integrations, integration_identifier(T), nothing)
get_integration(::Nothing, _) = nothing

function capture_envelope(c::Client, env::Envelope)
    c.spotlight === nothing || capture_envelope(c.spotlight, env)
    c.transport === nothing || capture_envelope(c.transport, env)
    return nothing
end

function record_lost_event(c::Client, reason, category; quantity::Integer=1)
    c.transport === nothing || record_lost_event(c.transport, reason, category; quantity=quantity)
    return nothing
end

##############################
# * Event pipeline
#----------------------------

function is_ignored_error(c::Client, hint::Dict{String,Any})
    exc = get(hint, "exception", nothing)
    exc === nothing && return false
    T = typeof(exc)
    name = string(nameof(T))
    full = string(parentmodule(T), ".", name)
    for ignored in c.options.ignore_errors
        if ignored isa AbstractString || ignored isa Symbol
            s = string(ignored)
            (s == name || s == full) && return true
        elseif ignored isa Type
            exc isa ignored && return true
        elseif ignored isa Function
            ignored(exc) === true && return true
        end
    end
    return false
end

function should_sample_error(c::Client, event, hint)
    sampler = c.options.error_sampler
    rate = if sampler !== nothing
        try
            call_flexible(sampler, event, hint)
        catch exc
            _report_internal_exception(exc, catch_backtrace())
            1.0
        end
    else
        c.options.sample_rate
    end
    if !(rate isa Real)
        sdk_warn("The error_sampler returned an invalid value; sampling the event")
        return true
    end
    if rate < 1 && rand() >= rate
        record_lost_event(c, "sample_rate", "error")
        return false
    end
    return true
end

const DATABAG_KEYS = ("extra", "user")

"""
Lowers an event to JSON-safe values, limiting the user supplied parts
(databags) in depth and breadth.
"""
function serialize_event(event::AbstractDict, options::Options)
    opts = SerializeOptions(options.max_value_length, options.custom_repr)
    bag(x) = serialize_value(x; databag=true, options=opts)
    plain(x) = serialize_value(x; databag=false, options=opts)
    out = Dict{String,Any}()
    for (k, v) in event
        out[k] = if k in DATABAG_KEYS
            bag(v)
        elseif k == "contexts" && v isa AbstractDict
            Dict{String,Any}(string(ck) => bag(cv) for (ck, cv) in v)
        elseif k == "tags" && v isa AbstractDict
            Dict{String,Any}(string(tk) => strip_string(tv isa AbstractString ? tv : string(tv), 200) for (tk, tv) in v)
        elseif k == "breadcrumbs" && v isa AbstractDict
            Dict{String,Any}("values" => Any[_ser_with_databag(c, "data", plain, bag) for c in get(v, "values", ())])
        elseif k == "spans" && v isa AbstractVector
            Any[_ser_with_databag(s, "data", plain, bag) for s in v]
        elseif k == "request" && v isa AbstractDict
            _ser_with_databag(v, "data", plain, bag)
        else
            plain(v)
        end
    end
    return out
end

function _ser_with_databag(d, key, plain, bag)
    d isa AbstractDict || return plain(d)
    out = Dict{String,Any}()
    for (k, v) in d
        out[string(k)] = string(k) == key ? bag(v) : plain(v)
    end
    return out
end

function prepare_event(c::Client, event::Dict{String,Any}, hint::Dict{String,Any}, scope)
    haskey(event, "timestamp") || (event["timestamp"] = time())
    ty = get(event, "type", nothing)
    is_transaction = ty == "transaction"
    is_checkin = ty == "check_in"

    if scope !== nothing
        spans_before = length(get(event, "spans", ()))
        new_event = apply_to_event(scope, event, hint, c.options)
        if new_event === nothing
            record_lost_event(c, "event_processor", is_transaction ? "transaction" : "error")
            is_transaction && record_lost_event(c, "event_processor", "span"; quantity=spans_before + 1)
            return nothing
        end
        event = new_event
        if is_transaction
            delta = spans_before - length(get(event, "spans", ()))
            delta > 0 && record_lost_event(c, "event_processor", "span"; quantity=delta)
            dropped = pop!(event, "_dropped_spans", 0)
            dropped > 0 && record_lost_event(c, "buffer_overflow", "span"; quantity=dropped)
        end
    end

    if !is_transaction && !is_checkin && c.options.attach_stacktrace &&
       !haskey(event, "exception") && !haskey(event, "stacktrace") && !haskey(event, "threads")
        @ignore_exception begin
            event["threads"] = Dict{String,Any}("values" => Any[Dict{String,Any}(
                "stacktrace" => current_stacktrace(c.options), "crashed" => false, "current" => true)])
        end
    end

    for (key, val) in (("release", c.options.release), ("environment", c.options.environment),
                       ("server_name", c.options.server_name), ("dist", c.options.dist))
        if get(event, key, nothing) === nothing && val !== nothing
            event[key] = strip(val)
        end
    end
    if get(event, "sdk", nothing) === nothing
        event["sdk"] = sdk_info(c)
    end
    get(event, "platform", nothing) === nothing && (event["platform"] = PLATFORM)

    # Scrub the serialized copy, which never shares containers with user data.
    event = serialize_event(event, c.options)
    scrubber = c.options.event_scrubber
    scrubber === nothing || scrub_event!(scrubber, event)

    if !is_transaction && c.options.before_send !== nothing
        new_event = nothing
        raised = false
        try
            new_event = call_flexible(c.options.before_send, event, hint)
        catch exc
            raised = true
            _report_internal_exception(exc, catch_backtrace())
        end
        if new_event === nothing
            sdk_debug("before send dropped event")
            record_lost_event(c, raised ? "callback_error" : "before_send", "error")
            haskey(event, "exception") && reset_dedupe!()
            return nothing
        end
        event = new_event
    end

    if is_transaction && c.options.before_send_transaction !== nothing
        spans_before = length(get(event, "spans", ()))
        new_event = nothing
        raised = false
        try
            new_event = call_flexible(c.options.before_send_transaction, event, hint)
        catch exc
            raised = true
            _report_internal_exception(exc, catch_backtrace())
        end
        if new_event === nothing
            sdk_debug("before send transaction dropped event")
            reason = raised ? "callback_error" : "before_send"
            record_lost_event(c, reason, "transaction")
            record_lost_event(c, reason, "span"; quantity=spans_before + 1)
            return nothing
        end
        delta = spans_before - length(get(new_event, "spans", ()))
        delta > 0 && record_lost_event(c, "before_send", "span"; quantity=delta)
        event = new_event
    end
    return event
end

function sdk_info(c::Client)
    return Dict{String,Any}(
        "name" => SDK_NAME,
        "version" => string(VERSION),
        "packages" => Any[Dict{String,Any}("name" => "pkg:julia/Sentry", "version" => string(VERSION))],
        "integrations" => sort!(collect(keys(c.integrations))),
    )
end

function update_session_from_event!(session::Session, event::AbstractDict)
    crashed = false
    errored = false
    exc = get(event, "exception", nothing)
    values = exc isa AbstractDict ? get(exc, "values", ()) : ()
    if !isempty(values)
        errored = true
        for v in values
            mech = get(v, "mechanism", nothing)
            if mech isa AbstractDict && get(mech, "handled", true) === false
                crashed = true
                break
            end
        end
    end
    user_agent = nothing
    if session.user_agent === nothing
        req = get(event, "request", nothing)
        headers = req isa AbstractDict ? get(req, "headers", nothing) : nothing
        if headers isa AbstractDict
            for (k, v) in headers
                lowercase(string(k)) == "user-agent" && (user_agent = v; break)
            end
        end
    end
    update!(session; status=crashed ? "crashed" : nothing, user=get(event, "user", nothing),
            user_agent=user_agent, errors=session.errors + (errored || crashed))
    return nothing
end

"""
    capture_event(client, event, hint, scope) -> event id or nothing

Runs an event through the scope and the client's processing, and sends it.
"""
function capture_event(c::Client, event::Dict{String,Any}, hint::Dict{String,Any}, scope)
    c.closed && return nothing
    ty = get(event, "type", nothing)
    is_transaction = ty == "transaction"
    is_checkin = ty == "check_in"

    if !is_transaction && is_ignored_error(c, hint)
        return nothing
    end

    profile = pop!(event, "_profile", nothing)
    event_id = get(event, "event_id", nothing)
    event_id === nothing && (event["event_id"] = event_id = generate_uuid4())

    event_opt = prepare_event(c, event, hint, scope)
    event_opt === nothing && return nothing

    session = scope === nothing ? nothing : scope.session
    session === nothing || is_transaction || is_checkin || update_session_from_event!(session, event_opt)

    if !is_transaction && !is_checkin && !should_sample_error(c, event_opt, hint)
        return nothing
    end

    headers = Dict{String,Any}("event_id" => event_opt["event_id"], "sent_at" => nowstr())
    contexts = get(event_opt, "contexts", nothing)
    if contexts isa AbstractDict
        trace = get(contexts, "trace", nothing)
        if trace isa AbstractDict
            dsc = pop!(trace, "dynamic_sampling_context", nothing)
            dsc isa AbstractDict && !isempty(dsc) && (headers["trace"] = dsc)
        end
    end
    c.dsn === nothing || (headers["dsn"] = string(c.dsn))

    env = Envelope(headers)
    if is_transaction
        push!(env, json_item("transaction", event_opt))
        profile === nothing || @ignore_exception push!(env, json_item("profile", profile_to_json(profile, event_opt, c.options)))
    elseif is_checkin
        push!(env, json_item("check_in", event_opt))
    else
        push!(env, json_item("event", event_opt))
    end
    for a in get(hint, "attachments", ())
        try
            push!(env, to_envelope_item(a))
        catch exc
            _report_internal_exception(exc, catch_backtrace())
        end
    end

    capture_envelope(c, env)
    return (c.transport === nothing && c.spotlight === nothing) ? nothing : event_id
end

"""Sends a log or metric, after `before_send_log` or `before_send_metric`."""
function capture_telemetry(c::Client, item::Dict{String,Any}, ty::Symbol, scope)
    c.closed && return nothing
    scope === nothing || apply_to_telemetry!(scope, item)
    if ty === :log
        before, category, batcher = c.options.before_send_log, "log_item", c.log_batcher
    else
        before, category, batcher = c.options.before_send_metric, "trace_metric", c.metrics_batcher
    end
    if before !== nothing
        new_item = nothing
        try
            new_item = call_flexible(before, item, Dict{String,Any}())
        catch exc
            _report_internal_exception(exc, catch_backtrace())
            record_lost_event(c, "callback_error", category)
            return nothing
        end
        if new_item === nothing
            record_lost_event(c, "before_send", category)
            return nothing
        end
        item = new_item
    end
    add!(batcher, item)
    return nothing
end

"""Queues a finished span, when spans are streamed."""
function capture_span(c::Client, span::Span)
    c.span_batcher === nothing && return nothing
    json = span_to_v2_json(span, c.options)
    before = c.options.before_send_span
    if before !== nothing
        # Spans can be changed, but not dropped, by before_send_span.
        try
            new = call_flexible(before, json, Dict{String,Any}())
            if new isa AbstractDict && haskey(new, "name")
                json["name"] = new["name"]
                json["attributes"] = Dict{String,Any}(string(k) => format_attribute(v)
                                                      for (k, v) in get(new, "attributes", Dict()))
            end
        catch exc
            _report_internal_exception(exc, catch_backtrace())
        end
    end
    b = get_baggage(span)
    add!(c.span_batcher, json, b === nothing ? nothing : dynamic_sampling_context(b))
    return nothing
end

function capture_session(c::Client, session::Session)
    if session.release === nothing
        sdk_debug("Discarded session update because of missing release")
        return nothing
    end
    add_session!(c.session_flusher, session)
    return nothing
end

##############################
# * Flush and close
#----------------------------

function flush_components(c::Client)
    @ignore_exception flush!(c.session_flusher)
    @ignore_exception flush!(c.log_batcher)
    @ignore_exception flush!(c.metrics_batcher)
    c.span_batcher === nothing || @ignore_exception flush!(c.span_batcher)
    return nothing
end

"""
    flush(client; timeout=client.options.shutdown_timeout) -> Bool

Waits for everything captured so far to be sent. Returns false on timeout.
"""
function flush_client(c::Client; timeout=nothing)
    t = timeout === nothing ? c.options.shutdown_timeout : Float64(timeout)
    flush_components(c)
    ok = true
    c.spotlight === nothing || (ok &= flush_transport(c.spotlight, t))
    c.transport === nothing || (ok &= flush_transport(c.transport, t))
    return ok
end

"""Flushes, then shuts the client down."""
function close_client(c::Client; timeout=nothing)
    c.closed && return nothing
    t = timeout === nothing ? c.options.shutdown_timeout : Float64(timeout)
    flush_components(c)
    c.closed = true
    kill!(c.session_flusher)
    kill!(c.log_batcher)
    kill!(c.metrics_batcher)
    c.span_batcher === nothing || kill!(c.span_batcher)
    c.monitor === nothing || kill!(c.monitor)
    for i in values(c.integrations)
        @ignore_exception teardown!(i, c)
    end
    c.spotlight === nothing || kill_transport(c.spotlight, t)
    if c.transport !== nothing
        flush_transport(c.transport, t)
        kill_transport(c.transport, t)
    end
    return nothing
end
