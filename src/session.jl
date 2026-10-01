##############################
# * Sessions (release health)
#----------------------------

"""
A release health session. Application mode sessions last for the life of the
program; request mode sessions (one per handled request) are aggregated
before they are sent.
"""
mutable struct Session
    sid::String
    did::Union{Nothing,String}
    started::Float64
    timestamp::Float64
    duration::Union{Nothing,Float64}
    status::String
    release::Union{Nothing,String}
    environment::Union{Nothing,String}
    user_agent::Union{Nothing,String}
    ip_address::Union{Nothing,String}
    errors::Int
    session_mode::String
end

function Session(; release=nothing, environment=nothing, user=nothing, session_mode="application")
    now_ = time()
    s = Session(string(uuid4()), nothing, now_, now_, nothing, "ok", release, environment,
                nothing, nothing, 0, session_mode)
    update!(s; user=user)
    return s
end

function update!(s::Session; status=nothing, user=nothing, user_agent=nothing, errors=nothing,
                 ip_address=nothing, did=nothing, duration=nothing)
    if user isa AbstractDict
        if ip_address === nothing
            ip_address = get(user, "ip_address", nothing)
        end
        if did === nothing
            did = something(get(user, "id", nothing), get(user, "email", nothing), get(user, "username", nothing), Some(nothing))
        end
    end
    did === nothing || (s.did = string(did))
    ip_address === nothing || (s.ip_address = string(ip_address))
    user_agent === nothing || (s.user_agent = string(user_agent))
    errors === nothing || (s.errors = errors)
    duration === nothing || (s.duration = duration)
    status === nothing || (s.status = status)
    s.timestamp = time()
    return s
end

function close!(s::Session, status=nothing)
    if status === nothing && s.status == "ok"
        status = "exited"
    end
    status === nothing || update!(s; status=status)
    s.duration === nothing && (s.duration = s.timestamp - s.started)
    return s
end

function session_attrs(s::Session; with_user_info::Bool=true)
    attrs = Dict{String,Any}()
    s.release === nothing || (attrs["release"] = s.release)
    s.environment === nothing || (attrs["environment"] = s.environment)
    if with_user_info
        s.ip_address === nothing || (attrs["ip_address"] = s.ip_address)
        s.user_agent === nothing || (attrs["user_agent"] = s.user_agent)
    end
    return attrs
end

function to_json(s::Session)
    rv = Dict{String,Any}(
        "sid" => s.sid,
        "init" => true,
        "started" => format_timestamp(s.started),
        "timestamp" => format_timestamp(s.timestamp),
        "status" => s.status,
    )
    s.errors > 0 && (rv["errors"] = s.errors)
    s.did === nothing || (rv["did"] = s.did)
    s.duration === nothing || (rv["duration"] = s.duration)
    attrs = session_attrs(s)
    isempty(attrs) || (rv["attrs"] = attrs)
    return rv
end

minute_trunc(t::Float64) = 60.0 * floor(t / 60.0)

##############################
# * Session flusher
#----------------------------

const MAX_ENVELOPE_ITEMS = 100

"""
Buffers finished sessions, and sends them every `flush_interval` seconds.
Request mode sessions are aggregated into counts per minute.
"""
mutable struct SessionFlusher
    capture::Any
    flush_interval::Float64
    pending_sessions::Vector{Dict{String,Any}}
    pending_aggregates::Dict{Tuple{Union{Nothing,String},Union{Nothing,String}},Dict{Float64,Dict{String,Int}}}
    lock::ReentrantLock
    timer::Union{Nothing,Timer}
    running::Bool
end

SessionFlusher(capture; flush_interval=60.0) =
    SessionFlusher(capture, flush_interval, Dict{String,Any}[], Dict(), ReentrantLock(), nothing, true)

function ensure_running!(f::SessionFlusher)
    f.timer === nothing || return nothing
    f.running || return nothing
    f.timer = Timer(_ -> @ignore_exception(flush!(f)), f.flush_interval; interval=f.flush_interval)
    return nothing
end

function add_session!(f::SessionFlusher, s::Session)
    @lock f.lock begin
        f.running || return nothing
        if s.session_mode == "request"
            add_aggregate_session!(f, s)
        else
            push!(f.pending_sessions, to_json(s))
        end
        ensure_running!(f)
    end
    return nothing
end

function add_aggregate_session!(f::SessionFlusher, s::Session)
    key = (s.release, s.environment)
    buckets = get!(f.pending_aggregates, key) do
        Dict{Float64,Dict{String,Int}}()
    end
    state = get!(buckets, minute_trunc(s.started)) do
        Dict{String,Int}()
    end
    field = if s.status == "crashed"
        "crashed"
    elseif s.status == "abnormal"
        "abnormal"
    elseif s.errors > 0
        "errored"
    else
        "exited"
    end
    state[field] = get(state, field, 0) + 1
    return nothing
end

function flush!(f::SessionFlusher)
    sessions, aggregates = @lock f.lock begin
        s, a = f.pending_sessions, f.pending_aggregates
        f.pending_sessions = Dict{String,Any}[]
        f.pending_aggregates = Dict()
        (s, a)
    end

    envelopes = Envelope[]
    env = Envelope(Dict{String,Any}("sent_at" => nowstr()))
    for s in sessions
        if length(env.items) == MAX_ENVELOPE_ITEMS
            push!(envelopes, env)
            env = Envelope(Dict{String,Any}("sent_at" => nowstr()))
        end
        push!(env, json_item("session", s))
    end
    for ((release, environment), buckets) in aggregates
        if length(env.items) == MAX_ENVELOPE_ITEMS
            push!(envelopes, env)
            env = Envelope(Dict{String,Any}("sent_at" => nowstr()))
        end
        attrs = Dict{String,Any}()
        release === nothing || (attrs["release"] = release)
        environment === nothing || (attrs["environment"] = environment)
        aggs = [merge(Dict{String,Any}("started" => format_timestamp(t)), counts) for (t, counts) in buckets]
        push!(env, json_item("sessions", Dict{String,Any}("attrs" => attrs, "aggregates" => aggs)))
    end
    isempty(env.items) || push!(envelopes, env)
    foreach(f.capture, envelopes)
    return envelopes
end

function kill!(f::SessionFlusher)
    @lock f.lock begin
        f.running = false
        f.timer === nothing || Base.close(f.timer)
        f.timer = nothing
    end
    return nothing
end

@testitem "sessions" begin
    s = Sentry.Session(; release="r", environment="e",
                       user=Dict{String,Any}("id" => 7, "ip_address" => "1.1.1.1"))
    @test s.did == "7"
    @test s.ip_address == "1.1.1.1"
    Sentry.update!(s; errors=2, user_agent="ua")
    j = Sentry.to_json(s)
    @test j["status"] == "ok"
    @test j["errors"] == 2
    @test j["attrs"] == Dict("release" => "r", "environment" => "e", "ip_address" => "1.1.1.1", "user_agent" => "ua")
    @test j["init"] == true
    Sentry.close!(s)
    @test s.status == "exited"
    @test s.duration !== nothing
    @test haskey(Sentry.to_json(s), "duration")

    c = Sentry.Session()
    Sentry.update!(c; status="crashed")
    Sentry.close!(c)
    @test c.status == "crashed"
    @test !haskey(Sentry.to_json(c), "attrs")
    @test Sentry.session_attrs(s; with_user_info=false) == Dict("release" => "r", "environment" => "e")

    # did falls back through email and username.
    @test Sentry.Session(; user=Dict{String,Any}("email" => "a@b")).did == "a@b"
    @test Sentry.Session(; user=Dict{String,Any}()).did === nothing
end

@testitem "session flusher" begin
    sent = Sentry.Envelope[]
    f = Sentry.SessionFlusher(e -> push!(sent, e); flush_interval=3600.0)
    Sentry.add_session!(f, Sentry.close!(Sentry.Session(; release="r")))

    for (status, errors) in (("exited", 0), ("exited", 1), ("crashed", 0), ("abnormal", 0))
        s = Sentry.Session(; release="r", environment="e", session_mode="request")
        Sentry.update!(s; errors=errors)
        Sentry.close!(s, status)
        Sentry.add_session!(f, s)
    end
    envs = Sentry.flush!(f)
    @test length(envs) == 1
    types = [Sentry.item_type(i) for i in envs[1].items]
    @test types == ["session", "sessions"]
    agg = Sentry.payload_json(envs[1].items[2])
    @test agg["attrs"] == Dict("release" => "r", "environment" => "e")
    counts = agg["aggregates"][1]
    @test counts["exited"] == 1
    @test counts["errored"] == 1
    @test counts["crashed"] == 1
    @test counts["abnormal"] == 1
    @test Sentry.flush!(f) == Sentry.Envelope[]

    # Envelopes are split once they reach the item limit.
    for _ in 1:(Sentry.MAX_ENVELOPE_ITEMS + 1)
        Sentry.add_session!(f, Sentry.Session())
    end
    s = Sentry.Session(; session_mode="request")
    Sentry.add_session!(f, s)
    @test length(Sentry.flush!(f)) == 2

    Sentry.kill!(f)
    Sentry.add_session!(f, Sentry.Session())
    @test isempty(f.pending_sessions)
    Sentry.ensure_running!(f)
    @test f.timer === nothing
end
