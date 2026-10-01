##############################
# * Serializer
#----------------------------

# Limits for user supplied data ("databags": extra, contexts, breadcrumb and
# span data, request bodies). SDK generated structure is not limited in breadth,
# so that a transaction keeps all of its spans.
const MAX_DATABAG_DEPTH = 5
const MAX_DATABAG_BREADTH = 100
const MAX_EVENT_DEPTH = 20

struct SerializeOptions
    max_value_length::Int
    custom_repr::Any
end
SerializeOptions() = SerializeOptions(DEFAULT_MAX_VALUE_LENGTH, nothing)

"""
    safe_repr(x)

A string representation of any value that never throws.
"""
function safe_repr(x; max_length::Integer=DEFAULT_MAX_VALUE_LENGTH)
    s = try
        sprint(show, x; context=(:limit => true, :compact => true))
    catch
        try
            "<$(typeof(x)) (repr failed)>"
        catch
            "<unprintable>"
        end
    end
    return strip_string(s, max_length)
end

"""
    serialize_value(x; databag=true, options=SerializeOptions())

Lowers an arbitrary Julia value to something JSON can write: `Dict{String,Any}`,
`Vector{Any}`, strings, finite numbers, booleans and `nothing`. Anything else is
turned into a string, using `custom_repr` when it gives one.
"""
function serialize_value(x; databag::Bool=true, options::SerializeOptions=SerializeOptions())
    seen = IdDict{Any,Nothing}()
    return _ser(x, databag ? MAX_DATABAG_DEPTH : MAX_EVENT_DEPTH, databag, options, seen)
end

function _ser(x, depth, databag, opts, seen)
    # Scalars first; these never recurse.
    x === nothing && return nothing
    x === missing && return nothing
    x isa Bool && return x
    x isa Union{Int8,Int16,Int32,Int64,UInt8,UInt16,UInt32} && return x
    x isa Integer && return typemin(Int64) <= x <= typemax(Int64) ? Int64(x) : string(x)
    x isa AbstractFloat && return isfinite(x) ? Float64(x) : string(x)
    x isa Rational && return Float64(x)
    x isa AbstractString && return strip_string(x, opts.max_value_length)
    x isa Symbol && return strip_string(string(x), opts.max_value_length)
    x isa AbstractChar && return string(x)
    x isa Union{Dates.TimeType,UUID,VersionNumber,Module} && return string(x)
    x isa Dates.Period && return string(x)

    if opts.custom_repr !== nothing
        r = try
            opts.custom_repr(x)
        catch
            nothing
        end
        r === nothing || return strip_string(string(r), opts.max_value_length)
    end

    x isa Exception && return strip_string(sprint(showerror, x), opts.max_value_length)
    x isa Union{Type,Function} && return safe_repr(x; max_length=opts.max_value_length)

    iscontainer = x isa Union{AbstractDict,NamedTuple,Base.Pairs,AbstractVector,Tuple,AbstractSet,Pair}
    iscontainer || return safe_repr(x; max_length=opts.max_value_length)

    depth <= 0 && return safe_repr(x; max_length=min(opts.max_value_length, 1024))
    if ismutable(x)
        haskey(seen, x) && return "<cyclic>"
        seen[x] = nothing
    end
    try
        return _ser_container(x, depth, databag, opts, seen)
    finally
        ismutable(x) && delete!(seen, x)
    end
end

_ser_key(k::AbstractString) = String(k)
_ser_key(k) = string(k)

function _ser_container(x::Union{AbstractDict,NamedTuple,Base.Pairs}, depth, databag, opts, seen)
    out = Dict{String,Any}()
    n = 0
    for (k, v) in pairs(x)
        n += 1
        databag && n > MAX_DATABAG_BREADTH && break
        out[_ser_key(k)] = _ser(v, depth - 1, databag, opts, seen)
    end
    return out
end

function _ser_container(x::Pair, depth, databag, opts, seen)
    return Any[_ser(x.first, depth - 1, databag, opts, seen), _ser(x.second, depth - 1, databag, opts, seen)]
end

function _ser_container(x, depth, databag, opts, seen)
    out = Any[]
    for v in x
        databag && length(out) >= MAX_DATABAG_BREADTH && break
        push!(out, _ser(v, depth - 1, databag, opts, seen))
    end
    return out
end

@testitem "serializer" begin
    using Dates, UUIDs
    ser = Sentry.serialize_value

    @test ser(nothing) === nothing
    @test ser(missing) === nothing
    @test ser(true) === true
    @test ser(Int32(3)) === Int32(3)
    @test ser(big(2)^70) == string(big(2)^70)
    @test ser(UInt64(5)) === Int64(5)
    @test ser(NaN) == "NaN"
    @test ser(1.5f0) === 1.5
    @test ser(1 // 2) == 0.5
    @test ser(:sym) == "sym"
    @test ser('c') == "c"
    @test ser(Date(2020, 1, 2)) == "2020-01-02"
    @test ser(Second(3)) == "3 seconds"
    @test ser(v"1.2.3") == "1.2.3"
    @test ser(Base) == "Base"
    @test ser(ErrorException("boom")) == "boom"
    @test ser(sin) == "sin"
    @test ser(Int) == "Int64"

    @test ser((a=1, b="x")) == Dict("a" => 1, "b" => "x")
    @test ser(Dict(:k => [1, 2])) == Dict("k" => Any[1, 2])
    @test ser((1, "a")) == Any[1, "a"]
    @test ser(Set([1])) == Any[1]
    @test ser(1 => 2) == Any[1, 2]

    # Unknown values are represented as strings.
    struct Opaque
        x::Int
    end
    @test ser(Opaque(1)) == "Opaque(1)"
    @test ser(Opaque(1); options=Sentry.SerializeOptions(100, o -> o isa Opaque ? "custom" : nothing)) == "custom"
    # A failing custom_repr falls back to the default representation.
    @test ser(Opaque(1); options=Sentry.SerializeOptions(100, o -> error("no"))) == "Opaque(1)"

    # Values longer than max_value_length are cut short.
    @test ser("x"^20; options=Sentry.SerializeOptions(10, nothing)) == "x"^7 * "..."

    # Cycles do not recurse forever.
    v = Any[1]
    push!(v, v)
    @test ser(v)[2] == "<cyclic>"

    # Databags are limited in depth and breadth, while event structure is not.
    deep = Dict("a" => Dict("b" => Dict("c" => Dict("d" => Dict("e" => Dict("f" => 1))))))
    @test ser(deep)["a"]["b"]["c"]["d"]["e"] isa String
    @test ser(deep; databag=false)["a"]["b"]["c"]["d"]["e"]["f"] == 1
    @test length(ser(collect(1:500))) == Sentry.MAX_DATABAG_BREADTH
    @test length(ser(Dict(string(i) => i for i in 1:500))) == Sentry.MAX_DATABAG_BREADTH
    @test length(ser(collect(1:500); databag=false)) == 500

    # safe_repr never throws.
    struct BadShow end
    Base.show(io::IO, ::BadShow) = error("cannot show")
    @test endswith(Sentry.safe_repr(BadShow()), "BadShow (repr failed)>")
end
