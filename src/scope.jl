##############################
# * Baggage
#----------------------------

"""
The W3C `baggage` header, of which the `sentry-` prefixed items form the
Dynamic Sampling Context (DSC) that is sent with events and transactions.
An incoming baggage with sentry items is frozen, so that a trace keeps the
context of the SDK that started it.
"""
mutable struct Baggage
    sentry_items::Dict{String,String}
    third_party_items::String
    mutable::Bool
end
Baggage(items=Dict{String,String}(); third_party_items="", mutable=true) =
    Baggage(Dict{String,String}(items), third_party_items, mutable)

function baggage_from_header(header::Union{Nothing,AbstractString})
    sentry_items = Dict{String,String}()
    third_party = String[]
    mutable = true
    if header !== nothing
        for item in split(header, ',')
            item = strip(item)
            occursin('=', item) || continue
            key, val = split(item, '='; limit=2)
            key, val = strip(key), strip(val)
            if startswith(key, "sentry-")
                sentry_items[URIs.unescapeuri(key[8:end])] = URIs.unescapeuri(val)
                mutable = false
            else
                push!(third_party, item)
            end
        end
    end
    return Baggage(sentry_items, join(third_party, ','), mutable)
end

dynamic_sampling_context(b::Baggage) = copy(b.sentry_items)

function serialize_baggage(b::Baggage; include_third_party::Bool=false)
    items = String["sentry-" * URIs.escapeuri(k) * "=" * URIs.escapeuri(v) for (k, v) in sort!(collect(b.sentry_items))]
    include_third_party && !isempty(b.third_party_items) && push!(items, b.third_party_items)
    return join(items, ',')
end

"""Removes the sentry items from a baggage header, keeping the rest."""
strip_sentry_baggage(header::AbstractString) =
    join(filter(i -> !startswith(strip(i), "sentry-"), split(header, ',')), ',')

function baggage_sample_rand(b::Baggage)
    v = tryparse(Float64, get(b.sentry_items, "sample_rand", ""))
    (v !== nothing && 0 <= v < 1) || return nothing
    return v
end

baggage_sample_rate(b::Baggage) = tryparse(Float64, get(b.sentry_items, "sample_rate", ""))

##############################
# * Propagation context
#----------------------------

"""
The trace that errors and spans are attached to when no span is active, and
which is continued from incoming requests.
"""
mutable struct PropagationContext
    trace_id::Union{Nothing,String}
    span_id::Union{Nothing,String}
    parent_span_id::Union{Nothing,String}
    parent_sampled::Union{Nothing,Bool}
    baggage::Union{Nothing,Baggage}
    custom_sampling_context::Union{Nothing,Dict{String,Any}}
end
PropagationContext() = PropagationContext(nothing, nothing, nothing, nothing, nothing, nothing)

function trace_id!(p::PropagationContext)
    p.trace_id === nothing && (p.trace_id = generate_uuid4())
    return p.trace_id
end
function span_id!(p::PropagationContext)
    p.span_id === nothing && (p.span_id = generate_span_id())
    return p.span_id
end

to_traceparent(p::PropagationContext) = "$(trace_id!(p))-$(span_id!(p))"

function get_baggage(p::PropagationContext)
    p.baggage === nothing && (p.baggage = baggage_from_propagation_context(p))
    return p.baggage
end

function iter_headers(p::PropagationContext)
    out = Pair{String,String}[SENTRY_TRACE_HEADER => to_traceparent(p)]
    b = serialize_baggage(get_baggage(p))
    isempty(b) || push!(out, BAGGAGE_HEADER => b)
    return out
end

const SENTRY_TRACE_REGEX = r"^[ \t]*([0-9a-f]{32})?-?([0-9a-f]{16})?-?([01])?[ \t]*$"
const W3C_TRACEPARENT_REGEX = r"^[ \t]*00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})[ \t]*$"

"""
Parses a `sentry-trace` header into its trace id, parent span id and sampling
flag, or returns nothing when it is malformed.
"""
function extract_sentrytrace_data(header::Union{Nothing,AbstractString})
    (header === nothing || isempty(header)) && return nothing
    if occursin(',', header)
        # Several headers combined into one; use the first non-empty one.
        parts = filter(!isempty, strip.(split(header, ',')))
        isempty(parts) && return nothing
        header = first(parts)
    end
    if startswith(header, "00-") && endswith(header, "-00")
        header = header[4:end-3]
    end
    m = match(SENTRY_TRACE_REGEX, header)
    m === nothing && return nothing
    sampled = m[3] === nothing ? nothing : m[3] != "0"
    return (; trace_id=m[1] === nothing ? nothing : String(m[1]),
            parent_span_id=m[2] === nothing ? nothing : String(m[2]),
            parent_sampled=sampled)
end

"""Parses a W3C `traceparent` header in the same way."""
function extract_w3c_traceparent(header::Union{Nothing,AbstractString})
    (header === nothing || isempty(header)) && return nothing
    m = match(W3C_TRACEPARENT_REGEX, header)
    m === nothing && return nothing
    flags = parse(UInt8, m[3]; base=16)
    return (; trace_id=String(m[1]), parent_span_id=String(m[2]), parent_sampled=(flags & 0x01) == 0x01)
end

"""
Normalizes incoming headers (a `Dict`, pairs, or an `HTTP.Request`'s headers)
to lowercase, dash separated keys, stripping the `HTTP_` prefix of CGI style
environments.
"""
function normalize_incoming_data(incoming)
    data = Dict{String,String}()
    incoming === nothing && return data
    for (k, v) in (incoming isa AbstractDict || incoming isa NamedTuple ? pairs(incoming) : incoming)
        key = string(k)
        startswith(key, "HTTP_") && (key = key[6:end])
        key = lowercase(replace(key, '_' => '-'))
        data[key] = string(v)
    end
    return data
end

function propagation_context_from_incoming(incoming)
    p = PropagationContext()
    data = normalize_incoming_data(incoming)
    trace = extract_sentrytrace_data(get(data, SENTRY_TRACE_HEADER, nothing))
    if trace === nothing
        trace = extract_w3c_traceparent(get(data, W3C_TRACEPARENT_HEADER, nothing))
    end
    trace === nothing && return p

    baggage_header = get(data, BAGGAGE_HEADER, nothing)
    baggage = baggage_header === nothing ? nothing : baggage_from_header(baggage_header)
    should_continue_trace(baggage) || return p

    p.trace_id = trace.trace_id
    p.parent_span_id = trace.parent_span_id
    p.parent_sampled = trace.parent_sampled
    baggage === nothing || (p.baggage = baggage)
    fill_sample_rand!(p)
    return p
end

"""
Makes sure an incoming baggage has a valid `sample_rand`, generating one that
is consistent with the incoming sampling decision when it is missing.
"""
function fill_sample_rand!(p::PropagationContext)
    p.baggage === nothing && return nothing
    baggage_sample_rand(p.baggage) === nothing || return nothing
    lower, upper = sample_rand_range(p.parent_sampled, baggage_sample_rate(p.baggage))
    lower < upper || return nothing
    p.baggage.sentry_items["sample_rand"] = format_sample_rand(generate_sample_rand(trace_id!(p); interval=(lower, upper)))
    return nothing
end

function sample_rand_range(parent_sampled, sample_rate)
    (parent_sampled === nothing || sample_rate === nothing) && return (0.0, 1.0)
    return parent_sampled ? (0.0, sample_rate) : (sample_rate, 1.0)
end

"""
A random number in `[lower, upper)` with six digits of precision, seeded by
the trace id so that every SDK in a trace makes the same sampling decision.
"""
function generate_sample_rand(trace_id::AbstractString; interval=(0.0, 1.0))
    lower, upper = interval
    lower < upper || throw(ArgumentError("Invalid interval: lower must be less than upper"))
    rng = Random.Xoshiro(hash(trace_id))
    lo, hi = floor(Int, lower * 1_000_000), floor(Int, upper * 1_000_000)
    scaled = hi > lo ? rand(rng, lo:(hi - 1)) : lo
    return scaled / 1_000_000
end

format_sample_rand(x::Real) = @sprintf("%.6f", x)

"""Whether an incoming trace may be continued, given the org ids involved."""
function should_continue_trace(baggage::Union{Nothing,Baggage})
    client = get_client()
    client_org = client === nothing ? nothing : effective_org_id(client)
    baggage_org = baggage === nothing ? nothing : get(baggage.sentry_items, "org_id", nothing)
    if client_org !== nothing && baggage_org !== nothing && client_org != baggage_org
        sdk_debug("Starting a new trace because org IDs don't match")
        return false
    end
    strict = client !== nothing && client.options.strict_trace_continuation
    if strict && ((baggage_org !== nothing) != (client_org !== nothing))
        sdk_debug("Starting a new trace because strict trace continuation is enabled and one org ID is missing")
        return false
    end
    return true
end

##############################
# * Feature flags
#----------------------------

"""The most recent flag evaluations, up to `capacity` of them."""
mutable struct FlagBuffer
    capacity::Int
    flags::Vector{Pair{String,Bool}}
    lock::ReentrantLock
end
FlagBuffer(capacity::Integer=DEFAULT_FLAG_CAPACITY) = FlagBuffer(capacity, Pair{String,Bool}[], ReentrantLock())

function set_flag!(b::FlagBuffer, flag::AbstractString, result::Bool)
    @lock b.lock begin
        filter!(p -> p.first != flag, b.flags)
        push!(b.flags, String(flag) => result)
        while length(b.flags) > b.capacity
            popfirst!(b.flags)
        end
    end
    return nothing
end

get_flags(b::FlagBuffer) = @lock b.lock [Dict{String,Any}("flag" => k, "result" => v) for (k, v) in b.flags]
Base.copy(b::FlagBuffer) = @lock b.lock FlagBuffer(b.capacity, copy(b.flags), ReentrantLock())

##############################
# * Scope
#----------------------------

"""
    Scope

Data that is applied to the events captured while it is active: tags, extra
data, contexts, the user, breadcrumbs, attachments and the active span.

There are three kinds: the global scope applies to everything; the isolation
scope is for one unit of work (for example a request, see
[`isolation_scope`](@ref)); and the current scope is the innermost one, which
also holds the active span (see [`new_scope`](@ref)). Scopes are carried into
child tasks automatically.
"""
mutable struct Scope
    lock::ReentrantLock
    type::Symbol
    level::Union{Nothing,String}
    fingerprint::Union{Nothing,Vector{String}}
    transaction::Union{Nothing,String}
    transaction_info::Dict{String,Any}
    user::Union{Nothing,Dict{String,Any}}
    tags::Dict{String,Any}
    contexts::Dict{String,Any}
    extras::Dict{String,Any}
    breadcrumbs::Vector{Dict{String,Any}}
    n_breadcrumbs_truncated::Int
    attachments::Vector{Attachment}
    event_processors::Vector{Any}
    error_processors::Vector{Any}
    span::Any
    propagation_context::Union{Nothing,PropagationContext}
    session::Union{Nothing,Session}
    flags::Union{Nothing,FlagBuffer}
    attributes::Dict{String,Any}
    last_event_id::Union{Nothing,String}
    client::Any
    profile::Any
end

function Scope(type::Symbol=:current)
    s = Scope(ReentrantLock(), type, nothing, nothing, nothing, Dict{String,Any}(), nothing,
              Dict{String,Any}(), Dict{String,Any}(), Dict{String,Any}(), Dict{String,Any}[], 0,
              Attachment[], Any[], Any[], nothing, nothing, nothing, nothing, Dict{String,Any}(),
              nothing, nothing, nothing)
    if type in (:isolation, :global)
        s.propagation_context = PropagationContext()
    end
    return s
end

function Base.show(io::IO, s::Scope)
    print(io, "Sentry.Scope(:", s.type, ", ", length(s.tags), " tags, ", length(s.breadcrumbs), " breadcrumbs")
    s.span === nothing || print(io, ", span=", s.span.span_id)
    print(io, ")")
end

"""Returns a copy of the scope that can be changed without affecting it."""
function fork(s::Scope)
    @lock s.lock begin
        return Scope(ReentrantLock(), s.type, s.level,
                     s.fingerprint === nothing ? nothing : copy(s.fingerprint),
                     s.transaction, copy(s.transaction_info),
                     s.user === nothing ? nothing : copy(s.user),
                     copy(s.tags), copy(s.contexts), copy(s.extras), copy(s.breadcrumbs),
                     s.n_breadcrumbs_truncated, copy(s.attachments), copy(s.event_processors),
                     copy(s.error_processors), s.span, s.propagation_context, s.session,
                     s.flags === nothing ? nothing : copy(s.flags), copy(s.attributes),
                     s.last_event_id, s.client, s.profile)
    end
end

"""Clears everything from the scope."""
function clear!(s::Scope)
    @lock s.lock begin
        s.level = nothing
        s.fingerprint = nothing
        s.transaction = nothing
        empty!(s.transaction_info)
        s.user = nothing
        empty!(s.tags)
        empty!(s.contexts)
        empty!(s.extras)
        empty!(s.breadcrumbs)
        s.n_breadcrumbs_truncated = 0
        empty!(s.attachments)
        empty!(s.event_processors)
        empty!(s.error_processors)
        s.span = nothing
        s.session = nothing
        s.flags = nothing
        empty!(s.attributes)
        s.propagation_context = s.type in (:isolation, :global) ? PropagationContext() : nothing
    end
    return s
end

function update_from_scope!(s::Scope, other::Scope)
    @lock other.lock begin
        other.level === nothing || (s.level = other.level)
        other.fingerprint === nothing || (s.fingerprint = other.fingerprint)
        other.transaction === nothing || (s.transaction = other.transaction)
        merge!(s.transaction_info, other.transaction_info)
        other.user === nothing || (s.user = other.user)
        merge!(s.tags, other.tags)
        merge!(s.contexts, other.contexts)
        merge!(s.extras, other.extras)
        append!(s.breadcrumbs, other.breadcrumbs)
        s.n_breadcrumbs_truncated += other.n_breadcrumbs_truncated
        other.span === nothing || (s.span = other.span)
        append!(s.attachments, other.attachments)
        append!(s.event_processors, other.event_processors)
        append!(s.error_processors, other.error_processors)
        other.profile === nothing || (s.profile = other.profile)
        other.propagation_context === nothing || (s.propagation_context = other.propagation_context)
        other.session === nothing || (s.session = other.session)
        if other.flags !== nothing
            if s.flags === nothing
                s.flags = copy(other.flags)
            else
                for f in get_flags(other.flags)
                    set_flag!(s.flags, f["flag"], f["result"])
                end
            end
        end
        merge!(s.attributes, other.attributes)
    end
    return s
end

"""
Keyword arguments accepted by the capture functions to add data to one event
without changing any scope: `tags`, `extras`, `contexts`, `user`, `level`,
`fingerprint`, `attachments`.
"""
function update_from_kwargs!(s::Scope; user=nothing, level=nothing, extras=nothing, extra=nothing,
                             contexts=nothing, tags=nothing, fingerprint=nothing, attachments=nothing)
    level === nothing || (s.level = sentry_level(level))
    user === nothing || (s.user = _string_dict(user))
    extras === nothing || merge!(s.extras, _string_dict(extras))
    extra === nothing || merge!(s.extras, _string_dict(extra))
    contexts === nothing || merge!(s.contexts, _string_dict(contexts))
    tags === nothing || merge!(s.tags, _string_dict(tags))
    fingerprint === nothing || (s.fingerprint = String[string(f) for f in fingerprint])
    if attachments !== nothing
        for (i, a) in enumerate(attachments)
            push!(s.attachments, a isa Attachment ? a : legacy_attachment(a, i))
        end
    end
    return s
end

# Attachments given as plain values are sent as JSON, as they were before
# attachments could be files.
legacy_attachment(value, i) = Attachment(json=Dict("data" => value), filename="attachment-$i.json")

_string_dict(d::AbstractDict) = Dict{String,Any}(string(k) => v for (k, v) in d)
_string_dict(d::Union{NamedTuple,Base.Pairs}) = Dict{String,Any}(string(k) => v for (k, v) in pairs(d))
_string_dict(d::AbstractVector{<:Pair}) = Dict{String,Any}(string(k) => v for (k, v) in d)

##############################
# * The three scopes
#----------------------------

const _GLOBAL_SCOPE = Ref{Scope}()
const _DEFAULT_ISOLATION_SCOPE = Ref{Scope}()
const _ISOLATION_SCOPE = ScopedValue{Union{Nothing,Scope}}(nothing)
const _CURRENT_SCOPE = ScopedValue{Union{Nothing,Scope}}(nothing)

function _init_scopes!()
    _GLOBAL_SCOPE[] = Scope(:global)
    _DEFAULT_ISOLATION_SCOPE[] = Scope(:isolation)
    return nothing
end

"""The scope that applies to every event."""
get_global_scope() = _GLOBAL_SCOPE[]

"""
The isolation scope of the current unit of work. Tags, the user, breadcrumbs
and the other data set through the top level functions go here.
"""
function get_isolation_scope()
    s = _ISOLATION_SCOPE[]
    return s === nothing ? _DEFAULT_ISOLATION_SCOPE[] : s
end

"""
The current scope, which holds the active span. Outside of any
[`new_scope`](@ref) block every task has one of its own.
"""
function get_current_scope()
    s = _CURRENT_SCOPE[]
    s === nothing || return s
    return get!(() -> Scope(:current), task_local_storage(), :sentry_current_scope)::Scope
end

"""
    new_scope(f)

Runs `f` (optionally passed the new scope) with a fork of the current scope,
so that changes made inside do not leak out. Tasks started inside share it.

```julia
Sentry.new_scope() do scope
    Sentry.set_tag(scope, "in", "here")
    Sentry.capture_message("tagged")
end
```
"""
function new_scope(f)
    forked = fork(get_current_scope())
    return with(() -> call_flexible(f, forked), _CURRENT_SCOPE => forked)
end

"""
    use_scope(f, scope)

Runs `f` with `scope` as the current scope.
"""
use_scope(f, scope::Scope) = with(() -> call_flexible(f, scope), _CURRENT_SCOPE => scope)

"""
    isolation_scope(f)

Runs `f` (optionally passed the new isolation scope) with forks of both the
isolation and the current scope: data set inside is kept apart from everything
else. Use one per request, job or other unit of work.
"""
function isolation_scope(f)
    iso = fork(get_isolation_scope())
    iso.type = :isolation
    cur = fork(get_current_scope())
    cur.type = :current
    return with(() -> call_flexible(f, iso), _ISOLATION_SCOPE => iso, _CURRENT_SCOPE => cur)
end

"""
    use_isolation_scope(f, scope)

Runs `f` with `scope` as the isolation scope.
"""
use_isolation_scope(f, scope::Scope) = with(() -> call_flexible(f, scope), _ISOLATION_SCOPE => scope)

"""
    configure_scope(f)

Calls `f` with the isolation scope. Kept for compatibility with older sentry
SDKs; prefer the top level functions or [`get_isolation_scope`](@ref).
"""
configure_scope(f) = f(get_isolation_scope())

"""
    push_scope(f)

The same as [`new_scope`](@ref). Kept for compatibility with older SDKs.
"""
push_scope(f) = new_scope(f)

"""
Merges the global, isolation and current scope into one for an event, adding
`additional` (a scope, or a function that changes the merged scope) on top.
"""
function merge_scopes(additional=nothing; scope_kwargs...)
    final = fork(get_global_scope())
    final.type = :merged
    iso = get_isolation_scope()
    cur = get_current_scope()
    update_from_scope!(final, iso)
    update_from_scope!(final, cur)
    if additional isa Scope
        additional === iso || additional === cur || update_from_scope!(final, additional)
    elseif additional !== nothing
        additional(final)
    end
    isempty(scope_kwargs) || update_from_kwargs!(final; scope_kwargs...)
    return final
end

"""The propagation context that applies to the scope."""
function active_propagation_context(s::Scope)
    s.propagation_context === nothing || return s.propagation_context
    cur = get_current_scope()
    cur.propagation_context === nothing || return cur.propagation_context
    iso = get_isolation_scope()
    iso.propagation_context === nothing && (iso.propagation_context = PropagationContext())
    return iso.propagation_context
end

##############################
# * Scope setters
#----------------------------

set_tag(s::Scope, key, value) = (@lock s.lock s.tags[string(key)] = value; nothing)
function set_tags(s::Scope, tags)
    @lock s.lock for (k, v) in pairs(tags)
        s.tags[string(k)] = v
    end
    return nothing
end
remove_tag(s::Scope, key) = (@lock s.lock delete!(s.tags, string(key)); nothing)
set_extra(s::Scope, key, value) = (@lock s.lock s.extras[string(key)] = value; nothing)
remove_extra(s::Scope, key) = (@lock s.lock delete!(s.extras, string(key)); nothing)
set_context(s::Scope, key, value) = (@lock s.lock s.contexts[string(key)] = value; nothing)
remove_context(s::Scope, key) = (@lock s.lock delete!(s.contexts, string(key)); nothing)
set_level(s::Scope, level) = (s.level = sentry_level(level); nothing)
set_fingerprint(s::Scope, fp) = (s.fingerprint = fp === nothing ? nothing : String[string(x) for x in fp]; nothing)
function set_user(s::Scope, user)
    s.user = user === nothing ? nothing : _string_dict(user)
    s.session === nothing || update!(s.session; user=s.user)
    return nothing
end
set_attribute(s::Scope, key, value) = (@lock s.lock s.attributes[string(key)] = format_attribute(value); nothing)
function set_attributes(s::Scope, attrs)
    for (k, v) in pairs(attrs)
        set_attribute(s, k, v)
    end
    return nothing
end
remove_attribute(s::Scope, key) = (@lock s.lock delete!(s.attributes, string(key)); nothing)
add_event_processor(s::Scope, f) = (@lock s.lock push!(s.event_processors, f); nothing)
add_error_processor(s::Scope, f) = (@lock s.lock push!(s.error_processors, f); nothing)
clear_breadcrumbs(s::Scope) = (@lock s.lock begin
    empty!(s.breadcrumbs)
    s.n_breadcrumbs_truncated = 0
end; nothing)

function add_attachment(s::Scope; kwargs...)
    a = Attachment(; kwargs...)
    @lock s.lock push!(s.attachments, a)
    return a
end
add_attachment(s::Scope, a::Attachment) = (@lock s.lock push!(s.attachments, a); a)

function set_transaction_name(s::Scope, name; source=nothing)
    s.transaction = string(name)
    source === nothing || (s.transaction_info["source"] = string(source))
    span = s.span
    if span !== nothing && span.containing_transaction !== nothing
        txn = span.containing_transaction
        txn.name = string(name)
        source === nothing || (txn.source = string(source))
    end
    return nothing
end

"""
    add_breadcrumb(scope, crumb=nothing; hint=nothing, kwargs...)

Adds a breadcrumb, given as a dict and/or keyword arguments such as `message`,
`category`, `level`, `type` and `data`.
"""
function add_breadcrumb(s::Scope, crumb=nothing; hint=nothing, kwargs...)
    client = get_client()
    client === nothing && return nothing

    c = crumb === nothing ? Dict{String,Any}() : _string_dict(crumb)
    for (k, v) in kwargs
        c[string(k)] = v
    end
    isempty(c) && return nothing
    haskey(c, "timestamp") || (c["timestamp"] = time())
    haskey(c, "type") || (c["type"] = "default")
    haskey(c, "level") && (c["level"] = sentry_level(c["level"]))
    h = hint === nothing ? Dict{String,Any}() : _string_dict(hint)

    new_crumb = c
    before = client.options.before_breadcrumb
    if before !== nothing
        new_crumb = try
            call_flexible(before, c, h)
        catch exc
            _report_internal_exception(exc, catch_backtrace())
            c
        end
    end
    if new_crumb === nothing
        sdk_debug("before breadcrumb dropped breadcrumb")
        return nothing
    end

    max_crumbs = client.options.max_breadcrumbs
    @lock s.lock begin
        push!(s.breadcrumbs, _string_dict(new_crumb))
        while length(s.breadcrumbs) > max_crumbs
            popfirst!(s.breadcrumbs)
            s.n_breadcrumbs_truncated += 1
        end
    end
    return nothing
end

##############################
# * Applying scopes to events
#----------------------------

"""The `trace` context for an event captured in this scope."""
function get_trace_context(s::Scope)
    client = get_client()
    span = s.span
    if client !== nothing && has_tracing_enabled(client.options) && span !== nothing
        return span_trace_context(span)
    end
    p = active_propagation_context(s)
    ctx = Dict{String,Any}("trace_id" => trace_id!(p), "span_id" => span_id!(p))
    p.parent_span_id === nothing || (ctx["parent_span_id"] = p.parent_span_id)
    ctx["dynamic_sampling_context"] = dynamic_sampling_context(get_baggage(p))
    return ctx
end

function apply_to_event(s::Scope, event::Dict{String,Any}, hint::Dict{String,Any}, options=nothing)
    ty = get(event, "type", nothing)
    is_transaction = ty == "transaction"
    is_check_in = ty == "check_in"

    attachments = get!(() -> Attachment[], hint, "attachments")
    for a in s.attachments
        (!is_transaction || a.add_to_transactions) && push!(attachments, a)
    end

    contexts = get!(() -> Dict{String,Any}(), event, "contexts")
    merge!(contexts, s.contexts)
    if get(contexts, "trace", nothing) === nothing
        contexts["trace"] = get_trace_context(s)
    end

    if is_check_in
        event["contexts"] = Dict{String,Any}("trace" => contexts["trace"])
    else
        s.level === nothing || (event["level"] = s.level)
        if get(event, "fingerprint", nothing) === nothing && s.fingerprint !== nothing
            event["fingerprint"] = s.fingerprint
        end
        if get(event, "user", nothing) === nothing && s.user !== nothing
            event["user"] = copy(s.user)
        end
        if get(event, "transaction", nothing) === nothing && s.transaction !== nothing
            event["transaction"] = s.transaction
        end
        if get(event, "transaction_info", nothing) === nothing && !isempty(s.transaction_info)
            event["transaction_info"] = copy(s.transaction_info)
        end
        if !isempty(s.tags)
            merge!(get!(() -> Dict{String,Any}(), event, "tags"), s.tags)
        end
        if !isempty(s.extras)
            merge!(get!(() -> Dict{String,Any}(), event, "extra"), s.extras)
        end
    end

    if !is_transaction && !is_check_in
        crumbs = get!(() -> Dict{String,Any}(), event, "breadcrumbs")
        values = get!(() -> Any[], crumbs, "values")
        append!(values, s.breadcrumbs)
        try
            sort!(values; by=c -> to_unix(get(c, "timestamp", nothing)))
        catch
        end
        if s.flags !== nothing
            flags = get_flags(s.flags)
            isempty(flags) || (contexts["flags"] = Dict{String,Any}("values" => flags))
        end
    end

    if haskey(hint, "exception")
        for p in s.error_processors
            new_event = try
                call_flexible(p, event, hint["exception"])
            catch exc
                _report_internal_exception(exc, catch_backtrace())
                event
            end
            if new_event === nothing
                sdk_debug("error processor dropped event")
                return nothing
            end
            event = new_event
        end
    end

    if !is_check_in
        for p in vcat(Any[global_event_processors()...], s.event_processors)
            new_event = try
                call_flexible(p, event, hint)
            catch exc
                _report_internal_exception(exc, catch_backtrace())
                event
            end
            if new_event === nothing
                sdk_debug("event processor dropped event")
                return nothing
            end
            event = new_event
        end
    end
    return event
end

"""Adds the scope's trace ids and attributes to a log or metric."""
function apply_to_telemetry!(s::Scope, telemetry::Dict{String,Any})
    ctx = get_trace_context(s)
    get(telemetry, "trace_id", nothing) === nothing && (telemetry["trace_id"] = get(ctx, "trace_id", nothing))
    if get(telemetry, "span_id", nothing) === nothing && s.span !== nothing
        telemetry["span_id"] = s.span.span_id
    end
    attrs = telemetry["attributes"]
    for (k, v) in s.attributes
        haskey(attrs, k) || (attrs[k] = v)
    end
    client = get_client()
    if client !== nothing && client.options.send_default_pii && s.user !== nothing
        for (attr, key) in (("user.id", "id"), ("user.name", "username"),
                            ("user.email", "email"), ("user.ip_address", "ip_address"))
            v = get(s.user, key, nothing)
            v === nothing || haskey(attrs, attr) || (attrs[attr] = format_attribute(v))
        end
    end
    return telemetry
end

# Event processors registered by integrations, applied to every event.
const _GLOBAL_EVENT_PROCESSORS = Any[]
global_event_processors() = _GLOBAL_EVENT_PROCESSORS

"""
    add_global_event_processor(f)

Registers `f(event, hint)` to be run on every event, whatever scope is active.
Return the (possibly changed) event, or `nothing` to drop it.
"""
add_global_event_processor(f) = (push!(_GLOBAL_EVENT_PROCESSORS, f); nothing)
