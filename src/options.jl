##############################
# * Options
#----------------------------

"""
    Options

Every setting that `Sentry.init` accepts, mirroring the options of the other
sentry SDKs. See the docstring of [`init`](@ref) for a description of each.
"""
Base.@kwdef mutable struct Options
    dsn::Union{Nothing,String} = nothing
    debug::Bool = false
    release::Union{Nothing,String} = nothing
    environment::Union{Nothing,String} = nothing
    dist::Union{Nothing,String} = nothing
    server_name::Union{Nothing,String} = nothing

    # Errors
    sample_rate::Float64 = 1.0
    error_sampler::Any = nothing
    max_breadcrumbs::Int = DEFAULT_MAX_BREADCRUMBS
    before_send::Any = nothing
    before_breadcrumb::Any = nothing
    ignore_errors::Vector{Any} = Any[]
    attach_stacktrace::Bool = false
    send_default_pii::Bool = false
    in_app_include::Vector{String} = String[]
    in_app_exclude::Vector{String} = String[]
    project_root::Union{Nothing,String} = nothing
    include_source_context::Bool = true
    max_stack_frames::Int = DEFAULT_MAX_STACK_FRAMES
    max_value_length::Int = DEFAULT_MAX_VALUE_LENGTH
    max_request_body_size::String = "medium"
    custom_repr::Any = nothing
    add_full_stack::Bool = false
    event_scrubber::Any = nothing

    # Integrations
    integrations::Vector{Any} = Any[]
    default_integrations::Bool = true
    auto_enabling_integrations::Bool = true
    disabled_integrations::Vector{Any} = Any[]

    # Transport
    transport::Any = nothing
    transport_queue_size::Int = DEFAULT_QUEUE_SIZE
    shutdown_timeout::Float64 = DEFAULT_SHUTDOWN_TIMEOUT
    http_proxy::Union{Nothing,String} = nothing
    https_proxy::Union{Nothing,String} = nothing
    proxy_headers::Dict{String,String} = Dict{String,String}()
    ca_certs::Union{Nothing,String} = nothing
    cert_file::Union{Nothing,String} = nothing
    key_file::Union{Nothing,String} = nothing
    keep_alive::Bool = false
    send_client_reports::Bool = true
    enable_backpressure_handling::Bool = true
    spotlight::Any = nothing

    # Tracing
    traces_sample_rate::Union{Nothing,Float64} = nothing
    traces_sampler::Any = nothing
    enable_tracing::Union{Nothing,Bool} = nothing
    trace_propagation_targets::Vector{Any} = Any[r".*"]
    propagate_traces::Bool = true
    strict_trace_continuation::Bool = false
    org_id::Union{Nothing,String} = nothing
    ignore_spans::Vector{Any} = Any[]
    trace_ignore_status_codes::Set{Int} = Set{Int}()
    functions_to_trace::Vector{Any} = Any[]
    max_spans::Int = DEFAULT_MAX_SPANS
    trace_lifecycle::String = "static"
    before_send_transaction::Any = nothing
    before_send_span::Any = nothing
    enable_db_query_source::Bool = true
    db_query_source_threshold_ms::Int = 100
    enable_http_request_source::Bool = true
    http_request_source_threshold_ms::Int = 100

    # Profiling
    profiles_sample_rate::Union{Nothing,Float64} = nothing
    profiles_sampler::Any = nothing
    profile_session_sample_rate::Union{Nothing,Float64} = nothing
    profile_lifecycle::String = "manual"

    # Release health
    auto_session_tracking::Bool = true

    # Logs and metrics
    enable_logs::Bool = false
    before_send_log::Any = nothing
    enable_metrics::Bool = true
    before_send_metric::Any = nothing

    _experiments::Dict{String,Any} = Dict{String,Any}()
end

const OPTION_NAMES = fieldnames(Options)

# Environment variables that CI and hosting providers set to the deployed commit.
const RELEASE_ENV_VARS = ("SENTRY_RELEASE", "HEROKU_SLUG_COMMIT", "SOURCE_VERSION",
                          "CODEBUILD_RESOLVED_SOURCE_VERSION", "CIRCLE_SHA1",
                          "GAE_DEPLOYMENT_ID", "GITHUB_SHA")

"""
The release to use when none is configured: taken from the environment, or
from the git commit of the working directory.
"""
function default_release()
    for var in RELEASE_ENV_VARS
        v = get(ENV, var, "")
        isempty(v) || return v
    end
    return git_release()
end

function git_release(dir=pwd())
    try
        Sys.which("git") === nothing && return nothing
        out = IOBuffer()
        cmd = Cmd(`git rev-parse HEAD`; dir=dir)
        success(pipeline(cmd; stdout=out, stderr=devnull)) || return nothing
        rev = strip(String(take!(out)))
        return isempty(rev) ? nothing : String(rev)
    catch
        return nothing
    end
end

"""
    make_options(dsn=nothing; kwargs...) -> Options

Builds the options for a client, filling in defaults from the environment the
way the other sentry SDKs do. Unknown options are an error, so that typos are
not silently ignored.
"""
function make_options(dsn=nothing; kwargs...)
    unknown = setdiff(keys(kwargs), OPTION_NAMES)
    if !isempty(unknown)
        throw(ArgumentError("Unknown Sentry option(s): $(join(unknown, ", "))"))
    end

    # Allow a few convenient input types, converted to what the field wants.
    converted = Dict{Symbol,Any}()
    for (k, v) in kwargs
        converted[k] = _convert_option(Val(k), v)
    end

    opts = Options(; converted...)

    if dsn !== nothing
        opts.dsn = string(dsn)
    elseif opts.dsn === nothing
        env_dsn = get(ENV, "SENTRY_DSN", "")
        opts.dsn = isempty(env_dsn) ? nothing : env_dsn
    end
    if !haskey(kwargs, :debug)
        v = env_bool_or_nothing(get(ENV, "SENTRY_DEBUG", ""))
        v === nothing || (opts.debug = v)
    end
    if opts.release === nothing
        opts.release = default_release()
    end
    if opts.environment === nothing
        env = get(ENV, "SENTRY_ENVIRONMENT", "")
        opts.environment = isempty(env) ? "production" : env
    end
    if opts.server_name === nothing
        opts.server_name = try
            gethostname()
        catch
            nothing
        end
    end
    if opts.project_root === nothing
        opts.project_root = pwd()
    end
    if opts.traces_sample_rate === nothing && opts.traces_sampler === nothing
        rate = tryparse(Float64, get(ENV, "SENTRY_TRACES_SAMPLE_RATE", ""))
        rate === nothing || (opts.traces_sample_rate = rate)
    end
    if opts.enable_tracing === true && opts.traces_sample_rate === nothing && opts.traces_sampler === nothing
        opts.traces_sample_rate = 1.0
    end
    if opts.spotlight === nothing
        env = get(ENV, "SENTRY_SPOTLIGHT", "")
        if !isempty(env)
            b = env_bool_or_nothing(env)
            opts.spotlight = b === nothing ? env : b
        end
    end
    if opts.event_scrubber === nothing
        opts.event_scrubber = EventScrubber(; send_default_pii=opts.send_default_pii)
    end

    validate_options(opts)
    return opts
end

_convert_option(::Val, v) = v
_convert_option(::Val{:traces_sample_rate}, v::Real) = Float64(v)
_convert_option(::Val{:profiles_sample_rate}, v::Real) = Float64(v)
_convert_option(::Val{:profile_session_sample_rate}, v::Real) = Float64(v)
_convert_option(::Val{:sample_rate}, v::Real) = Float64(v)
_convert_option(::Val{:shutdown_timeout}, v::Real) = Float64(v)
_convert_option(::Val{:ignore_errors}, v) = Any[v...]
_convert_option(::Val{:ignore_spans}, v) = Any[v...]
_convert_option(::Val{:integrations}, v) = Any[v...]
_convert_option(::Val{:disabled_integrations}, v) = Any[v...]
_convert_option(::Val{:functions_to_trace}, v) = Any[v...]
_convert_option(::Val{:trace_propagation_targets}, v) = v === nothing ? Any[] : Any[v...]
_convert_option(::Val{:in_app_include}, v) = String[string(x) for x in v]
_convert_option(::Val{:in_app_exclude}, v) = String[string(x) for x in v]
_convert_option(::Val{:trace_ignore_status_codes}, v) = Set{Int}(v)
_convert_option(::Val{:proxy_headers}, v) = Dict{String,String}(string(k) => string(x) for (k, x) in pairs(v))
_convert_option(::Val{:_experiments}, v) = Dict{String,Any}(string(k) => x for (k, x) in pairs(v))
_convert_option(::Val{:release}, v) = v === nothing ? nothing : string(v)
_convert_option(::Val{:environment}, v) = v === nothing ? nothing : string(v)
_convert_option(::Val{:dist}, v) = v === nothing ? nothing : string(v)
_convert_option(::Val{:max_request_body_size}, v) = string(v)
_convert_option(::Val{:trace_lifecycle}, v) = string(v)
_convert_option(::Val{:profile_lifecycle}, v) = string(v)

function validate_options(opts::Options)
    0 <= opts.sample_rate <= 1 || throw(ArgumentError("sample_rate must be between 0 and 1"))
    if opts.traces_sample_rate !== nothing
        0 <= opts.traces_sample_rate <= 1 || throw(ArgumentError("traces_sample_rate must be between 0 and 1"))
    end
    opts.max_request_body_size in ("never", "small", "medium", "always") ||
        throw(ArgumentError("max_request_body_size must be one of never, small, medium or always"))
    opts.trace_lifecycle in ("static", "stream") ||
        throw(ArgumentError("trace_lifecycle must be \"static\" or \"stream\""))
    opts.profile_lifecycle in ("manual", "trace") ||
        throw(ArgumentError("profile_lifecycle must be \"manual\" or \"trace\""))
    opts.max_breadcrumbs >= 0 || throw(ArgumentError("max_breadcrumbs must not be negative"))
    return opts
end

"""Whether performance monitoring (tracing) is switched on."""
function has_tracing_enabled(opts::Options)
    opts.enable_tracing === false && return false
    return opts.traces_sample_rate !== nothing || opts.traces_sampler !== nothing
end
has_tracing_enabled(::Nothing) = false

has_span_streaming_enabled(opts::Options) = opts.trace_lifecycle == "stream"
has_span_streaming_enabled(::Nothing) = false

function has_profiling_enabled(opts::Options)
    opts.profiles_sampler !== nothing && return true
    opts.profiles_sample_rate !== nothing && opts.profiles_sample_rate > 0 && return true
    return false
end

@testitem "options" begin
    withenv("SENTRY_DSN" => nothing, "SENTRY_RELEASE" => "r1", "SENTRY_ENVIRONMENT" => nothing,
            "SENTRY_DEBUG" => "true", "SENTRY_TRACES_SAMPLE_RATE" => "0.25", "SENTRY_SPOTLIGHT" => nothing) do
        o = Sentry.make_options()
        @test o.dsn === nothing
        @test o.release == "r1"
        @test o.environment == "production"
        @test o.debug
        @test o.traces_sample_rate == 0.25
        @test o.project_root == pwd()
        @test o.event_scrubber isa Sentry.EventScrubber
        @test Sentry.has_tracing_enabled(o)
    end

    withenv("SENTRY_DSN" => "https://k@h/1", "SENTRY_ENVIRONMENT" => "staging",
            "SENTRY_SPOTLIGHT" => "http://localhost:1234/stream", "SENTRY_DEBUG" => nothing) do
        o = Sentry.make_options(; release=v"1.0.0", sample_rate=1, ignore_errors=(ArgumentError,),
                                trace_ignore_status_codes=[404], proxy_headers=(a="b",),
                                in_app_include=[:MyPkg], _experiments=(x=1,), enable_tracing=true)
        @test o.dsn == "https://k@h/1"
        @test o.environment == "staging"
        @test o.release == "1.0.0"
        @test o.ignore_errors == Any[ArgumentError]
        @test 404 in o.trace_ignore_status_codes
        @test o.proxy_headers == Dict("a" => "b")
        @test o.in_app_include == ["MyPkg"]
        @test o._experiments["x"] == 1
        @test o.spotlight == "http://localhost:1234/stream"
        # enable_tracing alone turns on sampling of everything
        @test o.traces_sample_rate == 1.0
        @test Sentry.make_options("https://x@y/2").dsn == "https://x@y/2"
    end

    withenv("SENTRY_SPOTLIGHT" => "1") do
        @test Sentry.make_options().spotlight === true
    end

    @test_throws ArgumentError Sentry.make_options(; not_an_option=1)
    @test_throws ArgumentError Sentry.make_options(; sample_rate=2)
    @test_throws ArgumentError Sentry.make_options(; traces_sample_rate=-1)
    @test_throws ArgumentError Sentry.make_options(; max_request_body_size="huge")
    @test_throws ArgumentError Sentry.make_options(; trace_lifecycle="other")
    @test_throws ArgumentError Sentry.make_options(; profile_lifecycle="other")
    @test_throws ArgumentError Sentry.make_options(; max_breadcrumbs=-1)

    @test !Sentry.has_tracing_enabled(nothing)
    @test !Sentry.has_tracing_enabled(Sentry.make_options(; traces_sample_rate=1.0, enable_tracing=false))
    @test Sentry.has_profiling_enabled(Sentry.make_options(; profiles_sample_rate=1.0))
    @test Sentry.has_profiling_enabled(Sentry.make_options(; profiles_sampler=_ -> 1.0))
    @test !Sentry.has_profiling_enabled(Sentry.make_options())
    @test Sentry.has_span_streaming_enabled(Sentry.make_options(; trace_lifecycle="stream"))
    @test !Sentry.has_span_streaming_enabled(nothing)
end

@testitem "default release" begin
    withenv(("$v" => nothing for v in Sentry.RELEASE_ENV_VARS)...) do
        withenv("CIRCLE_SHA1" => "abc") do
            @test Sentry.default_release() == "abc"
        end
        # Falls back to git, which knows nothing about a fresh directory.
        mktempdir() do dir
            @test Sentry.git_release(dir) === nothing
        end
        @test Sentry.git_release("/this/does/not/exist") === nothing
    end
end
