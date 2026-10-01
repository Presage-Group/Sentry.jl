##############################
# * Constants
#----------------------------

const SDK_NAME = "sentry.julia"
const PLATFORM = "julia"

# Seconds to wait for queued events to be sent while the program is exiting
const DEFAULT_SHUTDOWN_TIMEOUT = 10.0
const DEFAULT_MAX_BREADCRUMBS = 100
const DEFAULT_MAX_VALUE_LENGTH = 100_000
const DEFAULT_QUEUE_SIZE = 100
const DEFAULT_MAX_SPANS = 1000
const DEFAULT_MAX_STACK_FRAMES = 100
const DEFAULT_FLAG_CAPACITY = 100
const SPAN_FLAG_CAPACITY = 10

const SENTRY_TRACE_HEADER = "sentry-trace"
const BAGGAGE_HEADER = "baggage"
const W3C_TRACEPARENT_HEADER = "traceparent"

# The Sentry level names, in increasing severity.
const LEVELS = ("debug", "info", "warning", "error", "fatal")

##############################
# * Ids and time
#----------------------------

function generate_uuid4()
    # This is mostly just printing the UUID4 in the format we want.
    val = uuid4().value
    s = string(val, base=16)
    lpad(s, 32, '0')
end

generate_span_id() = generate_uuid4()[17:32]

"""
    format_timestamp(t)

Formats seconds since the unix epoch as an RFC 3339 UTC timestamp with
microsecond precision, which is what sentry expects in envelope headers and
sessions. Events accept the float form directly.
"""
function format_timestamp(t::Real)
    secs = floor(Int, t)
    micros = round(Int, (t - secs) * 1_000_000)
    if micros >= 1_000_000
        secs += 1
        micros -= 1_000_000
    end
    dt = unix2datetime(secs)
    return string(Dates.format(dt, dateformat"yyyy-mm-ddTHH:MM:SS"), ".", lpad(micros, 6, '0'), "Z")
end
format_timestamp(dt::DateTime) = format_timestamp(datetime2unix(dt))

# Need to have an extra Z at the end - this indicates UTC
nowstr() = format_timestamp(time())

"""
Converts the timestamps sentry accepts (floats, `DateTime`s and RFC 3339
strings) into seconds since the epoch, for sorting and arithmetic.
"""
to_unix(t::Real) = Float64(t)
to_unix(t::DateTime) = datetime2unix(t)
function to_unix(t::AbstractString)
    s = replace(String(t), r"Z$" => "", r"\+00:00$" => "")
    m = match(r"^(.*?)(?:\.(\d+))?$", s)
    base = datetime2unix(DateTime(m[1], dateformat"yyyy-mm-ddTHH:MM:SS"))
    frac = m[2] === nothing ? 0.0 : parse(Float64, "0." * m[2])
    return base + frac
end
to_unix(::Nothing) = time()

@testitem "timestamps" begin
    s = Sentry.nowstr()
    @test s isa String
    @test endswith(s, "Z")
    @test occursin(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$", s)

    @test Sentry.format_timestamp(0.5) == "1970-01-01T00:00:00.500000Z"
    # Rounding up to a whole second carries over.
    @test Sentry.format_timestamp(0.9999999) == "1970-01-01T00:00:01.000000Z"
    @test Sentry.format_timestamp(Sentry.DateTime(1970, 1, 1)) == "1970-01-01T00:00:00.000000Z"

    @test Sentry.to_unix(1.5) == 1.5
    @test Sentry.to_unix("1970-01-01T00:00:01.250000Z") ≈ 1.25
    @test Sentry.to_unix("1970-01-01T00:00:02") == 2.0
    @test Sentry.to_unix(Sentry.DateTime(1970, 1, 1, 0, 0, 3)) == 3.0
    @test Sentry.to_unix(nothing) > 0
end

@testitem "ids" begin
    @test length(Sentry.generate_uuid4()) == 32
    @test all(c -> c in '0':'9' || c in 'a':'f', Sentry.generate_uuid4())
    @test length(Sentry.generate_span_id()) == 16
end

##############################
# * Internal logging
#----------------------------

# Whether the active client asked for debug output. Kept in a Ref rather than
# read from the client, so that the transport and the other background parts
# can check it without a client at hand.
const _debug_enabled = Ref(false)

"""
Writes an SDK diagnostic to stderr when `debug=true` was passed to `init`.
This deliberately bypasses the logging system, so that it can never feed back
into sentry through the logging integration.
"""
function sdk_debug(msg...; level="DEBUG")
    _debug_enabled[] || return nothing
    try
        println(stderr, " [sentry] ", level, ": ", msg...)
    catch # COV_EXCL_LINE
    end
    return nothing
end
sdk_warn(msg...) = sdk_debug(msg...; level="WARNING")

"""
    @ignore_exception expr

Runs `expr`, and swallows any exception it throws. Sentry must never be the
reason that the host program fails, so this guards every piece of user supplied
code the SDK calls into (callbacks, processors, integrations).
"""
macro ignore_exception(ex)
    quote
        try
            $(esc(ex))
        catch exc
            _report_internal_exception(exc, catch_backtrace())
            nothing
        end
    end
end

function _report_internal_exception(exc, bt)
    _debug_enabled[] || return nothing
    try
        println(stderr, " [sentry] ERROR: Internal error in sentry")
        showerror(stderr, exc, bt)
        println(stderr)
    catch # COV_EXCL_LINE
    end
    return nothing
end

@testitem "ignore_exception" begin
    @test Sentry.@ignore_exception(error("nope")) === nothing
    @test Sentry.@ignore_exception(1 + 1) == 2

    old = Sentry._debug_enabled[]
    Sentry._debug_enabled[] = true
    try
        # In debug mode the swallowed error is described on stderr.
        mktemp() do path, io
            redirect_stderr(io) do
                Sentry.@ignore_exception error("visible")
                Sentry.sdk_debug("hello")
            end
            close(io)
            out = read(path, String)
            @test occursin("Internal error in sentry", out)
            @test occursin("visible", out)
            @test occursin("DEBUG: hello", out)
        end
    finally
        Sentry._debug_enabled[] = old
    end
end

##############################
# * Misc helpers
#----------------------------

"""Truncates a string to `max_length` characters, marking the cut with `...`."""
function strip_string(s::AbstractString, max_length::Integer=DEFAULT_MAX_VALUE_LENGTH)
    length(s) <= max_length && return String(s)
    max_length <= 3 && return first(s, max_length)
    return first(s, max_length - 3) * "..."
end

"""Maps a Julia log level or a string to a sentry level name."""
function sentry_level(level::LogLevel)
    level >= LogLevel(Logging.Error.level + 1) && return "fatal"
    level >= Logging.Error && return "error"
    level >= Logging.Warn && return "warning"
    level >= Logging.Info && return "info"
    return "debug"
end
function sentry_level(level::Union{AbstractString,Symbol})
    s = lowercase(string(level))
    s == "warn" && return "warning"
    s == "critical" && return "fatal"
    return s
end
sentry_level(::Nothing) = nothing

@testitem "levels" begin
    using Logging
    @test Sentry.sentry_level(Logging.Debug) == "debug"
    @test Sentry.sentry_level(Logging.Info) == "info"
    @test Sentry.sentry_level(Logging.Warn) == "warning"
    @test Sentry.sentry_level(Logging.Error) == "error"
    @test Sentry.sentry_level(LogLevel(3000)) == "fatal"
    @test Sentry.sentry_level("warn") == "warning"
    @test Sentry.sentry_level(:critical) == "fatal"
    @test Sentry.sentry_level("Info") == "info"
    @test Sentry.sentry_level(nothing) === nothing

    @test Sentry.strip_string("abcdef", 4) == "a..."
    @test Sentry.strip_string("abc", 4) == "abc"
    @test Sentry.strip_string("abcdef", 2) == "ab"
end

"""
Matches a string against a list of patterns. Strings match as substrings when
`substring` is true (and exactly otherwise); regexes are searched for.
"""
function match_any(value::AbstractString, patterns; substring::Bool=true)
    for p in patterns
        if p isa Regex
            occursin(p, value) && return true
        elseif substring
            occursin(string(p), value) && return true
        else
            value == string(p) && return true
        end
    end
    return false
end

# Environment-variable style booleans.
env_bool(s::AbstractString) = lowercase(strip(s)) in ("1", "true", "t", "yes", "y", "on")
function env_bool_or_nothing(s::AbstractString)
    v = lowercase(strip(s))
    v in ("1", "true", "t", "yes", "y", "on") && return true
    v in ("0", "false", "f", "no", "n", "off") && return false
    return nothing
end

@testitem "match_any and env_bool" begin
    @test Sentry.match_any("https://example.com/api", ["example.com"])
    @test !Sentry.match_any("https://example.com/api", ["example.com"]; substring=false)
    @test Sentry.match_any("abc", [r"^a"])
    @test !Sentry.match_any("abc", [r"^b", "z"])
    @test Sentry.env_bool("Yes")
    @test !Sentry.env_bool("0")
    @test Sentry.env_bool_or_nothing("off") === false
    @test Sentry.env_bool_or_nothing("maybe") === nothing
    @test Sentry.env_bool_or_nothing("1") === true
end

"""Calls `f` with as many of `args` as it accepts, preferring more."""
function call_flexible(f, args...)
    for n in length(args):-1:0
        applicable(f, args[1:n]...) && return f(args[1:n]...)
    end
    return f(args...)  # raises the MethodError that describes the problem
end

@testitem "call_flexible" begin
    @test Sentry.call_flexible((a, b) -> a + b, 1, 2) == 3
    @test Sentry.call_flexible(a -> a, 1, 2) == 1
    @test Sentry.call_flexible(() -> 7, 1, 2) == 7
    @test_throws MethodError Sentry.call_flexible((a, b, c) -> a, 1)
end
