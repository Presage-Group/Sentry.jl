##############################
# * Support structs
#----------------------------

Base.@kwdef struct Event
    event_id = generate_uuid4()
    timestamp = nowstr()
    platform = "julia"

    message = nothing
    exception = nothing
    level = nothing
    tags = nothing
    attachments::Vector{Any} = []
end


Base.@kwdef mutable struct Span
    parent_span_id::Union{String,Nothing} = nothing
    span_id::String = generate_uuid4()[1:16]
    tags = nothing
    op = nothing
    description = nothing
    start_timestamp::String = nowstr()
    timestamp::Union{Nothing,String} = nothing
end

Base.@kwdef mutable struct Transaction
    event_id::String = generate_uuid4()
    name::Union{String, Missing} = missing
    trace_id::String = generate_uuid4()

    spans::Vector{Span} = []
    root_span::Union{Span,Nothing} = nothing
    num_open_spans::Int = 0
end

##############################
# * Hub
#----------------------------

struct NoSamples end
Base.@kwdef struct RatioSampler
    ratio::Float64
    function RatioSampler(x)
        @assert 0 <= x <= 1
        new(x)
    end
end

sample(::NoSamples) = false
sample(sampler::RatioSampler) = rand() < sampler.ratio
sample(sampler::Function) = sampler()

@testitem "Sampling" begin
    @test Sentry.sample(Sentry.NoSamples()) == false

    @test_throws AssertionError Sentry.RatioSampler(-0.1)
    @test_throws AssertionError Sentry.RatioSampler(1.1)
    @test Sentry.RatioSampler(0.0).ratio == 0.0
    @test Sentry.RatioSampler(1.0).ratio == 1.0
    @test Sentry.sample(Sentry.RatioSampler(0.0)) == false
    @test Sentry.sample(Sentry.RatioSampler(1.0)) == true

    @test Sentry.sample(() -> true) == true
    @test Sentry.sample(() -> false) == false
end

@testitem "Event and Span defaults" begin
    ev = Sentry.Event()
    @test length(ev.event_id) == 32
    @test ev.platform == "julia"
    @test isempty(ev.attachments)
    @test ev.message === nothing

    sp = Sentry.Span()
    @test length(sp.span_id) == 16
    @test sp.timestamp === nothing
    @test sp.parent_span_id === nothing
end

const TaskPayload = Union{Event,Transaction}

# Seconds to wait for queued events to be sent while the program is exiting
const DEFAULT_SHUTDOWN_TIMEOUT = 10.0

# This is to supposedly support the "unified api" of the sentry sdk. I'm not a
# fan, so it will only go partway to this goal.
# Note: a proper implementation here would make Hub a module.
Base.@kwdef mutable struct Hub
    initialised::Bool = false
    traces_sampler = NoSamples()

    dsn = nothing
    upstream::String = ""
    project_id::String = ""
    public_key::String = ""

    release::Union{Nothing,String} = nothing

    debug::Bool = false
    shutdown_timeout::Float64 = DEFAULT_SHUTDOWN_TIMEOUT

    last_send_time = nothing
    queued_tasks = Channel{TaskPayload}(100)
    sender_task = nothing
end

@testitem "Hub defaults" begin
    @test Sentry.Hub().initialised == false
    @test Sentry.Hub().shutdown_timeout == Sentry.DEFAULT_SHUTDOWN_TIMEOUT
end
