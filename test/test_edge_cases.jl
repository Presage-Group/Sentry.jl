@testitem "database system names" begin
    using DBInterface
    ext = Base.get_extension(Sentry, :SentryDBInterfaceExt)
    for (mod, system) in (:LibPQ => "postgresql", :MySQL => "mysql", :ODBC => "odbc", :DuckDB => "duckdb",
                          :SomethingElse => "somethingelse", :SQLite => "sqlite")
        m = Module(mod)
        Core.eval(m, :(struct Conn end))
        @test ext.guess_system(Core.eval(m, :(Conn()))) == system
    end
end

@testitem "re-initialising" setup=[SentryTest] begin
    first_client = SentryTest.init!(; auto_session_tracking=true)
    # Initialising again directly closes the previous client and its session.
    second = Sentry.init(SentryTest.DSN; transport=SentryTest.transport, release="v1.2.3",
                         auto_session_tracking=false)
    @test first_client.closed
    @test get_client() === second
    @test length(SentryTest.items("session")) == 1
    Sentry.close()
end

@testitem "internal errors never reach the caller" setup=[SentryTest] begin
    SentryTest.init!(; transport=env -> error("transport is broken"))
    @test capture_message("lost") === nothing

    SentryTest.init!(; traces_sample_rate=1.0, trace_lifecycle="stream",
                     before_send_span=(span, hint) -> error("broken callback"))
    start_transaction(name="kept anyway") do _ end
    Sentry.flush()
    @test only(only(SentryTest.items("span"))["items"])["name"] == "kept anyway"
end

@testitem "logging edge cases" setup=[SentryTest] begin
    using Logging
    SentryTest.init!(; enable_logs=true,
                     integrations=[Sentry.LoggingIntegration(; level=nothing, event_level=Logging.Error,
                                                             sentry_logs_level=Logging.Debug)])
    @test Logging.min_enabled_level(global_logger()) <= Logging.Debug

    # An exception outside of a catch block has no backtrace.
    @error "no backtrace" exception = ErrorException("detached")
    @test only(SentryTest.last_event()["exception"]["values"])["value"] == "detached"
    # A whole exception stack can be logged.
    try
        error("stacked")
    catch
        @error "stack" exception = current_exceptions()
    end
    @test only(SentryTest.last_event()["exception"]["values"])["value"] == "stacked"
    Sentry.close()
end

@testitem "profiler chunks" setup=[SentryTest] begin
    SentryTest.init!(; profile_session_sample_rate=1.0)
    Sentry._SESSION_SAMPLED[] = nothing
    Sentry.start_profiler()
    p = Sentry._CONTINUOUS[]
    t0 = time()
    while time() - t0 < 0.2
        sum(sin, 1:1000)
    end
    # A chunk is sent while the profiler keeps running.
    Sentry._send_chunk!(p)
    @test Sentry.continuous_profiler_running()
    @test length(SentryTest.items("profile_chunk")) == 1
    Sentry.stop_profiler()
    Sentry._SESSION_SAMPLED[] = nothing
end

@testitem "scope merging edge cases" setup=[SentryTest] begin
    SentryTest.init!()
    Sentry.get_global_scope().flags = Sentry.FlagBuffer()
    Sentry.set_flag!(Sentry.get_global_scope().flags, "global-flag", true)
    add_feature_flag("isolation-flag", false)
    capture_message("both flags")
    names = [f["flag"] for f in SentryTest.last_event()["contexts"]["flags"]["values"]]
    @test names == ["global-flag", "isolation-flag"]

    # Breadcrumbs that can not be sorted are kept in the order they came.
    add_breadcrumb(message="b", timestamp="not a time")
    add_breadcrumb(message="a")
    capture_message("unsorted")
    @test [c["message"] for c in SentryTest.last_event()["breadcrumbs"]["values"]] == ["b", "a"]
end

@testitem "session envelopes are split with aggregates" begin
    sent = Sentry.Envelope[]
    f = Sentry.SessionFlusher(e -> push!(sent, e); flush_interval=3600.0)
    for _ in 1:Sentry.MAX_ENVELOPE_ITEMS
        Sentry.add_session!(f, Sentry.Session())
    end
    Sentry.add_session!(f, Sentry.Session(; session_mode="request"))
    envs = Sentry.flush!(f)
    @test length(envs) == 2
    @test Sentry.item_type(only(envs[2].items)) == "sessions"
    Sentry.kill!(f)
end

@testitem "tracing edge cases" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0, trace_lifecycle="stream")
    start_transaction(name="with data") do t
        Sentry.set_data(t, "rows", 3)
    end
    Sentry.flush()
    @test only(only(SentryTest.items("span"))["items"])["attributes"]["rows"]["value"] == 3

    # A continued trace with only third party baggage gets sentry's own.
    SentryTest.init!(; traces_sample_rate=1.0)
    trace_id = "c"^32
    continue_trace(Dict("sentry-trace" => "$trace_id-$("d"^16)-1", "baggage" => "vendor=1"); name="mutable") do t
        @test t.baggage.mutable
        b = Sentry.get_baggage(t)
        @test !b.mutable
        @test b.sentry_items["trace_id"] == trace_id
    end

    # ignore_spans rules can match on attributes alone.
    SentryTest.init!(; traces_sample_rate=1.0, ignore_spans=[(; attributes=Dict("skip" => true))])
    start_transaction(name="filtered") do _
        start_span(name="skipped", attributes=Dict("skip" => true)) do _ end
        start_span(name="kept") do _ end
    end
    @test [s["description"] for s in SentryTest.last_transaction()["spans"]] == ["kept"]
end

@testitem "transport through a proxy and with tls options" setup=[FakeSentry] begin
    proxy = "http://127.0.0.1:$(FakeSentry.port)"
    # The DSN's host is never contacted directly, only through the proxy.
    client = Sentry.init("http://proxied@sentry.invalid/7"; http_proxy=proxy, auto_session_tracking=false)
    FakeSentry.reset!()
    capture_message("through the proxy")
    env, headers = FakeSentry.next_envelope()
    @test Sentry.payload_json(env.items[1])["message"]["formatted"] == "through the proxy"
    @test occursin("sentry_key=proxied", FakeSentry.header(headers, "X-Sentry-Auth"))
    Sentry.close()

    # A valid CA bundle gives the transport a client of its own.
    bundle = joinpath(Sys.BINDIR, "..", "share", "julia", "cert.pem")
    if isfile(bundle)
        client = Sentry.init(FakeSentry.dsn; ca_certs=bundle, auto_session_tracking=false)
        @test client.transport.http_client !== nothing
        FakeSentry.reset!()
        capture_message("with a tls client")
        env, _ = FakeSentry.next_envelope()
        @test Sentry.payload_json(env.items[1])["message"]["formatted"] == "with a tls client"
        Sentry.close()
    end
end

@testitem "functions_to_trace" setup=[SentryTest] begin
    @test_logs (:warn, r"functions_to_trace is not supported") match_mode=:any SentryTest.init!(; functions_to_trace=[sin])
    Sentry.close()
end
