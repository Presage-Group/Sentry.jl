##############################
# * Attributes
#----------------------------

const AttributeScalar = Union{Bool,Integer,AbstractFloat,AbstractString}

"""
Turns a value into one that attributes (on logs, metrics and streamed spans)
support: booleans, numbers, strings, and vectors of one of those. Everything
else is represented as a string. This happens as soon as the attribute is set,
so telemetry never holds on to live objects.
"""
format_attribute(v::Bool) = v
format_attribute(v::Integer) = typemin(Int64) <= v <= typemax(Int64) ? Int64(v) : string(v)
format_attribute(v::AbstractFloat) = Float64(v)
format_attribute(v::AbstractString) = String(v)
format_attribute(v::Symbol) = String(v)
function format_attribute(v::Union{AbstractVector,Tuple})
    isempty(v) && return Any[]
    for T in (Bool, Integer, AbstractFloat, AbstractString)
        all(x -> x isa T, v) && return Any[format_attribute(x) for x in v]
    end
    return safe_repr(v)
end
format_attribute(v) = safe_repr(v)

"""Writes an attribute in the typed form the protocol expects."""
serialize_attribute(v::Bool) = Dict{String,Any}("value" => v, "type" => "boolean")
serialize_attribute(v::Integer) = Dict{String,Any}("value" => v, "type" => "integer")
serialize_attribute(v::AbstractFloat) = Dict{String,Any}("value" => isfinite(v) ? v : string(v), "type" => "double")
serialize_attribute(v::AbstractString) = Dict{String,Any}("value" => String(v), "type" => "string")
function serialize_attribute(v::AbstractVector)
    isempty(v) && return Dict{String,Any}("value" => Any[], "type" => "array")
    for T in (Bool, Integer, AbstractFloat, AbstractString)
        all(x -> x isa T, v) && return Dict{String,Any}("value" => collect(v), "type" => "array")
    end
    return Dict{String,Any}("value" => safe_repr(v), "type" => "string")
end
serialize_attribute(v) = Dict{String,Any}("value" => safe_repr(v), "type" => "string")

serialize_attributes(attrs) = Dict{String,Any}(string(k) => serialize_attribute(v) for (k, v) in attrs)

@testitem "attributes" begin
    fa = Sentry.format_attribute
    @test fa(true) === true
    @test fa(Int8(3)) === Int64(3)
    @test fa(big(2)^70) == string(big(2)^70)
    @test fa(1.5f0) === 1.5
    @test fa(:s) == "s"
    @test fa([1, 2]) == Any[1, 2]
    @test fa((1.0, 2.0)) == Any[1.0, 2.0]
    @test fa([]) == Any[]
    @test fa([1, "a"]) isa String
    @test fa(Dict(1 => 2)) isa String

    sa = Sentry.serialize_attribute
    @test sa(true) == Dict("value" => true, "type" => "boolean")
    @test sa(3) == Dict("value" => 3, "type" => "integer")
    @test sa(1.5) == Dict("value" => 1.5, "type" => "double")
    @test sa(Inf)["value"] == "Inf"
    @test sa("x") == Dict("value" => "x", "type" => "string")
    @test sa(Any[1, 2])["type"] == "array"
    @test sa(Any[])["type"] == "array"
    @test sa(Any[1, "x"])["type"] == "string"
    @test sa(nothing)["type"] == "string"
    @test Sentry.serialize_attributes(Dict(:a => 1))["a"]["type"] == "integer"
end

##############################
# * Batcher
#----------------------------

"""
Collects telemetry (logs, metrics, streamed spans) and sends it in batches:
every `flush_interval` seconds, or sooner once `max_before_flush` items are
waiting. Items beyond `max_before_drop` are dropped, and reported as lost.
"""
mutable struct Batcher
    type::String
    content_type::String
    category::String
    max_before_flush::Int
    max_before_drop::Int
    flush_interval::Float64
    to_transport::Any
    capture::Any
    record_lost::Any
    buffer::Vector{Any}
    lock::ReentrantLock
    timer::Union{Nothing,Timer}
    running::Bool
end

function Batcher(; type, content_type, category, capture, record_lost, to_transport,
                 max_before_flush=100, max_before_drop=1000, flush_interval=5.0)
    return Batcher(type, content_type, category, max_before_flush, max_before_drop,
                   flush_interval, to_transport, capture, record_lost, Any[],
                   ReentrantLock(), nothing, true)
end

LogBatcher(capture, record_lost) =
    Batcher(; type="log", content_type="application/vnd.sentry.items.log+json",
            category="log_item", capture, record_lost, to_transport=log_to_transport,
            max_before_flush=100, max_before_drop=1000)

MetricsBatcher(capture, record_lost) =
    Batcher(; type="trace_metric", content_type="application/vnd.sentry.items.trace-metric+json",
            category="trace_metric", capture, record_lost, to_transport=metric_to_transport,
            max_before_flush=1000, max_before_drop=10_000)

function add!(b::Batcher, item)
    should_flush = false
    @lock b.lock begin
        if !b.running
            return nothing
        end
        if length(b.buffer) >= b.max_before_drop
            b.record_lost("queue_overflow", b.category, 1)
            return nothing
        end
        push!(b.buffer, item)
        should_flush = length(b.buffer) >= b.max_before_flush
        if b.timer === nothing
            b.timer = Timer(_ -> @ignore_exception(flush!(b)), b.flush_interval; interval=b.flush_interval)
        end
    end
    should_flush && flush!(b)
    return nothing
end

"""Sends whatever is buffered."""
function flush!(b::Batcher)
    items = @lock b.lock begin
        isempty(b.buffer) && return nothing
        x = b.buffer
        b.buffer = Any[]
        x
    end
    env = Envelope(Dict{String,Any}("sent_at" => nowstr()))
    payload = Dict{String,Any}("version" => 2, "items" => Any[b.to_transport(i) for i in items])
    push!(env, json_item(b.type, payload; content_type=b.content_type, item_count=length(items)))
    b.capture(env)
    return env
end

function kill!(b::Batcher)
    @lock b.lock begin
        b.running = false
        b.timer === nothing || Base.close(b.timer)
        b.timer = nothing
    end
    return nothing
end

function log_to_transport(log::AbstractDict)
    attrs = log["attributes"]
    haskey(attrs, "sentry.severity_number") || (attrs["sentry.severity_number"] = log["severity_number"])
    haskey(attrs, "sentry.severity_text") || (attrs["sentry.severity_text"] = log["severity_text"])
    res = Dict{String,Any}(
        "timestamp" => log["time_unix_nano"] / 1e9,
        "level" => string(log["severity_text"]),
        "body" => string(log["body"]),
        "attributes" => serialize_attributes(attrs),
    )
    get(log, "trace_id", nothing) === nothing || (res["trace_id"] = log["trace_id"])
    get(log, "span_id", nothing) === nothing || (res["span_id"] = log["span_id"])
    return res
end

function metric_to_transport(m::AbstractDict)
    res = Dict{String,Any}(
        "timestamp" => m["timestamp"],
        "name" => m["name"],
        "type" => m["type"],
        "value" => m["value"],
        "attributes" => serialize_attributes(m["attributes"]),
    )
    get(m, "trace_id", nothing) === nothing || (res["trace_id"] = m["trace_id"])
    get(m, "span_id", nothing) === nothing || (res["span_id"] = m["span_id"])
    get(m, "unit", nothing) === nothing || (res["unit"] = m["unit"])
    return res
end

@testitem "batcher" begin
    sent = Sentry.Envelope[]
    lost = Any[]
    b = Sentry.Batcher(; type="log", content_type="x", category="log_item",
                       capture=e -> push!(sent, e), record_lost=(r, c, q) -> push!(lost, (r, c, q)),
                       to_transport=identity, max_before_flush=2, max_before_drop=3, flush_interval=60.0)
    @test Sentry.flush!(b) === nothing
    Sentry.add!(b, Dict("a" => 1))
    @test isempty(sent)
    Sentry.add!(b, Dict("a" => 2))
    # Reaching max_before_flush sends right away.
    @test length(sent) == 1
    item = sent[1].items[1]
    @test item.headers["item_count"] == 2
    @test item.headers["content_type"] == "x"
    @test Sentry.payload_json(item)["version"] == 2
    @test length(Sentry.payload_json(item)["items"]) == 2

    # Past max_before_drop items are dropped and recorded.
    b.max_before_flush = 100
    for i in 1:4
        Sentry.add!(b, i)
    end
    @test lost == [("queue_overflow", "log_item", 1)]
    Sentry.flush!(b)
    @test length(Sentry.payload_json(sent[2].items[1])["items"]) == 3

    Sentry.kill!(b)
    Sentry.add!(b, 1)
    @test isempty(b.buffer)

    # The timer flushes on its own.
    b2 = Sentry.Batcher(; type="log", content_type="x", category="log_item",
                        capture=e -> push!(sent, e), record_lost=(r, c, q) -> nothing,
                        to_transport=identity, flush_interval=0.1)
    Sentry.add!(b2, 1)
    @test timedwait(() -> length(sent) == 3, 10) === :ok
    Sentry.kill!(b2)
end

@testitem "log and metric transport format" begin
    log = Dict{String,Any}("severity_text" => "info", "severity_number" => 9, "body" => "hi",
                           "attributes" => Dict{String,Any}("k" => 1), "time_unix_nano" => 2_000_000_000,
                           "trace_id" => "t", "span_id" => nothing)
    out = Sentry.log_to_transport(log)
    @test out["timestamp"] == 2.0
    @test out["level"] == "info"
    @test out["attributes"]["sentry.severity_number"]["value"] == 9
    @test out["attributes"]["k"]["type"] == "integer"
    @test out["trace_id"] == "t"
    @test !haskey(out, "span_id")

    m = Dict{String,Any}("timestamp" => 1.0, "name" => "n", "type" => "counter", "value" => 1.0,
                         "attributes" => Dict{String,Any}(), "unit" => "byte", "trace_id" => nothing, "span_id" => "s")
    out = Sentry.metric_to_transport(m)
    @test out["unit"] == "byte"
    @test out["span_id"] == "s"
    @test !haskey(out, "trace_id")
end
