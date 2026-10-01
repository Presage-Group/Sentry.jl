##############################
# * Backpressure monitor
#----------------------------

const MAX_DOWNSAMPLE_FACTOR = 10

"""
Checks the health of the transport every `interval` seconds. While it is
unhealthy (rate limited, or its queue is full) the sample rate for
transactions is halved on each check, up to `2^-MAX_DOWNSAMPLE_FACTOR`, and
restored once it is healthy again.
"""
mutable struct Monitor
    transport::Any
    interval::Float64
    healthy::Bool
    downsample_factor::Int
    timer::Union{Nothing,Timer}
end

function Monitor(transport; interval=10.0, start=true)
    m = Monitor(transport, interval, true, 0, nothing)
    if start
        m.timer = Timer(_ -> @ignore_exception(run_check!(m)), interval; interval=interval)
    end
    return m
end

function run_check!(m::Monitor)
    m.healthy = is_healthy(m.transport)
    if m.healthy
        m.downsample_factor > 0 && sdk_debug("[Monitor] health check positive, reverting to normal sampling")
        m.downsample_factor = 0
    else
        m.downsample_factor < MAX_DOWNSAMPLE_FACTOR && (m.downsample_factor += 1)
        sdk_debug("[Monitor] health check negative, downsampling with a factor of ", m.downsample_factor)
    end
    return m
end

function kill!(m::Monitor)
    m.timer === nothing || Base.close(m.timer)
    m.timer = nothing
    return nothing
end

@testitem "backpressure monitor" begin
    struct Unhealthy <: Sentry.AbstractTransport
        healthy::Base.RefValue{Bool}
    end
    Sentry.is_healthy(t::Unhealthy) = t.healthy[]

    t = Unhealthy(Ref(false))
    m = Sentry.Monitor(t; start=false)
    for _ in 1:12
        Sentry.run_check!(m)
    end
    @test m.downsample_factor == Sentry.MAX_DOWNSAMPLE_FACTOR
    @test !m.healthy
    t.healthy[] = true
    Sentry.run_check!(m)
    @test m.downsample_factor == 0

    m2 = Sentry.Monitor(t; interval=0.05)
    t.healthy[] = false
    @test timedwait(() -> m2.downsample_factor > 0, 10) === :ok
    Sentry.kill!(m2)
    @test m2.timer === nothing
    @test Sentry.is_healthy(Sentry.FunctionTransport(identity))
end
