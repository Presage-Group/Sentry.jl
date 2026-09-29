module Sentry

using CodecZlib
using Dates
using HTTP
using JSON
using Logging
using PkgVersion
using UUIDs
using TestItems

include("structs.jl")
include("transactions.jl")

const global main_hub = Hub()
const global global_tags = Dict{String,String}()

const VERSION = @PkgVersion.Version 0

export capture_message,
    capture_exception,
    start_transaction,
    finish_transaction,
    set_task_transaction,
    set_tag,
    Info,
    Warn,
    Error,
    init

function init(dsn=nothing ; traces_sample_rate=nothing, traces_sampler=nothing, debug=false, release=nothing)
    main_hub.initialised && @warn "Sentry already initialised."
    if dsn === nothing
        dsn = get(ENV, "SENTRY_DSN", nothing)
        if dsn === nothing
            # Abort - pretend nothing happened
            @warn "No DSN for Sentry.jl"
            return
        end
    end

    if !main_hub.initialised
        atexit(clear_queue)
    end


    main_hub.debug = debug
    main_hub.dsn = dsn

    upstream, project_id, public_key = parse_dsn(dsn)
    main_hub.upstream = upstream
    main_hub.project_id = project_id
    main_hub.public_key = public_key

    main_hub.release = release

    @assert traces_sample_rate === nothing || traces_sampler === nothing
    if traces_sample_rate !== nothing
        main_hub.traces_sampler = RatioSampler(ratio = traces_sample_rate)
    elseif traces_sampler !== nothing
        main_hub.traces_sampler = traces_sampler
    else
        main_hub.traces_sampler = NoSamples()
    end

    main_hub.sender_task = @async send_worker()
    bind(main_hub.queued_tasks, main_hub.sender_task)
    main_hub.initialised = true

    return nothing
end

function parse_dsn(dsn)
    dsn == "fake" && return (; upstream="", project_id="", public_key="")

    m = match(r"(?'protocol'\w+)://(?'public_key'\w+)@(?'hostname'[\w\.]+(?::\d+)?)/(?'project_id'\w+)"a, dsn)
    m === nothing && error("dsn does not fit correct format")

    upstream = "$(m[:protocol])://$(m[:hostname])"

    return (; upstream, project_id=m[:project_id], public_key=m[:public_key])
end

####################################################
# * Globally applied things
#--------------------------------------------------


function set_tag(tag::String, data::String)
    if tag == "release"
        @warn "A 'release' tag is ignored by sentry upstream. You should instead set the release in the `init` call"
    end
    global_tags[tag] = data
end

##############################
# * Utils
#----------------------------

# Need to have an extra Z at the end - this indicates UTC
nowstr() = string(now(UTC)) * "Z" # COV_EXCL_LINE

@testitem "nowstr" begin
    s = Sentry.nowstr()
    @test s isa String
    @test endswith(s, "Z")
    @test length(s) > 1
end

# Useful util
macro ignore_exception(ex)
    quote
        try
            $(esc(ex))
        catch exc
            @error "Ignoring problem in sentry" exc
        end
    end
end


################################
# * Communication
#------------------------------

function generate_uuid4()
    # This is mostly just printing the UUID4 in the format we want.
    val = uuid4().value
    s = string(val, base=16)
    lpad(s, 32, '0')
end

FilterNothings(thing) = filter(x -> x.second !== nothing, pairs(thing))
function MergeTags(args...)
    args = filter(!=(nothing), args)
    isempty(args) && return nothing
    out = merge(pairs.(args)...)
    isempty(out) && return nothing
    out
end

function PrepareBody(event::Event, buf)
    envelope_header = (; event.event_id,
                       sent_at = nowstr(),
                       dsn = main_hub.dsn
                       )

    item = (;
            event.timestamp,
            event.platform,
            server_name = gethostname(),
            event.exception,
            event.message,
            event.level,
            main_hub.release,
            tags = MergeTags(global_tags, event.tags),
            ) |> FilterNothings
    item_str = JSON.json(item)

    item_header = (; type="event",
                   content_type="application/json",
                   length=sizeof(item_str))


    println(buf, JSON.json(envelope_header))
    println(buf, JSON.json(item_header))
    println(buf, item_str)

    for attachment in event.attachments
        attachment_str = JSON.json((;data=attachment))
        attachment_header = (; type="attachment",
                             length=sizeof(attachment_str),
                             content_type="application/json")

        println(buf, JSON.json(attachment_header))
        println(buf, attachment_str)
    end


    nothing
end

function PrepareBody(transaction::Transaction, buf)
    envelope_header = (; transaction.event_id,
                       sent_at = nowstr(),
                       dsn = main_hub.dsn
                       )

    if main_hub.debug && any(span -> span.timestamp === nothing, transaction.spans)
        @warn "At least one span didn't complete before the transaction completed"
    end

    spans = map(transaction.spans) do span
        (;
         transaction.trace_id,
         span.parent_span_id,
         span.span_id,
         span.tags,
         span.op,
         span.description,
         span.start_timestamp,
         span.timestamp)
    end
    #root_span = popfirst!(spans)
    # root_span = pop!(spans)
    root_span = transaction.root_span

    trace = (;
             transaction.trace_id,
             root_span.op,
             root_span.description,
             root_span.tags,
             root_span.span_id,
             root_span.parent_span_id,
            ) |> FilterNothings

    item = (; type="transaction",
            platform = "julia",
            server_name = gethostname(),
            transaction.event_id,
            transaction = transaction.name,
            # root_span...,
            root_span.start_timestamp,
            root_span.timestamp,
            tags = MergeTags(global_tags, root_span.tags),

            contexts = (; trace),
            spans = FilterNothings.(spans),
            ) |> FilterNothings
    item_str = JSON.json(item)

    item_header = (; type="transaction",
                   content_type="application/json",
                   length=sizeof(item_str)+1) # +1 for the newline to come


    println(buf, JSON.json(envelope_header))
    println(buf, JSON.json(item_header))
    println(buf, item_str)
    nothing
end

# The envelope version
function send_envelope(task::TaskPayload)
    target = "$(main_hub.upstream)/api/$(main_hub.project_id)/envelope/"

    headers = ["Content-Type" => "application/x-sentry-envelope",
               "content-encoding" => "gzip",
               "User-Agent" => "Sentry.jl/$VERSION",
               "X-Sentry-Auth" => "Sentry sentry_version=7, sentry_client=Sentry.jl/$VERSION, sentry_timestamp=$(nowstr()), sentry_key=$(main_hub.public_key)"
               ]

    buf = PipeBuffer()
    stream = CodecZlib.GzipCompressorStream(buf)
    PrepareBody(task, buf)
    body = read(stream)
    close(stream)

    if main_hub.debug
        @info "Sending HTTP request" typeof(task)
    end
    if main_hub.dsn === "fake"
        body = String(transcode(CodecZlib.GzipDecompressor, body))
        lines = map(eachline(IOBuffer(body))) do line
            line = JSON.Parser.parse(line)
            line = JSON.json(line, 4)
        end
        @info "Would have sent this body"
        foreach(println, lines)
        return
    end
    r = HTTP.request("POST", target, headers, body)
    if r.status == 200
        return r.body
    else
        throw(HTTP.Exceptions.StatusError(r.status, "POST", target, r))
    end
    return nothing
end

function send_worker()
    while true
        try
            event = take!(main_hub.queued_tasks)
            yield()
            send_envelope(event)
        catch exc
            if main_hub.debug
                @error "Sentry error"
                showerror(stderr, exc, catch_backtrace())
            end
        end
    end
end

function clear_queue()
    while isready(main_hub.queued_tasks)
        @info "Waiting for queue to finish before closing"
        # send_envelope(take!(main_hub.queued_tasks))
        sleep(1)
    end
end

####################################
# * Basic capturing
#----------------------------------

function capture_event(task::TaskPayload)
    main_hub.initialised || return

    push!(main_hub.queued_tasks, task)
end

function capture_message(message, level::LogLevel=Info ; kwds...)
    level_str = if level == Warn
        "warning"
    else
        lowercase(string(level))
    end
    capture_message(message, level_str ; kwds...)
end
function capture_message(message, level::String ; tags=nothing, attachments::Vector=[])
    main_hub.initialised || return

    capture_event(Event(;
                        message=(; formatted=message),
                        level,
                        attachments,
                        tags))
end

@testitem "capture_message levels" begin
    old_init = Sentry.main_hub.initialised
    Sentry.main_hub.initialised = true
    while isready(Sentry.main_hub.queued_tasks)
        take!(Sentry.main_hub.queued_tasks)
    end

    capture_message("test", Warn)
    ev = take!(Sentry.main_hub.queued_tasks)
    @test ev isa Sentry.Event
    @test ev.level == "warning"

    capture_message("test", Info)
    ev = take!(Sentry.main_hub.queued_tasks)
    @test ev.level == "info"

    capture_message("test", Error)
    ev = take!(Sentry.main_hub.queued_tasks)
    @test ev.level == "error"

    capture_message("hello", "debug")
    ev = take!(Sentry.main_hub.queued_tasks)
    @test ev.message.formatted == "hello"
    @test ev.level == "debug"

    Sentry.main_hub.initialised = old_init
end

# This assumes that we are calling from within a catch
capture_exception(exc::Exception) = capture_exception([(exc, catch_backtrace())])
function capture_exception(exceptions=catch_stack())
    main_hub.initialised || return

    formatted_excs = map(exceptions) do (exc,strace)
        bt = Base.scrub_repl_backtrace(strace)
        # frames = map(Base.stacktrace(strace, false)) do frame
        frames = map(bt) do frame
            Dict(:filename => frame.file,
             :function => frame.func,
             :lineno => frame.line)
        end

        Dict(:type => typeof(exc).name.name,
         :module => string(typeof(exc).name.module),
         :value => hasproperty(exc, :msg) ? exc.msg : sprint(showerror, exc),
         :stacktrace => (;frames=reverse(frames)))
    end
    capture_event(Event(exception=(;values=formatted_excs),
                        level="error"))
end

@testitem "capture_exception" begin
    old_init = Sentry.main_hub.initialised
    Sentry.main_hub.initialised = true
    while isready(Sentry.main_hub.queued_tasks)
        take!(Sentry.main_hub.queued_tasks)
    end

    try
        error("test error")
    catch exc
        capture_exception(exc)
    end

    ev = take!(Sentry.main_hub.queued_tasks)
    @test ev isa Sentry.Event
    @test ev.level == "error"
    @test !isempty(ev.exception.values)
    exc_info = ev.exception.values[1]
    @test exc_info[:type] == :ErrorException
    @test exc_info[:value] == "test error"
    @test haskey(exc_info, :stacktrace)
    @test !isempty(exc_info[:stacktrace].frames)

    Sentry.main_hub.initialised = old_init
end

@testitem "Sentry.jl" begin
    Sentry.init()

    @test Sentry.parse_dsn("fake") == (upstream = "", project_id = "", public_key = "")
    @test_throws ErrorException Sentry.parse_dsn("https://0000000000000000000000000000000000000000.ingest.sentry.io/0000000")
    @test Sentry.parse_dsn("https://abcdef1234567890@a12345.us.sentry.io/1234567890123456789") == (upstream = "https://a12345.us.sentry.io", project_id = "1234567890123456789", public_key = "abcdef1234567890")

    set_tag("test", "message")
    @test Sentry.global_tags["test"] == "message"
    @test_warn "A 'release' tag is ignored by sentry upstream. You should instead set the release in the `init` call" set_tag("release", "v1.0")
    @test Sentry.global_tags["release"] == "v1.0"

    @test length(Sentry.generate_uuid4()) == 32
    @test all(c -> c in '0':'9' || c in 'a':'f', Sentry.generate_uuid4())

    d = Sentry.FilterNothings([1, nothing, 2])
    @test d[3] == 2
    @test d[1] == 1

    @test Sentry.MergeTags() === nothing
    @test Sentry.MergeTags(nothing) === nothing
    @test Sentry.MergeTags(nothing, nothing) === nothing
    @test Sentry.MergeTags(Dict{String,String}()) === nothing
    merged = Sentry.MergeTags(Dict("a" => "1"), Dict("b" => "2"))
    @test merged["a"] == "1"
    @test merged["b"] == "2"
    @test Sentry.MergeTags(Dict("a" => "1"), Dict("a" => "2"))["a"] == "2"
    @test Sentry.MergeTags(Dict("x" => "1"), nothing)["x"] == "1"
end

end

