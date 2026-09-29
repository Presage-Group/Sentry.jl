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

function init(dsn=nothing ; traces_sample_rate=nothing, traces_sampler=nothing, debug=false, release=nothing, shutdown_timeout=DEFAULT_SHUTDOWN_TIMEOUT)
    if main_hub.initialised
        # Returning early, otherwise we would leak another send_worker task.
        @warn "Sentry already initialised."
        return nothing
    end
    if dsn === nothing
        dsn = get(ENV, "SENTRY_DSN", nothing)
        if dsn === nothing
            # Abort - pretend nothing happened
            @warn "No DSN for Sentry.jl"
            return
        end
    end

    main_hub.debug = debug
    main_hub.shutdown_timeout = shutdown_timeout
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

    main_hub.sender_task = Threads.@spawn send_worker()
    atexit(clear_queue)
    bind(main_hub.queued_tasks, main_hub.sender_task)
    main_hub.initialised = true

    return nothing
end

@testitem "init" setup=[FakeSentry] begin
    @test Sentry.main_hub.shutdown_timeout == FakeSentry.shutdown_timeout

    # Re-initialising must not disturb the running hub.
    @test_warn "Sentry already initialised." Sentry.init("http://cafe@127.0.0.1:1/99")
    @test Sentry.main_hub.dsn == FakeSentry.dsn
end

@testitem "init without an explicit dsn" begin
    # `init` only does its work once per process and the shared hub is already
    # initialised, so the dsn fallbacks need a process of their own.
    code = """
        using Sentry, Test

        delete!(ENV, "SENTRY_DSN")
        @test_warn "No DSN for Sentry.jl" Sentry.init()
        @test Sentry.main_hub.initialised == false

        # Falls back to the environment, and takes a sampler object as given.
        ENV["SENTRY_DSN"] = "fake"
        sampler = () -> false
        Sentry.init(; traces_sampler=sampler)
        @test Sentry.main_hub.initialised
        @test Sentry.main_hub.dsn == "fake"
        @test Sentry.main_hub.traces_sampler === sampler
        """

    cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) --eval $code`
    @test success(pipeline(cmd, stdout=stdout, stderr=stderr))
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

    for (i, attachment) in enumerate(event.attachments)
        attachment_str = JSON.json((;data=attachment))
        # `filename` is required by sentry for attachment items.
        attachment_header = (; type="attachment",
                             length=sizeof(attachment_str),
                             filename="attachment-$i.json",
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
            main_hub.release,
            tags = MergeTags(global_tags, root_span.tags),

            contexts = (; trace),
            spans = FilterNothings.(spans),
            ) |> FilterNothings
    item_str = JSON.json(item)

    item_header = (; type="transaction",
                   content_type="application/json",
                   length=sizeof(item_str))


    println(buf, JSON.json(envelope_header))
    println(buf, JSON.json(item_header))
    println(buf, item_str)
    nothing
end

@testitem "incomplete spans warn in debug mode" begin
    transaction = Sentry.Transaction(name="job", root_span=Sentry.Span(timestamp=Sentry.nowstr()))
    push!(transaction.spans, Sentry.Span())  # deliberately never completed

    old_debug = Sentry.main_hub.debug
    Sentry.main_hub.debug = true
    try
        @test_warn "complete before the transaction completed" Sentry.PrepareBody(transaction, PipeBuffer())
    finally
        Sentry.main_hub.debug = old_debug
    end
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
            line = JSON.parse(line)
            line = JSON.json(line, 4)
        end
        @info "Would have sent this body"
        foreach(println, lines)
        return
    end
    r = HTTP.request("POST", target, headers, body)
    if r.status == 200
        return Vector{UInt8}(r.body)
    else
        throw(HTTP.StatusError(r.status, r))
    end
end

@testitem "fake dsn" setup=[FakeSentry] begin
    # The fake dsn pretty prints the envelope instead of sending it.
    dsn = Sentry.main_hub.dsn
    old_debug = Sentry.main_hub.debug
    Sentry.main_hub.dsn = "fake"
    Sentry.main_hub.debug = true
    try
        @test_logs (:info, "Sending HTTP request") (:info, "Would have sent this body") match_mode=:any Sentry.send_envelope(Sentry.Event(message=(; formatted="dry run")))
    finally
        Sentry.main_hub.dsn = dsn
        Sentry.main_hub.debug = old_debug
    end
end

@testitem "only 200 counts as sent" setup=[FakeSentry] begin
    # HTTP raises on a failure status itself, so a success status that sentry
    # would never send is what reaches the check in send_envelope.
    FakeSentry.response_status[] = 202
    try
        @test_throws Sentry.HTTP.StatusError Sentry.send_envelope(Sentry.Event(message=(; formatted="accepted")))
    finally
        FakeSentry.response_status[] = 200
    end
end

function send_worker()
    # Iterating the channel drains whatever is still buffered once it has been
    # closed, and then finishes, which is what lets clear_queue wait for the
    # sends themselves to complete rather than just for the queue to empty.
    for event in main_hub.queued_tasks
        try
            send_envelope(event)
        catch exc
            if main_hub.debug
                @error "Sentry error"
                showerror(stderr, exc, catch_backtrace())
            end
        end
    end
end

@testitem "a failed send does not kill the worker" setup=[FakeSentry] begin
    old_debug = Sentry.main_hub.debug
    Sentry.main_hub.debug = true
    FakeSentry.response_status[] = 202
    try
        FakeSentry.reset!()
        capture_message("rejected")
        parsed, _ = FakeSentry.next_envelope()
        @test parsed[3]["message"]["formatted"] == "rejected"

        # Waiting for a second envelope proves the worker got past the error,
        # because it sends one event at a time.
        FakeSentry.response_status[] = 200
        FakeSentry.reset!()
        capture_message("after the failure")
        parsed, _ = FakeSentry.next_envelope()
        @test parsed[3]["message"]["formatted"] == "after the failure"
        @test !istaskdone(Sentry.main_hub.sender_task)
    finally
        FakeSentry.response_status[] = 200
        Sentry.main_hub.debug = old_debug
    end
end

function clear_queue()
    close(main_hub.queued_tasks)
    if timedwait(() -> istaskdone(main_hub.sender_task), main_hub.shutdown_timeout) === :timed_out
        @warn "Timed out sending queued events to sentry"
    end
end

@testitem "flushing on exit" setup=[FakeSentry] begin
    # Needs a real process exit to run the atexit handler, and deliberately
    # does not wait for the send itself. The response is delayed so that
    # just emptying the queue is not enough to get the event through.
    code = """
        using Sentry
        Sentry.init("$(FakeSentry.dsn)"; shutdown_timeout=60.0)
        capture_message("sent while exiting")
        """

    FakeSentry.reset!()
    FakeSentry.response_delay[] = 3.0
    try
        elapsed = @elapsed run(`$(Base.julia_cmd()) --project=$(Base.active_project()) --eval $code`)

        # Exiting has to block until the send itself came back
        @test elapsed > FakeSentry.response_delay[]

        parsed, _ = FakeSentry.next_envelope()
        @test parsed[3]["message"]["formatted"] == "sent while exiting"
    finally
        FakeSentry.response_delay[] = 0.0
    end
end

@testitem "giving up on a stuck sender" setup=[FakeSentry] begin
    # Stands in a queue and a sender of its own, because clear_queue closes the
    # queue it is given and the real one has to survive for the other test items.
    hub = Sentry.main_hub
    old_queue, old_task, old_timeout = hub.queued_tasks, hub.sender_task, hub.shutdown_timeout
    blocked = Channel{Nothing}(0)
    hub.queued_tasks = Channel{Sentry.TaskPayload}(1)
    hub.sender_task = Threads.@spawn try
        wait(blocked)
    catch
    end
    hub.shutdown_timeout = 0.2
    try
        @test_logs (:warn, "Timed out sending queued events to sentry") Sentry.clear_queue()
    finally
        close(blocked)
        hub.queued_tasks, hub.sender_task, hub.shutdown_timeout = old_queue, old_task, old_timeout
    end
end

####################################
# * Basic capturing
#----------------------------------

function capture_event(task::TaskPayload)
    main_hub.initialised || return

    try
        push!(main_hub.queued_tasks, task)
    catch exc
        if !(exc isa InvalidStateException)
            rethrow()
        end

        # The queue is closed while shutting down, so there is nothing left to
        # send it to. Never let that propagate into the calling program.
        if main_hub.debug
            @error "Could not queue an event for sentry" exc
        end
    end
end

@testitem "queueing failures" setup=[FakeSentry] begin
    hub = Sentry.main_hub
    old_queue, old_debug = hub.queued_tasks, hub.debug
    try
        # A closed queue is what shutting down looks like: the event is dropped
        # rather than thrown at the calling program, and debug mode says so.
        hub.queued_tasks = Channel{Sentry.TaskPayload}(1)
        close(hub.queued_tasks)
        hub.debug = true
        @test_logs (:error, "Could not queue an event for sentry") capture_message("dropped")

        # Anything else is a real bug and must not be swallowed.
        hub.queued_tasks = 0
        @test_throws MethodError capture_message("broken")
    finally
        hub.queued_tasks, hub.debug = old_queue, old_debug
    end
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

@testitem "capture_message" setup=[FakeSentry] begin
    FakeSentry.reset!()
    set_tag("test", "message")

    capture_message("hello", Warn; attachments=[(; command="ls")])
    parsed, items = FakeSentry.next_envelope()
    _, event_header, event, attachment_header, attachment = parsed

    @test event_header["type"] == "event"
    @test event["level"] == "warning"
    @test event["message"]["formatted"] == "hello"
    @test event["release"] == "v1.2.3"
    @test event["tags"]["test"] == "message"

    # A declared length must not include the newline separating the items.
    @test event_header["length"] == sizeof(items[3])
    @test attachment_header["length"] == sizeof(items[5])

    @test attachment_header["type"] == "attachment"
    @test attachment_header["filename"] == "attachment-1.json"
    @test attachment["data"]["command"] == "ls"
end

@testitem "capture_message levels" setup=[FakeSentry] begin
    FakeSentry.reset!()

    for (level, expected) in ((Warn, "warning"), (Info, "info"), (Error, "error"))
        capture_message("test", level)
        parsed, _ = FakeSentry.next_envelope()
        @test parsed[3]["level"] == expected
    end

    # A level can also be given as the string sentry itself uses.
    capture_message("hello", "debug")
    parsed, _ = FakeSentry.next_envelope()
    @test parsed[3]["message"]["formatted"] == "hello"
    @test parsed[3]["level"] == "debug"
end

# This assumes that we are calling from within a catch
capture_exception(exc::Exception) = capture_exception([(exc, catch_backtrace())])
function capture_exception(exceptions=Base.current_exceptions())
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

@testitem "capture_exception" setup=[FakeSentry] begin
    FakeSentry.reset!()

    try
        error("boom")
    catch exc
        capture_exception(exc)
    end
    parsed, _ = FakeSentry.next_envelope()
    @test parsed[3]["level"] == "error"
    exception = parsed[3]["exception"]["values"][1]
    @test exception["type"] == "ErrorException"
    @test exception["value"] == "boom"
    @test !isempty(exception["stacktrace"]["frames"])

    # The zero argument method reads the current exception stack.
    try
        error("implicit boom")
    catch
        capture_exception()
    end
    parsed, _ = FakeSentry.next_envelope()
    @test parsed[3]["exception"]["values"][1]["value"] == "implicit boom"
end

@testitem "Sentry.jl" begin
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

