##############################
# * Profiling
#----------------------------

# Julia has one sampling profiler per process, so one profile is recorded at a
# time: either for a transaction, or a chunk of the continuous profile.
const _PROFILER_LOCK = ReentrantLock()
const _ACTIVE_PROFILE = Ref{Any}(nothing)
const _PROFILER_INITIALISED = Ref(false)

# Sample at about 101Hz, like the other SDKs.
const PROFILE_SAMPLE_DELAY = 1 / 101
const PROFILE_BUFFER_SIZE = 10_000_000

"""A profile of one transaction, recorded with the `Profile` standard library."""
mutable struct TransactionProfile
    event_id::String
    start_ns::UInt64
    stop_ns::UInt64
    start_time::Float64
    data::Vector{UInt}
end

function _init_profiler()
    _PROFILER_INITIALISED[] && return nothing
    Profile.init(; n=PROFILE_BUFFER_SIZE, delay=PROFILE_SAMPLE_DELAY)
    _PROFILER_INITIALISED[] = true
    return nothing
end

function _start_sampling()
    _init_profiler()
    Profile.clear()
    Profile.start_timer()
    return nothing
end

function _stop_sampling()
    Profile.stop_timer()
    data = Profile.fetch(; include_meta=true, limitwarn=false)
    Profile.clear()
    return Vector{UInt}(data)
end

function should_profile(txn::Span, client)
    opts = client.options
    has_profiling_enabled(opts) || return false
    opts.profile_session_sample_rate === nothing || return false  # continuous mode
    txn.sampled === true || return false
    rate = try
        opts.profiles_sampler !== nothing ?
            sample_rate_from(opts.profiles_sampler, _sampling_context(txn, nothing)) :
            opts.profiles_sample_rate
    catch exc
        _report_internal_exception(exc, catch_backtrace())
        0.0
    end
    is_valid_sample_rate(rate) || return false
    return rand() < Float64(rate)
end

"""Starts profiling a sampled transaction, when profiling is enabled."""
function maybe_start_profile!(txn::Span, client)
    if continuous_profiler_running()
        txn.contexts["profile"] = Dict{String,Any}("profiler_id" => _CONTINUOUS[].profiler_id)
        return nothing
    end
    if client.options.profile_lifecycle == "trace" && client.options.profile_session_sample_rate !== nothing
        _trace_lifecycle_start!(txn)
        return nothing
    end
    should_profile(txn, client) || return nothing
    @lock _PROFILER_LOCK begin
        _ACTIVE_PROFILE[] === nothing || return nothing
        try
            _start_sampling()
        catch exc
            _report_internal_exception(exc, catch_backtrace()) # COV_EXCL_LINE
            return nothing # COV_EXCL_LINE
        end
        p = TransactionProfile(generate_uuid4(), time_ns(), 0, time(), UInt[])
        _ACTIVE_PROFILE[] = p
        txn.profile = p
    end
    return nothing
end

"""Stops the transaction's profile, returning it (or nothing)."""
function stop_profile!(txn::Span, client)
    _trace_lifecycle_stop!(txn)
    p = txn.profile
    p isa TransactionProfile || return nothing
    txn.profile = nothing
    @lock _PROFILER_LOCK begin
        _ACTIVE_PROFILE[] === p || return nothing
        try
            p.data = _stop_sampling()
            p.stop_ns = time_ns()
        catch exc
            _report_internal_exception(exc, catch_backtrace()) # COV_EXCL_LINE
            return nothing
        finally
            _ACTIVE_PROFILE[] = nothing
        end
    end
    return p
end

"""
Splits the raw profile data into samples: the instruction pointers of each
stack (innermost first), and its thread, cycle clock and sleep state.
"""
function profile_blocks(data::Vector{UInt})
    blocks = NamedTuple{(:ips, :thread, :clock, :sleeping),Tuple{Vector{UInt},Int,UInt,Bool}}[]
    start = 1
    i = 6
    while i <= length(data)
        if data[i] == 0 && data[i-1] == 0 && data[i-2] != 0
            ips = data[start:i-6]
            thread = Int(data[i-5])
            clock = data[i-3]
            sleeping = data[i-2] == 2
            push!(blocks, (; ips, thread, clock, sleeping))
            start = i + 1
            i = start + 5
        else
            i += 1
        end
    end
    return blocks
end

"""
Converts raw profile data into sentry's sampled profile format: frames,
stacks of frame indices (innermost first), and samples of stacks.
"""
function process_profile(data::Vector{UInt}, start_ns::UInt64, stop_ns::UInt64, options;
                         timestamps::Symbol=:elapsed, start_time::Float64=0.0)
    frames = Dict{String,Any}[]
    frame_index = Dict{Any,Int}()
    ip_frames = Dict{UInt,Vector{Int}}()
    stacks = Vector{Int}[]
    stack_index = Dict{Vector{Int},Int}()
    samples = Dict{String,Any}[]
    threads = Set{Int}()

    blocks = filter(b -> !b.sleeping && !isempty(b.ips), profile_blocks(data))
    isempty(blocks) && return Dict{String,Any}("frames" => frames, "stacks" => stacks,
                                                "samples" => samples, "thread_metadata" => Dict{String,Any}())
    cmin = minimum(b.clock for b in blocks)
    cmax = maximum(b.clock for b in blocks)
    duration = Float64(stop_ns - start_ns)

    for b in blocks
        stack = Int[]
        for ip in b.ips
            idxs = get!(ip_frames, ip) do
                out = Int[]
                for sf in (try Profile.lookup(ip) catch; Base.StackTraces.StackFrame[] end)
                    sf.from_c && continue
                    key = (sf.func, sf.file, sf.line)
                    idx = get!(frame_index, key) do
                        d = frame_to_dict(sf, nothing)
                        for k in ("pre_context", "context_line", "post_context", "vars")
                            delete!(d, k)
                        end
                        options === nothing || (d["in_app"] = is_in_app(get(d, "module", nothing), get(d, "abs_path", nothing), options))
                        push!(frames, d)
                        length(frames) - 1
                    end
                    push!(out, idx)
                end
                out
            end
            append!(stack, idxs)
        end
        isempty(stack) && continue
        sid = get!(stack_index, stack) do
            push!(stacks, stack)
            length(stacks) - 1
        end
        frac = cmax > cmin ? Float64(b.clock - cmin) / Float64(cmax - cmin) : 0.0
        elapsed = round(Int, frac * duration)
        push!(threads, b.thread)
        sample = Dict{String,Any}("thread_id" => string(b.thread), "stack_id" => sid)
        if timestamps === :elapsed
            sample["elapsed_since_start_ns"] = string(elapsed)
        else
            sample["timestamp"] = start_time + elapsed / 1e9
        end
        push!(samples, sample)
    end
    meta = Dict{String,Any}(string(t) => Dict{String,Any}("name" => "thread $t") for t in threads)
    return Dict{String,Any}("frames" => frames, "stacks" => stacks, "samples" => samples,
                            "thread_metadata" => meta)
end

"""The profile item for a transaction event."""
function profile_to_json(p::TransactionProfile, event::AbstractDict, options)
    profile = process_profile(p.data, p.start_ns, p.stop_ns, options)
    os = get(runtime_contexts(), "os", Dict{String,Any}())
    trace = get(get(event, "contexts", Dict()), "trace", Dict())
    return Dict{String,Any}(
        "environment" => get(event, "environment", nothing),
        "event_id" => p.event_id,
        "platform" => PLATFORM,
        "profile" => profile,
        "release" => get(event, "release", ""),
        "timestamp" => format_timestamp(p.start_time),
        "version" => "1",
        "device" => Dict{String,Any}("architecture" => string(Sys.ARCH)),
        "os" => Dict{String,Any}("name" => get(os, "name", string(Sys.KERNEL)),
                                 "version" => get(os, "version", get(os, "kernel_version", ""))),
        "runtime" => Dict{String,Any}("name" => "julia", "version" => string(Base.VERSION)),
        "transactions" => Any[Dict{String,Any}(
            "id" => event["event_id"],
            "name" => get(event, "transaction", ""),
            "relative_start_ns" => "0",
            "relative_end_ns" => string(p.stop_ns - p.start_ns),
            "trace_id" => get(trace, "trace_id", ""),
            "active_thread_id" => "1",
        )],
    )
end

##############################
# * Continuous profiling
#----------------------------

const CHUNK_INTERVAL = 60.0

mutable struct ContinuousProfiler
    profiler_id::String
    chunk_start_ns::UInt64
    chunk_start_time::Float64
    timer::Union{Nothing,Timer}
    active_traces::Int
end

const _CONTINUOUS = Ref{Union{Nothing,ContinuousProfiler}}(nothing)
const _SESSION_SAMPLED = Ref{Union{Nothing,Bool}}(nothing)

continuous_profiler_running() = _CONTINUOUS[] !== nothing

"""Whether this process is part of the sampled profiling session."""
function profile_session_sampled(client)
    rate = client.options.profile_session_sample_rate
    rate === nothing && return false
    if _SESSION_SAMPLED[] === nothing
        _SESSION_SAMPLED[] = rand() < rate
    end
    return _SESSION_SAMPLED[]
end

"""
    start_profiler()

Starts the continuous profiler (when `profile_session_sample_rate` is set and
this process was sampled). Profiles are sent in chunks every minute until
[`stop_profiler`](@ref) is called.
"""
function start_profiler()
    client = get_client()
    client === nothing && return nothing
    profile_session_sampled(client) || return nothing
    @lock _PROFILER_LOCK begin
        _CONTINUOUS[] === nothing || return nothing
        _ACTIVE_PROFILE[] === nothing || return nothing
        try
            _start_sampling()
        catch exc
            _report_internal_exception(exc, catch_backtrace()) # COV_EXCL_LINE
            return nothing # COV_EXCL_LINE
        end
        p = ContinuousProfiler(generate_uuid4(), time_ns(), time(), nothing, 0)
        p.timer = Timer(_ -> @ignore_exception(_send_chunk!(p)), CHUNK_INTERVAL; interval=CHUNK_INTERVAL)
        _CONTINUOUS[] = p
        _ACTIVE_PROFILE[] = p
    end
    return nothing
end

"""
    stop_profiler()

Stops the continuous profiler, sending the last chunk.
"""
function stop_profiler()
    p = @lock _PROFILER_LOCK begin
        x = _CONTINUOUS[]
        x === nothing && return nothing
        x.timer === nothing || Base.close(x.timer)
        _CONTINUOUS[] = nothing
        x
    end
    _send_chunk!(p; stop=true)
    return nothing
end

function _send_chunk!(p::ContinuousProfiler; stop::Bool=false)
    client = get_client()
    data, start_ns, start_time, stop_ns = @lock _PROFILER_LOCK begin
        d = try
            _stop_sampling()
        catch exc
            _report_internal_exception(exc, catch_backtrace()) # COV_EXCL_LINE
            UInt[]
        end
        s_ns, s_t = p.chunk_start_ns, p.chunk_start_time
        now_ns = time_ns()
        if stop
            _ACTIVE_PROFILE[] === p && (_ACTIVE_PROFILE[] = nothing)
        else
            _start_sampling()
            p.chunk_start_ns = time_ns()
            p.chunk_start_time = time()
        end
        (d, s_ns, s_t, now_ns)
    end
    (client === nothing || isempty(data)) && return nothing
    profile = process_profile(data, start_ns, stop_ns, client.options; timestamps=:absolute, start_time=start_time)
    isempty(profile["samples"]) && return nothing
    chunk = Dict{String,Any}(
        "chunk_id" => generate_uuid4(),
        "profiler_id" => p.profiler_id,
        "platform" => PLATFORM,
        "version" => "2",
        "release" => something(client.options.release, ""),
        "environment" => client.options.environment,
        "client_sdk" => Dict{String,Any}("name" => SDK_NAME, "version" => string(VERSION)),
        "profile" => profile,
    )
    env = Envelope(Dict{String,Any}("sent_at" => nowstr()))
    push!(env, json_item("profile_chunk", chunk; platform=PLATFORM))
    capture_envelope(client, env)
    return nothing
end

# With profile_lifecycle="trace", the profiler runs while sampled transactions do.
function _trace_lifecycle_start!(txn::Span)
    client = get_client()
    (client === nothing || !profile_session_sampled(client)) && return nothing
    start_profiler()
    p = _CONTINUOUS[]
    p === nothing && return nothing
    @lock _PROFILER_LOCK p.active_traces += 1
    txn.profile = :trace_lifecycle
    txn.contexts["profile"] = Dict{String,Any}("profiler_id" => p.profiler_id)
    return nothing
end

function _trace_lifecycle_stop!(txn::Span)
    txn.profile === :trace_lifecycle || return nothing
    txn.profile = nothing
    p = _CONTINUOUS[]
    p === nothing && return nothing
    remaining = @lock _PROFILER_LOCK (p.active_traces -= 1)
    remaining <= 0 && stop_profiler()
    return nothing
end
