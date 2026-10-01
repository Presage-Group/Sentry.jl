##############################
# * Integration framework
#----------------------------

"""
    Integration

Hooks sentry into a library or the runtime. Subtype it and implement

- `Sentry.setup_once(::Type{YourIntegration})`: global setup, run once per
  process however many times `init` is called;
- `Sentry.setup!(integration, client)`: setup for one client (optional);
- `Sentry.teardown!(integration, client)`: undo `setup!` when the client
  closes (optional);
- `Sentry.integration_identifier(::Type{YourIntegration})`: its name
  (defaults to the type name).

Pass instances in the `integrations` option of `init`. Integrations can check
whether they are enabled with `Sentry.get_integration(Sentry.get_client(), T)`.
"""
abstract type Integration end

integration_identifier(::Type{T}) where {T} = string(nameof(T))
integration_identifier(i::Integration) = integration_identifier(typeof(i))
setup_once(::Type{<:Integration}) = nothing
setup!(::Integration, ::Any) = nothing
teardown!(::Integration, ::Any) = nothing

const _INSTALLED_ONCE = Set{Any}()
const _INSTALL_LOCK = ReentrantLock()

# Integrations that package extensions make available when their package is
# loaded. They are enabled by default, like the auto enabling integrations of
# the other SDKs.
const _AUTO_INTEGRATIONS = Any[]

"""Registers an integration type to be enabled automatically (for package extensions)."""
function register_auto_integration(T)
    T in _AUTO_INTEGRATIONS || push!(_AUTO_INTEGRATIONS, T)
    return nothing
end

function default_integrations()
    return Any[DedupeIntegration(), ArgvIntegration(), ModulesIntegration(), AtexitIntegration(),
               ExcepthookIntegration(), LoggingIntegration(), RuntimeContextIntegration(),
               TasksIntegration()]
end

auto_integrations() = Any[T() for T in _AUTO_INTEGRATIONS]

function _is_disabled(i, disabled)
    id = integration_identifier(i)
    for d in disabled
        if d isa Type
            i isa d && return true
        elseif d isa Integration
            integration_identifier(d) == id && return true
        else
            string(d) == id && return true
        end
    end
    return false
end

"""Sets up the integrations for a new client."""
function setup_integrations!(c::Client)
    opts = c.options
    chosen = Dict{String,Any}()
    candidates = Any[]
    opts.default_integrations && append!(candidates, default_integrations())
    opts.default_integrations && opts.auto_enabling_integrations && append!(candidates, auto_integrations())
    # Explicitly given integrations replace the defaults of the same kind.
    for i in opts.integrations
        push!(candidates, i isa Type ? i() : i)
    end
    for i in candidates
        _is_disabled(i, opts.disabled_integrations) && continue
        chosen[integration_identifier(i)] = i
    end
    for (id, i) in chosen
        try
            T = typeof(i)
            once = @lock _INSTALL_LOCK begin
                T in _INSTALLED_ONCE ? false : (push!(_INSTALLED_ONCE, T); true)
            end
            once && setup_once(T)
            setup!(i, c)
            c.integrations[id] = i
            sdk_debug("Setting up integration ", id)
        catch exc
            @warn "Sentry: could not set up integration $id" exception = (exc, catch_backtrace())
        end
    end
    return c
end

integration_enabled(::Type{T}) where {T} = get_integration(get_client(), T) !== nothing

##############################
# * Dedupe
#----------------------------

"""Drops an exception that is captured again right after it was sent."""
struct DedupeIntegration <: Integration end

const _LAST_SEEN = Ref{Any}(nothing)

function setup_once(::Type{DedupeIntegration})
    add_global_event_processor() do event, hint
        integration_enabled(DedupeIntegration) || return event
        exc = get(hint, "exception", nothing)
        exc === nothing && return event
        if _LAST_SEEN[] === exc
            sdk_debug("DedupeIntegration dropped duplicated error event")
            return nothing
        end
        _LAST_SEEN[] = exc
        return event
    end
end

reset_dedupe!() = (_LAST_SEEN[] = nothing; nothing)

##############################
# * Argv
#----------------------------

"""Adds the command line of the program to the extra data of events."""
struct ArgvIntegration <: Integration end

function setup_once(::Type{ArgvIntegration})
    add_global_event_processor() do event, hint
        integration_enabled(ArgvIntegration) || return event
        extra = get!(() -> Dict{String,Any}(), event, "extra")
        extra isa AbstractDict && (extra["sys.argv"] = String[PROGRAM_FILE; ARGS])
        return event
    end
end

##############################
# * Modules
#----------------------------

"""Adds the loaded packages and their versions to error events."""
struct ModulesIntegration <: Integration end

function loaded_packages()
    out = Dict{String,String}()
    for (id, mod) in Base.loaded_modules
        v = try
            pkgversion(mod)
        catch
            nothing
        end
        v === nothing || (out[id.name] = string(v))
    end
    out["julia"] = string(Base.VERSION)
    return out
end

function setup_once(::Type{ModulesIntegration})
    add_global_event_processor() do event, hint
        integration_enabled(ModulesIntegration) || return event
        get(event, "type", nothing) == "transaction" && return event
        event["modules"] = loaded_packages()
        return event
    end
end

##############################
# * Runtime contexts
#----------------------------

"""Adds the `runtime`, `os` and `device` contexts to events."""
struct RuntimeContextIntegration <: Integration end

function os_context()
    name = Sys.iswindows() ? "Windows" : Sys.isapple() ? "macOS" : Sys.islinux() ? "Linux" : string(Sys.KERNEL)
    ctx = Dict{String,Any}("name" => name)
    try
        if Sys.iswindows()
            ctx["version"] = string(Sys.windows_version())
        else
            ctx["kernel_version"] = strip(read(`uname -r`, String))
        end
    catch # COV_EXCL_LINE
    end
    return ctx
end

const _OS_CONTEXT = Ref{Any}(nothing)

function runtime_contexts()
    if _OS_CONTEXT[] === nothing
        _OS_CONTEXT[] = os_context()
    end
    return Dict{String,Any}(
        "runtime" => Dict{String,Any}("name" => "julia", "version" => string(Base.VERSION),
                                      "raw_description" => "julia $(Base.VERSION) ($(Sys.MACHINE))",
                                      "threads" => Threads.nthreads()),
        "os" => copy(_OS_CONTEXT[]),
        "device" => Dict{String,Any}("arch" => string(Sys.ARCH), "cpu_description" => Sys.CPU_NAME,
                                     "processor_count" => Sys.CPU_THREADS,
                                     "memory_size" => Int(Sys.total_memory()),
                                     "free_memory" => Int(Sys.free_memory())),
    )
end

function setup_once(::Type{RuntimeContextIntegration})
    add_global_event_processor() do event, hint
        integration_enabled(RuntimeContextIntegration) || return event
        contexts = get!(() -> Dict{String,Any}(), event, "contexts")
        for (k, v) in runtime_contexts()
            haskey(contexts, k) || (contexts[k] = v)
        end
        return event
    end
end

##############################
# * Tasks
#----------------------------

"""
Scopes, and with them the active span, are carried into tasks started with
`@async` and `Threads.@spawn` by Julia's scoped values, so this integration
has nothing to set up; it is listed so that it can be seen to be active.
See also [`Sentry.errormonitor`](@ref) for reporting errors of tasks.
"""
struct TasksIntegration <: Integration end

"""
    errormonitor(task) -> task

Like `Base.errormonitor`: reports an error that ends `task` to sentry, as an
unhandled error.
"""
function errormonitor(t::Task)
    scope = get_isolation_scope()
    cur = get_current_scope()
    Threads.@spawn begin
        try
            wait(t)
        catch exc
            with(_ISOLATION_SCOPE => scope, _CURRENT_SCOPE => cur) do
                stack = istaskfailed(t) ? current_exceptions(t) : [(exc, catch_backtrace())]
                capture_exception(stack; handled=false, mechanism_type="task")
            end
        end
    end
    return t
end

"""
    traced(f; op="task", name=nothing)

Wraps `f` so that, wherever it runs (another task, thread, or a Distributed
worker that has loaded Sentry), it continues the current trace inside a span.
"""
function traced(f; op="task", name=nothing)
    headers = Dict(trace_propagation_headers())
    label = name === nothing ? string(f) : name
    return (args...; kwargs...) -> begin
        client = get_client()
        client === nothing && return f(args...; kwargs...)
        if get_current_span() isa Span
            return start_span(_ -> f(args...; kwargs...); op=op, name=label)
        end
        continue_trace(headers; op=op, name=label, source="task") do _
            f(args...; kwargs...)
        end
    end
end

##############################
# * Atexit and uncaught errors
#----------------------------

"""Sends what is still queued when the program exits."""
struct AtexitIntegration <: Integration end

"""
Reports the error that ends a script (an uncaught exception at the top level)
as an unhandled, fatal error, and marks the release health session as
crashed.
"""
struct ExcepthookIntegration <: Integration end

const _ATEXIT_REGISTERED = Ref(false)

function register_atexit!()
    _ATEXIT_REGISTERED[] && return nothing
    _ATEXIT_REGISTERED[] = true
    atexit(_atexit_hook)
    return nothing
end

function _atexit_hook(exitcode::Integer=0)
    client = _CLIENT[]
    (client === nothing || client.closed) && return nothing
    try
        crashed = false
        if exitcode != 0 && get_integration(client, ExcepthookIntegration) !== nothing
            stack = current_exceptions()
            if !isempty(stack) && !(last(stack)[1] isa InterruptException)
                capture_exception(stack; handled=false, mechanism_type="excepthook", level="fatal")
                crashed = true
            end
        end
        end_session(; status=crashed ? "crashed" : exitcode == 0 ? nothing : "abnormal")
        if get_integration(client, AtexitIntegration) !== nothing
            sdk_debug("atexit: flushing queued events")
            close_client(client)
        end
    catch exc
        _report_internal_exception(exc, catch_backtrace()) # COV_EXCL_LINE
    end
    return nothing
end

##############################
# * Cloud resource context
#----------------------------

"""
Adds the `cloud_resource` context when running on a known cloud platform,
detected from the environment variables the platform sets.
"""
struct CloudResourceContextIntegration <: Integration end

function cloud_resource_context()
    env(k) = get(ENV, k, nothing)
    if env("AWS_LAMBDA_FUNCTION_NAME") !== nothing
        return Dict{String,Any}("cloud.provider" => "aws", "cloud.platform" => "aws_lambda",
                                "cloud.region" => env("AWS_REGION"), "faas.name" => env("AWS_LAMBDA_FUNCTION_NAME"))
    elseif env("ECS_CONTAINER_METADATA_URI_V4") !== nothing || env("ECS_CONTAINER_METADATA_URI") !== nothing
        return Dict{String,Any}("cloud.provider" => "aws", "cloud.platform" => "aws_ecs",
                                "cloud.region" => env("AWS_REGION"))
    elseif env("K_SERVICE") !== nothing
        return Dict{String,Any}("cloud.provider" => "gcp", "cloud.platform" => "gcp_cloud_run",
                                "faas.name" => env("K_SERVICE"))
    elseif env("FUNCTION_TARGET") !== nothing && env("GOOGLE_CLOUD_PROJECT") !== nothing
        return Dict{String,Any}("cloud.provider" => "gcp", "cloud.platform" => "gcp_cloud_functions",
                                "cloud.account.id" => env("GOOGLE_CLOUD_PROJECT"))
    elseif env("WEBSITE_SITE_NAME") !== nothing
        return Dict{String,Any}("cloud.provider" => "azure", "cloud.platform" => "azure_app_service",
                                "cloud.region" => env("REGION_NAME"))
    elseif env("KUBERNETES_SERVICE_HOST") !== nothing
        return Dict{String,Any}("cloud.platform" => "kubernetes")
    end
    return nothing
end

function setup_once(::Type{CloudResourceContextIntegration})
    add_global_event_processor() do event, hint
        integration_enabled(CloudResourceContextIntegration) || return event
        ctx = cloud_resource_context()
        ctx === nothing && return event
        filter!(p -> p.second !== nothing, ctx)
        contexts = get!(() -> Dict{String,Any}(), event, "contexts")
        haskey(contexts, "cloud_resource") || (contexts["cloud_resource"] = ctx)
        return event
    end
end
register_auto_integration(CloudResourceContextIntegration)
