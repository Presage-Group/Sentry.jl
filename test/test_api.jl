@testitem "init" setup=[SentryTest] begin
    client = SentryTest.init!()
    @test client isa Sentry.Client
    @test Sentry.is_initialized()
    @test get_client() === client
    @test client.options.release == "v1.2.3"
    @test client.dsn.project_id == "42"
    @test occursin("Sentry.Client", repr(client))

    # Calling init again replaces the client, closing the previous one.
    client2 = SentryTest.init!()
    @test client.closed
    @test get_client() === client2

    # Without a DSN nothing is set up.
    withenv("SENTRY_DSN" => nothing, "SENTRY_SPOTLIGHT" => nothing) do
        @test Sentry.init() === nothing
        @test_logs (:warn, "No DSN for Sentry.jl") Sentry.init(; debug=true)
    end
    @test get_client() === client2

    Sentry.close()
    @test !Sentry.is_initialized()
    @test get_client() === nothing
    @test Sentry.close() === nothing
    @test Sentry.flush()
    # Nothing is captured without a client.
    @test capture_message("dropped") === nothing
    @test capture_exception(ErrorException("x")) === nothing
    @test capture_checkin(; monitor_slug="m") isa String
    Sentry._debug_enabled[] = false
end

@testitem "init without an explicit dsn" begin
    # The dsn fallbacks need a process of their own.
    code = """
        using Sentry, Test
        delete!(ENV, "SENTRY_DSN")
        @test Sentry.init() === nothing
        @test !Sentry.is_initialized()

        ENV["SENTRY_DSN"] = "fake"
        c = Sentry.init(; traces_sampler=() -> false, auto_session_tracking=false)
        @test Sentry.is_initialized()
        @test c.options.dsn == "fake"
        @test c.transport isa Sentry.PrintTransport
        """
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) --eval $code`
    @test success(pipeline(cmd, stdout=devnull, stderr=stderr))
end

@testitem "capture_message" setup=[SentryTest] begin
    SentryTest.init!()
    set_tag("test", "message")

    id = capture_message("hello", Warn; attachments=[(; command="ls")], tags=(; extra_tag=1))
    @test id isa String
    @test last_event_id() == id
    env = only(SentryTest.envelopes())
    @test env.headers["event_id"] == id
    @test haskey(env.headers, "sent_at")
    @test env.headers["trace"]["public_key"] == "public"
    @test env.headers["trace"]["org_id"] == "1"
    event = Sentry.payload_json(env.items[1])
    @test event["level"] == "warning"
    @test event["message"]["formatted"] == "hello"
    @test event["release"] == "v1.2.3"
    @test event["environment"] == "production"
    @test event["platform"] == "julia"
    @test event["tags"]["test"] == "message"
    @test event["tags"]["extra_tag"] == "1"
    @test event["sdk"]["name"] == "sentry.julia"
    @test "DedupeIntegration" in event["sdk"]["integrations"]
    @test haskey(event["contexts"], "trace")
    @test haskey(event["contexts"], "runtime")
    @test event["contexts"]["runtime"]["name"] == "julia"
    @test haskey(event["contexts"], "os")
    @test haskey(event["contexts"], "device")
    @test haskey(event["modules"], "HTTP")
    @test event["extra"]["sys.argv"] isa Vector

    attachment = env.items[2]
    @test attachment.headers["type"] == "attachment"
    @test attachment.headers["filename"] == "attachment-1.json"
    @test Sentry.payload_json(attachment)["data"]["command"] == "ls"

    # Per event data does not stick to the scope.
    capture_message("again")
    @test !haskey(SentryTest.last_event()["tags"], "extra_tag")
end

@testitem "capture_message levels" setup=[SentryTest] begin
    SentryTest.init!()
    for (level, expected) in ((Warn, "warning"), (Info, "info"), (Error, "error"), ("debug", "debug"),
                              ("warn", "warning"), (:fatal, "fatal"))
        capture_message("test", level)
        @test SentryTest.last_event()["level"] == expected
    end
    capture_message("default level")
    @test SentryTest.last_event()["level"] == "info"
end

@testitem "capture_exception" setup=[SentryTest] begin
    SentryTest.init!()

    try
        error("boom")
    catch exc
        capture_exception(exc)
    end
    event = SentryTest.last_event()
    @test event["level"] == "error"
    exception = only(event["exception"]["values"])
    @test exception["type"] == "ErrorException"
    @test exception["module"] == "Core"
    @test exception["value"] == "boom"
    @test exception["mechanism"] == Dict("type" => "generic", "handled" => true)
    frames = exception["stacktrace"]["frames"]
    @test !isempty(frames)
    # The innermost frame is last, and belongs to this test, with its source.
    @test any(f -> get(f, "in_app", false), frames)
    @test any(f -> occursin("error(\"boom\")", get(f, "context_line", "")), frames)
    base_frames = filter(f -> get(f, "module", "") == "Base", frames)
    @test all(f -> f["in_app"] == false, base_frames)

    # The zero argument method reads the current exception stack.
    try
        error("implicit boom")
    catch
        capture_exception()
    end
    @test only(SentryTest.last_event()["exception"]["values"])["value"] == "implicit boom"

    # An exception with an explicit backtrace, and one outside a catch block.
    capture_exception(ArgumentError("given"), backtrace())
    @test only(SentryTest.last_event()["exception"]["values"])["type"] == "ArgumentError"
    capture_exception(DomainError(1, "no backtrace"))
    @test only(SentryTest.last_event()["exception"]["values"])["type"] == "DomainError"

    # Nothing to report outside of a catch block.
    @test capture_exception() === nothing
end

@testitem "chained exceptions" setup=[SentryTest] begin
    SentryTest.init!()
    try
        try
            error("inner")
        catch
            throw(ArgumentError("outer"))
        end
    catch exc
        capture_exception(exc)
    end
    values = SentryTest.last_event()["exception"]["values"]
    @test length(values) == 2
    # Oldest first: the cause, then the error being reported.
    @test values[1]["value"] == "inner"
    @test values[2]["value"] == "outer"
    @test values[2]["mechanism"]["exception_id"] == 0
    @test !haskey(values[2]["mechanism"], "parent_id")
    @test values[1]["mechanism"]["exception_id"] == 1
    @test values[1]["mechanism"]["parent_id"] == 0
end

@testitem "task and composite exceptions" setup=[SentryTest] begin
    SentryTest.init!()
    t = @async error("in a task")
    try
        wait(t)
    catch exc
        capture_exception(exc)
    end
    values = SentryTest.last_event()["exception"]["values"]
    @test [v["type"] for v in values] == ["ErrorException", "TaskFailedException"]
    @test values[1]["value"] == "in a task"
    @test values[1]["mechanism"]["parent_id"] == values[2]["mechanism"]["exception_id"]

    composite = CompositeException([CapturedException(ErrorException("a"), backtrace()), ArgumentError("b")])
    capture_exception(composite, backtrace())
    values = SentryTest.last_event()["exception"]["values"]
    @test [v["type"] for v in values] == ["ErrorException", "ArgumentError", "CompositeException"]
    @test values[3]["mechanism"]["is_exception_group"] == true
    @test values[1]["mechanism"]["parent_id"] == values[3]["mechanism"]["exception_id"]
    @test haskey(values[1], "stacktrace")

    # A stack of (exception, backtrace) pairs is accepted as is.
    capture_exception([(ErrorException("from a stack"), backtrace())])
    @test only(SentryTest.last_event()["exception"]["values"])["value"] == "from a stack"
end

@testitem "capture_event" setup=[SentryTest] begin
    SentryTest.init!()
    id = capture_event(Dict("message" => "raw", "level" => "debug"); hint=(; x=1), user=(; id=5),
                       fingerprint=["a", :b], contexts=Dict("c" => Dict("k" => 1)), extras=(; e=2))
    event = SentryTest.last_event()
    @test event["event_id"] == id
    @test event["message"] == "raw"
    @test event["user"]["id"] == 5
    @test event["fingerprint"] == ["a", "b"]
    @test event["contexts"]["c"]["k"] == 1
    @test event["extra"]["e"] == 2

    # A function changes the merged scope for this event only.
    capture_event(Dict("message" => "fn"); scope=s -> Sentry.set_tag(s, "via", "function"))
    @test SentryTest.last_event()["tags"]["via"] == "function"

    # As does a scope, merged on top.
    extra_scope = Sentry.Scope()
    Sentry.set_tag(extra_scope, "via", "scope")
    capture_event(Dict("message" => "scope"); scope=extra_scope)
    @test SentryTest.last_event()["tags"]["via"] == "scope"
end

@testitem "scope data" setup=[SentryTest] begin
    SentryTest.init!()
    @test_logs (:warn, r"release") set_tag("release", "v1")
    set_tags(Dict("a" => 1, :b => "2"))
    set_extra("extra", [1, 2])
    set_context("character", Dict("name" => "Mighty Fighter"))
    set_user((; id="u1", email="a@b.c"))
    set_level("warning")
    set_fingerprint(["{{ default }}", "custom"])
    Sentry.set_transaction_name("the-transaction"; source="custom")
    capture_message("with data", Error)
    e = SentryTest.last_event()
    @test e["tags"]["a"] == "1"
    @test e["tags"]["b"] == "2"
    @test e["extra"]["extra"] == [1, 2]
    @test e["contexts"]["character"]["name"] == "Mighty Fighter"
    @test e["user"]["id"] == "u1"
    # The scope's level overrides the event's.
    @test e["level"] == "warning"
    @test e["fingerprint"] == ["{{ default }}", "custom"]
    @test e["transaction"] == "the-transaction"
    @test e["transaction_info"]["source"] == "custom"

    Sentry.remove_tag("a")
    Sentry.remove_extra("extra")
    Sentry.remove_context("character")
    set_user(nothing)
    capture_message("less data")
    e = SentryTest.last_event()
    @test !haskey(e["tags"], "a")
    @test !haskey(e, "user")
    @test !haskey(get(e, "extra", Dict()), "extra")
    @test !haskey(e["contexts"], "character")

    Sentry.clear!(get_isolation_scope())
    capture_message("cleared")
    @test !haskey(SentryTest.last_event(), "fingerprint")
    @test occursin("Sentry.Scope(:isolation", repr(get_isolation_scope()))
    Sentry.configure_scope(s -> Sentry.set_tag(s, "configured", "yes"))
    capture_message("configured")
    @test SentryTest.last_event()["tags"]["configured"] == "yes"
end

@testitem "global scope" setup=[SentryTest] begin
    SentryTest.init!()
    Sentry.set_tag(get_global_scope(), "everywhere", "yes")
    isolation_scope() do _
        capture_message("isolated")
    end
    @test SentryTest.last_event()["tags"]["everywhere"] == "yes"
end

@testitem "new_scope and isolation_scope" setup=[SentryTest] begin
    SentryTest.init!()
    set_tag("outer", "1")

    new_scope() do scope
        Sentry.set_tag(scope, "inner", "1")
        capture_message("inside")
    end
    @test SentryTest.last_event()["tags"]["inner"] == "1"
    capture_message("outside")
    @test !haskey(SentryTest.last_event()["tags"], "inner")

    isolation_scope() do
        set_tag("isolated", "1")
        add_breadcrumb(message="isolated crumb")
        capture_message("in isolation")
        e = SentryTest.last_event()
        @test e["tags"]["outer"] == "1"
        @test e["tags"]["isolated"] == "1"
    end
    capture_message("after isolation")
    e = SentryTest.last_event()
    @test !haskey(e["tags"], "isolated")
    @test !any(c -> get(c, "message", "") == "isolated crumb", get(get(e, "breadcrumbs", Dict()), "values", []))

    # The last event id belongs to the isolation scope.
    outer_id = last_event_id()
    isolation_scope() do
        capture_message("inner id")
        @test last_event_id() != outer_id
    end
    @test last_event_id() == outer_id

    # Scopes are inherited by tasks.
    isolation_scope() do
        set_tag("task", "inherited")
        fetch(Threads.@spawn capture_message("from a task"))
    end
    @test SentryTest.last_event()["tags"]["task"] == "inherited"

    s = Sentry.Scope()
    Sentry.set_tag(s, "used", "yes")
    Sentry.use_scope(s) do
        @test get_current_scope() === s
        capture_message("used")
    end
    @test SentryTest.last_event()["tags"]["used"] == "yes"
    iso = Sentry.Scope(:isolation)
    Sentry.use_isolation_scope(iso) do
        @test get_isolation_scope() === iso
    end
    Sentry.push_scope() do scope
        @test scope isa Sentry.Scope
    end
end

@testitem "breadcrumbs" setup=[SentryTest] begin
    SentryTest.init!(; max_breadcrumbs=3,
                     before_breadcrumb=(crumb, hint) -> get(crumb, "message", "") == "drop me" ? nothing :
                                                        (crumb["data"] = Dict("hint" => get(hint, "h", nothing)); crumb))
    add_breadcrumb(Dict("message" => "one", "timestamp" => 1.0); hint=(; h=1))
    add_breadcrumb(message="drop me")
    add_breadcrumb(message="two", category="cat", level=Warn)
    add_breadcrumb(message="three")
    add_breadcrumb(message="four")
    add_breadcrumb()  # nothing to record
    capture_message("with crumbs")
    crumbs = SentryTest.last_event()["breadcrumbs"]["values"]
    @test [c["message"] for c in crumbs] == ["two", "three", "four"]
    @test crumbs[1]["level"] == "warning"
    @test crumbs[1]["category"] == "cat"
    @test crumbs[1]["type"] == "default"
    @test get_isolation_scope().n_breadcrumbs_truncated == 1

    Sentry.clear_breadcrumbs()
    capture_message("no crumbs")
    @test isempty(SentryTest.last_event()["breadcrumbs"]["values"])

    # A failing before_breadcrumb keeps the breadcrumb.
    SentryTest.init!(; before_breadcrumb=(c, h) -> error("broken"))
    add_breadcrumb(message="kept")
    capture_message("x")
    @test SentryTest.last_event()["breadcrumbs"]["values"][1]["message"] == "kept"

    # Breadcrumbs from the past are sorted by time.
    add_breadcrumb(message="earlier", timestamp="2000-01-01T00:00:00Z")
    capture_message("y")
    @test SentryTest.last_event()["breadcrumbs"]["values"][1]["message"] == "earlier"
end

@testitem "before_send" setup=[SentryTest] begin
    SentryTest.init!(; before_send=(event, hint) -> begin
        get(event["message"], "formatted", "") == "drop" && return nothing
        get(event["message"], "formatted", "") == "fail" && error("before_send failed")
        event["tags"] = Dict("changed" => "yes")
        event
    end)
    capture_message("keep")
    @test SentryTest.last_event()["tags"]["changed"] == "yes"
    n = length(SentryTest.events())
    @test capture_message("drop") === nothing
    @test capture_message("fail") === nothing
    @test length(SentryTest.events()) == n

    # before_send sees the exception in its hint.
    seen = Ref{Any}(nothing)
    SentryTest.init!(; before_send=(event, hint) -> (seen[] = hint["exception"]; event))
    capture_exception(ArgumentError("hinted"), backtrace())
    @test seen[] isa ArgumentError
end

@testitem "event processors" setup=[SentryTest] begin
    SentryTest.init!()
    Sentry.add_event_processor((event, hint) -> (event["extra"]["processed"] = true; event))
    Sentry.add_event_processor((event, hint) -> get(event, "level", "") == "debug" ? nothing : event)
    Sentry.add_event_processor((event, hint) -> error("a failing processor is skipped"))
    Sentry.add_error_processor((event, exc) -> exc isa DomainError ? nothing : (event["tags"] = Dict("err" => "yes"); event))
    Sentry.add_error_processor((event, exc) -> error("also skipped"))
    capture_message("processed")
    @test SentryTest.last_event()["extra"]["processed"] == true
    @test capture_message("dropped", "debug") === nothing
    capture_exception(ArgumentError("error processed"), backtrace())
    @test SentryTest.last_event()["tags"]["err"] == "yes"
    @test capture_exception(DomainError(1), backtrace()) === nothing
end

@testitem "ignore_errors" setup=[SentryTest] begin
    SentryTest.init!(; ignore_errors=[ArgumentError, "DomainError", "Core.BoundsError", e -> e isa KeyError])
    @test capture_exception(ArgumentError("x"), backtrace()) === nothing
    @test capture_exception(DomainError(1), backtrace()) === nothing
    @test capture_exception(BoundsError([1], 2), backtrace()) === nothing
    @test capture_exception(KeyError(1), backtrace()) === nothing
    @test capture_exception(ErrorException("kept"), backtrace()) isa String
end

@testitem "error sampling" setup=[SentryTest] begin
    SentryTest.init!(; sample_rate=0.0)
    @test capture_message("never") === nothing
    SentryTest.init!(; error_sampler=(event, hint) -> get(event, "level", "") == "error" ? 1.0 : 0.0)
    @test capture_message("sampled", Error) isa String
    @test capture_message("unsampled", Info) === nothing
    # Invalid or failing samplers keep the event.
    SentryTest.init!(; error_sampler=(event, hint) -> "invalid")
    @test capture_message("kept") isa String
    SentryTest.init!(; error_sampler=(event, hint) -> error("broken"))
    @test capture_message("kept too") isa String
end

@testitem "attach_stacktrace" setup=[SentryTest] begin
    SentryTest.init!(; attach_stacktrace=true)
    capture_message("with a stack")
    thread = only(SentryTest.last_event()["threads"]["values"])
    @test thread["current"] == true
    frames = thread["stacktrace"]["frames"]
    @test !isempty(frames)
    # The SDK's own frames are left out.
    @test get(frames[end], "module", "") != "Sentry"
end

@testitem "dedupe" setup=[SentryTest] begin
    SentryTest.init!()
    exc = ArgumentError("same")
    bt = backtrace()
    @test capture_exception(exc, bt) isa String
    @test capture_exception(exc, bt) === nothing
    @test capture_exception(ArgumentError("other"), bt) isa String

    # A dropped event does not count as seen.
    SentryTest.init!(; before_send=(e, h) -> nothing)
    capture_exception(exc, bt)
    SentryTest.init!()
    @test capture_exception(exc, bt) isa String

    SentryTest.init!(; disabled_integrations=[Sentry.DedupeIntegration])
    @test capture_exception(exc, bt) isa String
    @test capture_exception(exc, bt) isa String
end

@testitem "attachments" setup=[SentryTest] begin
    SentryTest.init!()
    add_attachment(; bytes="file contents", filename="notes.txt")
    add_attachment(Attachment(json=Dict("k" => "v"), filename="data.json", add_to_transactions=true))
    capture_message("with attachments")
    env = last(SentryTest.envelopes())
    @test [Sentry.item_type(i) for i in env.items] == ["event", "attachment", "attachment"]
    @test String(env.items[2].payload) == "file contents"
    @test env.items[2].headers["content_type"] == "text/plain"

    # Only attachments marked for it are sent with transactions.
    SentryTest.init!(; traces_sample_rate=1.0)
    add_attachment(; bytes="error only", filename="e.txt")
    add_attachment(Attachment(bytes="both", filename="b.txt", add_to_transactions=true))
    start_transaction(name="t") do _ end
    env = last(SentryTest.envelopes())
    @test [Sentry.item_type(i) for i in env.items] == ["transaction", "attachment"]
    @test String(env.items[2].payload) == "both"

    # A broken attachment is skipped rather than losing the event.
    add_attachment(; path="/does/not/exist")
    @test capture_message("still sent") isa String
end

@testitem "scrubbing and pii" setup=[SentryTest] begin
    SentryTest.init!()
    set_extra("password", "hunter2")
    set_user(Dict("id" => 1, "ip_address" => "10.0.0.1"))
    capture_message("scrubbed")
    e = SentryTest.last_event()
    @test e["extra"]["password"] == "[Filtered]"
    @test !haskey(e["user"], "ip_address")

    SentryTest.init!(; send_default_pii=true)
    set_user(Dict("id" => 1, "ip_address" => "10.0.0.1"))
    capture_message("pii")
    @test SentryTest.last_event()["user"]["ip_address"] == "10.0.0.1"

    SentryTest.init!(; event_scrubber=Sentry.EventScrubber(; denylist=["custom"], recursive=true))
    set_extra("nested", Dict("custom" => 1))
    capture_message("custom scrubber")
    @test SentryTest.last_event()["extra"]["nested"]["custom"] == "[Filtered]"
end

@testitem "serialization limits" setup=[SentryTest] begin
    SentryTest.init!(; max_value_length=20, custom_repr=x -> x isa Symbol ? nothing : nothing)
    set_extra("long", "x"^100)
    set_extra("deep", Dict("a" => Dict("b" => Dict("c" => Dict("d" => Dict("e" => 1))))))
    set_extra("object", Base.Threads.Atomic{Int}(3))
    capture_message("limited")
    e = SentryTest.last_event()
    @test length(e["extra"]["long"]) == 20
    @test e["extra"]["deep"]["a"]["b"]["c"]["d"] isa String
    @test e["extra"]["object"] isa String
end

@testitem "in_app" setup=[SentryTest] begin
    options = Sentry.make_options(; in_app_include=["MyPkg"], in_app_exclude=["MyApp.Vendored"])
    @test Sentry.is_in_app("MyPkg.Sub", "/somewhere/.julia/packages/MyPkg/x/src/a.jl", options)
    @test !Sentry.is_in_app("MyApp.Vendored", "/app/src/v.jl", options)
    @test !Sentry.is_in_app("Base", nothing, options)
    @test !Sentry.is_in_app("Base.Iterators", "/x/base/iterators.jl", options)
    @test !Sentry.is_in_app("Sentry", "/x/Sentry/src/api.jl", options)
    @test Sentry.is_in_app(nothing, nothing, options)
    @test Sentry.is_in_app("Main", joinpath(pwd(), "script.jl"), options)
    pkgfile = joinpath(first(DEPOT_PATH), "packages", "Foo", "abc", "src", "Foo.jl")
    @test !Sentry.is_in_app("Foo", pkgfile, options)
    @test !Sentry.is_in_app("LinearAlgebra", joinpath(Sys.STDLIB, "LinearAlgebra", "src", "x.jl"), options)
    @test Sentry.frame_abs_path("REPL[1]") === nothing
    @test Sentry.frame_abs_path("not/absolute.jl") === nothing
    @test Sentry.frame_abs_path(@__FILE__) == @__FILE__

    # Source context is read from the file, and can be switched off.
    frame = Sentry.add_source_context!(Dict{String,Any}(), @__FILE__, 1)
    @test frame["pre_context"] == []
    @test haskey(frame, "context_line")
    @test Sentry.add_source_context!(Dict{String,Any}(), "/does/not/exist.jl", 3) == Dict()
    @test Sentry.add_source_context!(Dict{String,Any}(), @__FILE__, 10^7) == Dict()

    SentryTest.init!(; include_source_context=false, max_stack_frames=2)
    capture_exception(ErrorException("x"), backtrace())
    frames = only(SentryTest.last_event()["exception"]["values"])["stacktrace"]["frames"]
    @test length(frames) == 2
    @test !any(f -> haskey(f, "context_line"), frames)
end

@testitem "flush and close" setup=[SentryTest] begin
    SentryTest.init!(; enable_logs=true)
    Sentry.Logs.info("buffered")
    @test isempty(SentryTest.items("log"))
    @test Sentry.flush(; timeout=5)
    @test length(SentryTest.items("log")) == 1

    Sentry.Logs.info("sent on close")
    Sentry.close()
    @test length(SentryTest.items("log")) == 2
    @test !Sentry.is_initialized()

    # Sentry.flush and Sentry.close still work on IO.
    io = IOBuffer()
    Sentry.flush(io)
    Sentry.close(io)
    @test !isopen(io)
end

@testitem "custom transports" begin
    got = Sentry.Envelope[]
    Sentry.init("https://k@example.com/1"; transport=e -> push!(got, e), auto_session_tracking=false)
    capture_message("to a function")
    @test length(got) == 1
    Sentry.close()

    struct Minimal <: Sentry.AbstractTransport end
    Sentry.capture_envelope(::Minimal, env) = push!(got, env)
    Sentry.init("https://k@example.com/1"; transport=Minimal(), auto_session_tracking=false)
    capture_message("to a transport")
    @test length(got) == 2
    @test Sentry.flush_transport(Minimal(), 1)
    @test Sentry.kill_transport(Minimal()) === nothing
    @test Sentry.record_lost_event(Minimal(), "r", Sentry.Item("event", UInt8[])) === nothing
    Sentry.close()
end

@testitem "integrations" setup=[SentryTest] begin
    struct Counting <: Sentry.Integration
        calls::Vector{Symbol}
    end
    Sentry.setup_once(::Type{Counting}) = nothing
    Sentry.setup!(i::Counting, client) = push!(i.calls, :setup)
    Sentry.teardown!(i::Counting, client) = push!(i.calls, :teardown)

    i = Counting(Symbol[])
    client = SentryTest.init!(; integrations=[i])
    @test Sentry.get_integration(client, Counting) === i
    @test Sentry.get_integration(client, "Counting") === i
    @test Sentry.get_integration(nothing, Counting) === nothing
    @test Sentry.integration_identifier(i) == "Counting"
    Sentry.close()
    @test i.calls == [:setup, :teardown]

    client = SentryTest.init!(; default_integrations=false)
    @test isempty(client.integrations)
    client = SentryTest.init!(; disabled_integrations=["ArgvIntegration", Sentry.ModulesIntegration(), Sentry.RuntimeContextIntegration])
    @test Sentry.get_integration(client, Sentry.ArgvIntegration) === nothing
    @test Sentry.get_integration(client, Sentry.ModulesIntegration) === nothing
    @test Sentry.get_integration(client, Sentry.RuntimeContextIntegration) === nothing
    capture_message("no default data")
    e = SentryTest.last_event()
    @test !haskey(e, "modules")
    @test !haskey(get(e, "extra", Dict()), "sys.argv")
    @test !haskey(e["contexts"], "runtime")

    # A failing integration is skipped.
    struct Broken <: Sentry.Integration end
    Sentry.setup!(::Broken, client) = error("cannot set up")
    client = @test_logs (:warn, r"could not set up integration Broken") match_mode=:any SentryTest.init!(; integrations=[Broken])
    @test Sentry.get_integration(client, Broken) === nothing
end

@testitem "cloud resource context" setup=[SentryTest] begin
    SentryTest.init!()
    withenv("AWS_LAMBDA_FUNCTION_NAME" => "fn", "AWS_REGION" => "us-east-1") do
        capture_message("on lambda")
    end
    ctx = SentryTest.last_event()["contexts"]["cloud_resource"]
    @test ctx["cloud.provider"] == "aws"
    @test ctx["faas.name"] == "fn"

    clean = ("AWS_LAMBDA_FUNCTION_NAME" => nothing, "ECS_CONTAINER_METADATA_URI_V4" => nothing,
             "ECS_CONTAINER_METADATA_URI" => nothing, "K_SERVICE" => nothing, "FUNCTION_TARGET" => nothing,
             "WEBSITE_SITE_NAME" => nothing, "KUBERNETES_SERVICE_HOST" => nothing)
    withenv(clean...) do
        @test Sentry.cloud_resource_context() === nothing
        for (vars, platform) in (("ECS_CONTAINER_METADATA_URI_V4" => "x",) => "aws_ecs",
                                 ("K_SERVICE" => "svc",) => "gcp_cloud_run",
                                 ("FUNCTION_TARGET" => "f", "GOOGLE_CLOUD_PROJECT" => "p") => "gcp_cloud_functions",
                                 ("WEBSITE_SITE_NAME" => "site",) => "azure_app_service",
                                 ("KUBERNETES_SERVICE_HOST" => "k",) => "kubernetes")
            withenv(vars...) do
                @test Sentry.cloud_resource_context()["cloud.platform"] == platform
            end
        end
    end
end

@testitem "logging integration" setup=[SentryTest] begin
    using Logging
    SentryTest.init!(; enable_logs=true)
    @test global_logger() isa Sentry.SentryLogger

    @info "an info message" key = "value"
    @debug "below every threshold"
    @warn "a warning"
    capture_message("after logging")
    crumbs = SentryTest.last_event()["breadcrumbs"]["values"]
    @test [c["message"] for c in crumbs] == ["an info message", "a warning"]
    @test crumbs[1]["type"] == "log"
    @test crumbs[1]["category"] == string(@__MODULE__)
    @test crumbs[1]["data"]["key"] == "value"
    @test crumbs[2]["level"] == "warning"

    @error "an error message" code = 3
    e = SentryTest.last_event()
    @test e["logentry"]["message"] == "an error message"
    @test e["level"] == "error"
    @test e["extra"]["code"] == 3
    @test e["logger"] == string(@__MODULE__)

    try
        error("logged exception")
    catch exc
        @error "failed" exception = (exc, catch_backtrace())
    end
    e = SentryTest.last_event()
    @test only(e["exception"]["values"])["value"] == "logged exception"
    @test only(e["exception"]["values"])["mechanism"]["type"] == "logging"

    try
        error("bare exception")
    catch exc
        @error "failed again" exception = exc
    end
    @test only(SentryTest.last_event()["exception"]["values"])["value"] == "bare exception"
    @error "not an exception" exception = "a string"
    @test only(SentryTest.last_event()["exception"]["values"])["value"] == "\"a string\""

    Sentry.flush()
    logs = [l for batch in SentryTest.items("log") for l in batch["items"]]
    bodies = [l["body"] for l in logs]
    @test "an info message" in bodies
    @test "an error message" in bodies
    log = logs[findfirst(==("an info message"), bodies)]
    @test log["attributes"]["sentry.origin"]["value"] == "auto.log.julia"
    @test log["attributes"]["key"]["value"] == "value"
    @test log["level"] == "info"

    # Ignored modules are left alone.
    Sentry.ignore_logger(@__MODULE__)
    n = length(SentryTest.events())
    @error "ignored"
    @test length(SentryTest.events()) == n
    delete!(Sentry._IGNORED_LOGGERS, string(@__MODULE__))

    # Levels are configurable, and the parent logger still gets everything it wants.
    SentryTest.init!(; integrations=[Sentry.LoggingIntegration(; level=nothing, event_level=Logging.Warn)])
    @warn "now an event"
    @test SentryTest.last_event()["level"] == "warning"
    @test Logging.min_enabled_level(global_logger()) <= Logging.Warn

    Sentry.close()
    @test !(global_logger() isa Sentry.SentryLogger)
    # Without a client, the logger just passes messages on.
    l = Sentry.SentryLogger(ConsoleLogger(devnull))
    @test Logging.min_enabled_level(l) == Logging.Info
    @test Logging.shouldlog(l, Logging.Info, Main, :g, :id)
    @test Logging.catch_exceptions(l) == Logging.catch_exceptions(ConsoleLogger(devnull))
    with_logger(l) do
        @info "no client"
    end
end
