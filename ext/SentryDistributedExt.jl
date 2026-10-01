module SentryDistributedExt

using Sentry
using Distributed

"""
Adds the `distributed` context (the worker id and the number of processes) to
events, when Distributed.jl is loaded.
"""
struct DistributedIntegration <: Sentry.Integration end

function Sentry.setup_once(::Type{DistributedIntegration})
    Sentry.add_global_event_processor() do event, hint
        Sentry.integration_enabled(DistributedIntegration) || return event
        contexts = get!(() -> Dict{String,Any}(), event, "contexts")
        haskey(contexts, "distributed") ||
            (contexts["distributed"] = Dict{String,Any}("worker_id" => myid(), "nprocs" => nprocs(),
                                                        "nworkers" => nworkers()))
        return event
    end
end

function Sentry.init_workers(pids=workers(); kwargs...)
    client = Sentry.get_client()
    client === nothing && throw(ArgumentError("Call Sentry.init before Sentry.init_workers"))
    o = client.options
    settings = Dict{Symbol,Any}(:release => o.release, :environment => o.environment,
                                :traces_sample_rate => o.traces_sample_rate, :sample_rate => o.sample_rate,
                                :enable_logs => o.enable_logs, :debug => o.debug)
    for (k, v) in kwargs
        settings[k] = v
    end
    call = Expr(:call, Expr(:., :Sentry, QuoteNode(:init)),
                Expr(:parameters, (Expr(:kw, k, v) for (k, v) in settings if v !== nothing)...),
                o.dsn)
    Distributed.remotecall_eval(Main, pids, :(using Sentry))
    Distributed.remotecall_eval(Main, pids, :($call; nothing))
    return nothing
end

function __init__()
    Sentry.register_auto_integration(DistributedIntegration)
end

end
