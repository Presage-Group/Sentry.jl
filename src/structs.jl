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

const TaskPayload = Union{Event,Transaction}
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

    last_send_time = nothing
    queued_tasks = Channel{TaskPayload}(100)
    sender_task = nothing
end
