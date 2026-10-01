##############################
# * Envelopes
#----------------------------

"""
One item of an [`Envelope`](@ref): a header with its `type`, and the payload
bytes. JSON payloads are written when the item is made, so an item holds no
references to live objects.
"""
struct Item
    headers::Dict{String,Any}
    payload::Vector{UInt8}
end

function Item(type::AbstractString, payload::Vector{UInt8}; headers...)
    h = Dict{String,Any}("type" => String(type))
    for (k, v) in headers
        v === nothing || (h[string(k)] = v)
    end
    return Item(h, payload)
end

"""Makes an item with a JSON payload."""
json_item(type::AbstractString, payload; content_type="application/json", headers...) =
    Item(type, Vector{UInt8}(JSON.json(payload)); content_type=content_type, headers...)

item_type(item::Item) = get(item.headers, "type", nothing)

"""The rate limiting and client report category of an item."""
function data_category(item::Item)
    ty = item_type(item)
    ty in ("session", "sessions") && return "session"
    ty == "attachment" && return "attachment"
    ty == "transaction" && return "transaction"
    ty == "span" && return "span"
    ty == "event" && return "error"
    ty == "log" && return "log_item"
    ty == "trace_metric" && return "trace_metric"
    ty == "client_report" && return "internal"
    ty == "profile" && return "profile"
    ty == "profile_chunk" && return "profile_chunk"
    ty == "check_in" && return "monitor"
    return "default"
end

payload_json(item::Item) = JSON.parse(String(copy(item.payload)))

"""
A sentry envelope: the unit that the transport sends, made of a header and
some items.
"""
struct Envelope
    headers::Dict{String,Any}
    items::Vector{Item}
end
Envelope(headers=Dict{String,Any}()) = Envelope(Dict{String,Any}(headers), Item[])

Base.push!(env::Envelope, item::Item) = (push!(env.items, item); env)

"""Writes the envelope in the newline separated wire format."""
function serialize_envelope(io::IO, env::Envelope)
    println(io, JSON.json(env.headers))
    for item in env.items
        headers = copy(item.headers)
        headers["length"] = length(item.payload)
        println(io, JSON.json(headers))
        write(io, item.payload)
        write(io, '\n')
    end
    return nothing
end
serialize_envelope(env::Envelope) = sprint(serialize_envelope, env)

"""Parses the wire format back into an envelope. Used by tests and tooling."""
function parse_envelope(data::Union{AbstractString,AbstractVector{UInt8}})
    bytes = data isa AbstractString ? Vector{UInt8}(data) : Vector{UInt8}(data)
    io = IOBuffer(bytes)
    headers = JSON.parse(readline(io))
    env = Envelope(Dict{String,Any}(headers), Item[])
    while !eof(io)
        line = readline(io)
        isempty(strip(line)) && continue
        h = Dict{String,Any}(JSON.parse(line))
        len = get(h, "length", nothing)
        payload = if len === nothing
            Vector{UInt8}(readline(io))
        else
            p = read(io, Int(len))
            # Skip the newline that ends the payload.
            if !eof(io)
                c = read(io, UInt8)
                c == UInt8('\n') || skip(io, -1)
            end
            p
        end
        delete!(h, "length")
        push!(env.items, Item(h, payload))
    end
    return env
end

function describe(env::Envelope)
    return join((data_category(i) for i in env.items), ", ")
end

##############################
# * Attachments
#----------------------------

"""
    Attachment(; bytes=nothing, path=nothing, json=nothing, filename=nothing,
               content_type=nothing, add_to_transactions=false,
               attachment_type="event.attachment")

A file sent along with an event. Give exactly one of `bytes` (a byte vector,
string, or a function that returns one), `path` (read when the event is sent),
or `json` (any value, written as JSON).
"""
Base.@kwdef struct Attachment
    bytes::Any = nothing
    path::Union{Nothing,String} = nothing
    json::Any = nothing
    filename::Union{Nothing,String} = nothing
    content_type::Union{Nothing,String} = nothing
    add_to_transactions::Bool = false
    attachment_type::String = "event.attachment"
end

function attachment_bytes(a::Attachment)
    if a.bytes !== nothing
        b = a.bytes isa Function ? a.bytes() : a.bytes
        return b isa AbstractString ? Vector{UInt8}(b) : Vector{UInt8}(b)
    elseif a.path !== nothing
        return read(a.path)
    elseif a.json !== nothing
        return Vector{UInt8}(JSON.json(serialize_value(a.json; databag=false)))
    end
    throw(ArgumentError("An attachment needs bytes, a path or json"))
end

function attachment_filename(a::Attachment)
    a.filename !== nothing && return a.filename
    a.path !== nothing && return basename(a.path)
    a.json !== nothing && return "attachment.json"
    return "attachment"
end

function attachment_content_type(a::Attachment)
    a.content_type !== nothing && return a.content_type
    a.json !== nothing && return "application/json"
    name = lowercase(attachment_filename(a))
    endswith(name, ".json") && return "application/json"
    endswith(name, ".txt") && return "text/plain"
    endswith(name, ".log") && return "text/plain"
    endswith(name, ".html") && return "text/html"
    endswith(name, ".png") && return "image/png"
    endswith(name, ".jpg") && return "image/jpeg"
    return "application/octet-stream"
end

function to_envelope_item(a::Attachment)
    return Item("attachment", attachment_bytes(a);
                filename=attachment_filename(a),
                content_type=attachment_content_type(a),
                attachment_type=a.attachment_type)
end

@testitem "envelopes" begin
    env = Sentry.Envelope(Dict("event_id" => "abc"))
    push!(env, Sentry.json_item("event", Dict("message" => "hi")))
    push!(env, Sentry.Item("attachment", Vector{UInt8}("raw\nbytes"); filename="a.txt", nothing_is_dropped=nothing))
    s = Sentry.serialize_envelope(env)
    lines = split(s, '\n')
    @test Sentry.JSON.parse(lines[1])["event_id"] == "abc"
    @test Sentry.JSON.parse(lines[2])["length"] == sizeof(lines[3])
    @test !haskey(Sentry.JSON.parse(lines[4]), "nothing_is_dropped")

    back = Sentry.parse_envelope(s)
    @test back.headers["event_id"] == "abc"
    @test length(back.items) == 2
    @test Sentry.payload_json(back.items[1])["message"] == "hi"
    @test String(back.items[2].payload) == "raw\nbytes"
    @test Sentry.describe(back) == "error, attachment"

    # Items without a length run to the end of the line.
    back = Sentry.parse_envelope("{}\n{\"type\":\"event\"}\n{\"a\":1}\n")
    @test Sentry.payload_json(back.items[1])["a"] == 1

    cats = Dict("session" => "session", "sessions" => "session", "transaction" => "transaction",
                "span" => "span", "log" => "log_item", "trace_metric" => "trace_metric",
                "client_report" => "internal", "profile" => "profile", "profile_chunk" => "profile_chunk",
                "check_in" => "monitor", "other" => "default")
    for (ty, cat) in cats
        @test Sentry.data_category(Sentry.Item(ty, UInt8[])) == cat
    end
end

@testitem "attachments" begin
    a = Sentry.Attachment(bytes="hello", filename="notes.txt")
    item = Sentry.to_envelope_item(a)
    @test String(item.payload) == "hello"
    @test item.headers["filename"] == "notes.txt"
    @test item.headers["content_type"] == "text/plain"
    @test item.headers["attachment_type"] == "event.attachment"

    @test String(Sentry.attachment_bytes(Sentry.Attachment(bytes=() -> "lazy"))) == "lazy"

    mktemp() do path, io
        write(io, "from disk")
        close(io)
        a = Sentry.Attachment(path=path)
        @test String(Sentry.attachment_bytes(a)) == "from disk"
        @test Sentry.attachment_filename(a) == basename(path)
    end

    j = Sentry.Attachment(json=(; a=1))
    @test Sentry.JSON.parse(String(Sentry.attachment_bytes(j)))["a"] == 1
    @test Sentry.attachment_filename(j) == "attachment.json"
    @test Sentry.attachment_content_type(j) == "application/json"

    @test Sentry.attachment_filename(Sentry.Attachment(bytes=UInt8[1])) == "attachment"
    for (name, ct) in ("x.json" => "application/json", "x.log" => "text/plain", "x.html" => "text/html",
                       "x.png" => "image/png", "x.jpg" => "image/jpeg", "x.bin" => "application/octet-stream")
        @test Sentry.attachment_content_type(Sentry.Attachment(bytes=UInt8[], filename=name)) == ct
    end
    @test Sentry.attachment_content_type(Sentry.Attachment(bytes=UInt8[], content_type="a/b")) == "a/b"
    @test_throws ArgumentError Sentry.attachment_bytes(Sentry.Attachment())
end
