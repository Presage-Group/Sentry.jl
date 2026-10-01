@testitem "sentry logs" setup=[SentryTest] begin
    # Logs are only sent when enabled.
    SentryTest.init!()
    Sentry.Logs.info("not sent")
    Sentry.flush()
    @test isempty(SentryTest.items("log"))

    SentryTest.init!(; enable_logs=true,
                     before_send_log=(log, hint) -> begin
                         log["body"] == "drop" && return nothing
                         log["body"] == "fail" && error("broken")
                         log["attributes"]["seen"] = true
                         log
                     end)
    set_user(Dict("id" => "u1"))
    Sentry.set_attribute("scope.attr", 1)
    Sentry.set_attributes(Dict("other" => "x"))
    Sentry.remove_attribute("other")
    start_transaction(name="logging") do t
        Sentry.Logs.warn("User {user} did {action}"; user="ada", action=:login, attributes=(; plan="pro"))
    end
    Sentry.Logs.trace("t")
    Sentry.Logs.debug("d")
    Sentry.Logs.error("e")
    Sentry.Logs.fatal("f")
    Sentry.Logs.warning("w")
    Sentry.Logs.info("drop")
    Sentry.Logs.info("fail")
    Sentry.Logs.info("{missing} placeholder"; other=1)
    Sentry.flush()
    logs = [l for b in SentryTest.items("log") for l in b["items"]]
    @test [l["level"] for l in logs] == ["warn", "trace", "debug", "error", "fatal", "warn", "info"]
    log = logs[1]
    @test log["body"] == "User ada did login"
    attrs = log["attributes"]
    @test attrs["sentry.message.template"]["value"] == "User {user} did {action}"
    @test attrs["sentry.message.parameter.user"]["value"] == "ada"
    @test attrs["plan"]["value"] == "pro"
    @test attrs["seen"]["value"] == true
    @test attrs["scope.attr"]["value"] == 1
    @test !haskey(attrs, "other")
    @test attrs["sentry.severity_number"]["value"] == 13
    @test attrs["sentry.release"]["value"] == "v1.2.3"
    @test attrs["sentry.sdk.name"]["value"] == "sentry.julia"
    # User attributes are only added with send_default_pii.
    @test !haskey(attrs, "user.id")
    @test haskey(log, "trace_id")
    @test haskey(log, "span_id")
    @test logs[end]["body"] == "{missing} placeholder"

    SentryTest.init!(; enable_logs=true, send_default_pii=true)
    set_user(Dict("id" => "u1", "email" => "a@b.c"))
    Sentry.Logs.info("with user")
    Sentry.flush()
    attrs = only(only(SentryTest.items("log"))["items"])["attributes"]
    @test attrs["user.id"]["value"] == "u1"
    @test attrs["user.email"]["value"] == "a@b.c"

    @test Sentry.format_template("{a} {b}", (; a=1)) == "1 {b}"
    @test Sentry.log_severity(Sentry.Logging.LogLevel(-2000)) == ("trace", 1)
    @test Sentry.log_severity(Sentry.Logging.LogLevel(3000)) == ("fatal", 21)
end

@testitem "metrics" setup=[SentryTest] begin
    SentryTest.init!(; before_send_metric=(m, hint) -> m["name"] == "dropped" ? nothing :
                                                        m["name"] == "failing" ? error("x") : m)
    start_transaction(name="measured") do t
        Sentry.Metrics.count("checkout", 2; attributes=(; region="eu"))
    end
    Sentry.Metrics.count("default increment")
    Sentry.Metrics.gauge("queue.depth", 42)
    Sentry.Metrics.distribution("latency", 0.25; unit="second")
    Sentry.Metrics.count("dropped")
    Sentry.Metrics.count("failing")
    Sentry.flush()
    metrics = [m for b in SentryTest.items("trace_metric") for m in b["items"]]
    @test [m["name"] for m in metrics] == ["checkout", "default increment", "queue.depth", "latency"]
    @test [m["type"] for m in metrics] == ["counter", "counter", "gauge", "distribution"]
    @test metrics[1]["value"] == 2.0
    @test metrics[1]["attributes"]["region"]["value"] == "eu"
    @test haskey(metrics[1], "span_id")
    @test metrics[2]["value"] == 1.0
    @test metrics[4]["unit"] == "second"
    env = only(SentryTest.envelopes_of("trace_metric"))
    @test only(env.items).headers["content_type"] == "application/vnd.sentry.items.trace-metric+json"

    SentryTest.init!(; enable_metrics=false)
    Sentry.Metrics.count("disabled")
    Sentry.flush()
    @test isempty(SentryTest.items("trace_metric"))
end

@testitem "sessions" setup=[SentryTest] begin
    # init starts an application session when a release is known.
    SentryTest.init!(; auto_session_tracking=true)
    @test get_isolation_scope().session isa Sentry.Session
    set_user(Dict("id" => "u1"))
    capture_message("not an error")
    capture_exception(ErrorException("counts"), backtrace())
    end_session()
    @test get_isolation_scope().session === nothing
    Sentry.flush()
    session = only(SentryTest.items("session"))
    @test session["status"] == "exited"
    @test session["errors"] == 1
    @test session["did"] == "u1"
    @test session["attrs"]["release"] == "v1.2.3"
    @test session["attrs"]["environment"] == "production"

    # An unhandled error crashes the session.
    start_session()
    capture_exception(ErrorException("crash"), backtrace(); handled=false)
    end_session()
    Sentry.flush()
    @test SentryTest.items("session")[end]["status"] == "crashed"

    # Without a release there is nothing to track.
    c = SentryTest.init!()
    c.options.release = nothing
    start_session()
    end_session()
    Sentry.flush()
    @test isempty(SentryTest.items("session"))

    # Sessions are closed when sentry is.
    SentryTest.init!(; auto_session_tracking=true)
    Sentry.close()
    @test length(SentryTest.items("session")) == 1
    @test start_session() === nothing
end

@testitem "crons" setup=[SentryTest] begin
    SentryTest.init!()
    id = capture_checkin(; monitor_slug="nightly", status="in_progress",
                         monitor_config=(; schedule=(; type="crontab", value="0 0 * * *"), checkin_margin=5))
    checkin = SentryTest.items("check_in")[end]
    @test checkin["check_in_id"] == id
    @test checkin["monitor_slug"] == "nightly"
    @test checkin["status"] == "in_progress"
    @test checkin["monitor_config"]["schedule"]["value"] == "0 0 * * *"
    @test checkin["release"] == "v1.2.3"
    # Check-ins only carry the trace context.
    @test collect(keys(checkin["contexts"])) == ["trace"]

    @test Sentry.monitor(() -> 42, "job") == 42
    checkins = SentryTest.items("check_in")
    @test [c["status"] for c in checkins[end-1:end]] == ["in_progress", "ok"]
    @test checkins[end-1]["check_in_id"] == checkins[end]["check_in_id"]
    @test checkins[end]["duration"] >= 0

    @test_throws ErrorException Sentry.@monitor "failing" error("job failed")
    @test SentryTest.items("check_in")[end]["status"] == "error"
    @test (Sentry.@monitor "configured" (; schedule=(; type="interval", value=1, unit="hour")) 1 + 1) == 2
    @test SentryTest.items("check_in")[end]["monitor_config"]["schedule"]["unit"] == "hour"
    @test_throws LoadError @eval Sentry.@monitor "x" a b c
end

@testitem "feature flags" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0)
    add_feature_flag("new-ui", true)
    add_feature_flag("beta", false)
    add_feature_flag("new-ui", false)  # re-evaluated flags move to the end
    capture_message("with flags")
    flags = SentryTest.last_event()["contexts"]["flags"]["values"]
    @test flags == [Dict("flag" => "beta", "result" => false), Dict("flag" => "new-ui", "result" => false)]

    start_transaction(name="flagged") do _
        for i in 1:12
            add_feature_flag("f$i", true)
        end
    end
    data = SentryTest.last_transaction()["contexts"]["trace"]
    txn = SentryTest.last_transaction()
    # The span keeps up to 10 flags.
    b = Sentry.FlagBuffer(2)
    Sentry.set_flag!(b, "a", true)
    Sentry.set_flag!(b, "b", true)
    Sentry.set_flag!(b, "c", true)
    @test [f["flag"] for f in Sentry.get_flags(b)] == ["b", "c"]

    # Flags are isolated with the scope.
    isolation_scope() do
        add_feature_flag("inner", true)
        capture_message("inner")
    end
    @test any(f -> f["flag"] == "inner", SentryTest.last_event()["contexts"]["flags"]["values"])
    capture_message("outer")
    @test !any(f -> f["flag"] == "inner", SentryTest.last_event()["contexts"]["flags"]["values"])

    span = Sentry.Transaction(; name="x")
    for i in 1:12
        Sentry.set_flag(span, "f$i", true)
    end
    @test length(span.flags) == 10
end

@testitem "transaction profiling" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0, profiles_sample_rate=1.0)
    function busy(seconds)
        t0 = time()
        x = 0.0
        while time() - t0 < seconds
            x += sum(sin, 1:1000)
        end
        x
    end
    start_transaction(name="profiled") do _
        busy(0.5)
    end
    txn_env = last(SentryTest.envelopes())
    types = [Sentry.item_type(i) for i in txn_env.items]
    @test types == ["transaction", "profile"]
    txn = Sentry.payload_json(txn_env.items[1])
    profile = Sentry.payload_json(txn_env.items[2])
    @test txn["contexts"]["profile"]["profile_id"] == profile["event_id"]
    @test profile["version"] == "1"
    @test profile["platform"] == "julia"
    @test profile["transactions"][1]["id"] == txn["event_id"]
    @test profile["transactions"][1]["trace_id"] == txn["contexts"]["trace"]["trace_id"]
    p = profile["profile"]
    @test !isempty(p["samples"])
    @test !isempty(p["stacks"])
    @test !isempty(p["frames"])
    @test all(s -> 0 <= s["stack_id"] < length(p["stacks"]), p["samples"])
    @test all(st -> all(i -> 0 <= i < length(p["frames"]), st), p["stacks"])
    @test any(f -> f["function"] == "busy", p["frames"])

    # Only one transaction is profiled at a time.
    start_transaction(name="outer") do t
        start_transaction(name="inner", force_new=true) do t2
            @test t2.profile === nothing
        end
    end

    # Profiling can be switched off by the sampler.
    SentryTest.init!(; traces_sample_rate=1.0, profiles_sampler=ctx -> 0.0)
    start_transaction(name="unprofiled") do _ end
    @test [Sentry.item_type(i) for i in last(SentryTest.envelopes()).items] == ["transaction"]
    SentryTest.init!(; traces_sample_rate=1.0, profiles_sampler=ctx -> error("x"))
    start_transaction(name="broken sampler") do _ end
    @test [Sentry.item_type(i) for i in last(SentryTest.envelopes()).items] == ["transaction"]

    # Profile data is split into blocks at its double zero markers.
    @test isempty(Sentry.process_profile(UInt[], UInt64(0), UInt64(1), nothing)["samples"])
end

@testitem "continuous profiling" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0, profile_session_sample_rate=1.0)
    Sentry._SESSION_SAMPLED[] = nothing
    Sentry.start_profiler()
    @test Sentry.continuous_profiler_running()
    Sentry.start_profiler()  # already running
    start_transaction(name="during profiling") do _
        t0 = time()
        while time() - t0 < 0.3
            sum(sin, 1:1000)
        end
    end
    Sentry.stop_profiler()
    @test !Sentry.continuous_profiler_running()
    @test Sentry.stop_profiler() === nothing
    txn = SentryTest.last_transaction()
    chunks = SentryTest.items("profile_chunk")
    @test length(chunks) == 1
    chunk = only(chunks)
    @test chunk["version"] == "2"
    @test txn["contexts"]["profile"]["profiler_id"] == chunk["profiler_id"]
    @test haskey(chunk["profile"]["samples"][1], "timestamp")

    # With profile_lifecycle="trace" the profiler runs while transactions do.
    SentryTest.init!(; traces_sample_rate=1.0, profile_session_sample_rate=1.0, profile_lifecycle="trace")
    start_transaction(name="auto profiled") do t
        @test Sentry.continuous_profiler_running()
        t0 = time()
        while time() - t0 < 0.2
            sum(sin, 1:1000)
        end
    end
    @test !Sentry.continuous_profiler_running()
    @test length(SentryTest.items("profile_chunk")) == 1

    # A process outside of the session sample does not profile.
    SentryTest.init!(; traces_sample_rate=1.0, profile_session_sample_rate=0.0)
    Sentry._SESSION_SAMPLED[] = nothing
    Sentry.start_profiler()
    @test !Sentry.continuous_profiler_running()
    Sentry._SESSION_SAMPLED[] = nothing
    Sentry.close()
    @test Sentry.start_profiler() === nothing
end

@testitem "http client" setup=[SentryTest] begin
    HTTP = Sentry.HTTP
    received = Channel{Any}(10)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
        put!(received, Dict(string(k) => string(v) for (k, v) in req.headers))
        req.target == "/missing" && return HTTP.Response(404, "nope")
        HTTP.Response(200, "hello")
    end
    port = HTTP.port(server)
    try
        SentryTest.init!(; traces_sample_rate=1.0)
        start_transaction(name="calls out") do t
            r = Sentry.http_request("GET", "http://127.0.0.1:$port/hello?x=1#frag", ["Accept" => "*/*"])
            @test String(r.body) == "hello"
            # HTTP.jl canonicalizes the header names.
            headers = Dict(lowercase(k) => v for (k, v) in take!(received))
            @test haskey(headers, "sentry-trace")
            @test startswith(headers["sentry-trace"], t.trace_id)
            @test occursin("sentry-trace_id=$(t.trace_id)", headers["baggage"])

            @test_throws HTTP.StatusError Sentry.http_request(:get, "http://127.0.0.1:$port/missing")
            take!(received)
            @test_throws Exception Sentry.http_request("GET", "http://127.0.0.1:1/unreachable"; retry=false, connect_timeout=2)
        end
        txn = SentryTest.last_transaction()
        spans = txn["spans"]
        @test length(spans) == 3
        @test spans[1]["op"] == "http.client"
        @test spans[1]["description"] == "GET http://127.0.0.1:$port/hello"
        @test spans[1]["data"]["http.query"] == "x=1"
        @test spans[1]["data"]["http.fragment"] == "frag"
        @test spans[1]["data"]["http.response.status_code"] == 200
        @test spans[2]["status"] == "not_found"
        @test spans[3]["status"] == "internal_error"

        capture_message("after requests")
        crumbs = SentryTest.last_event()["breadcrumbs"]["values"]
        http_crumbs = filter(c -> c["type"] == "http", crumbs)
        @test [c["level"] for c in http_crumbs] == ["info", "warning", "error"]
        @test http_crumbs[1]["data"]["status_code"] == 200

        # Without the integration, it is a plain request.
        SentryTest.init!(; disabled_integrations=[Sentry.HTTPIntegration])
        Sentry.http_request("GET", "http://127.0.0.1:$port/plain")
        @test !any(k -> lowercase(k) == "sentry-trace", keys(take!(received)))
        @test Sentry.parse_url_parts("::not a url::").url == "::not a url::"
    finally
        close(server)
    end
end

@testitem "http middleware" setup=[SentryTest] begin
    HTTP = Sentry.HTTP
    handler = req -> begin
        req.target == "/boom" && error("handler failed")
        req.target == "/teapot" && return HTTP.Response(418, "teapot")
        capture_message("inside the handler")
        HTTP.Response(200, "ok")
    end
    SentryTest.init!(; traces_sample_rate=1.0, auto_session_tracking=true)
    server = HTTP.serve!(Sentry.http_middleware(handler), "127.0.0.1", 0; listenany=true)
    port = HTTP.port(server)
    try
        trace_id = "9"^32
        r = HTTP.post("http://127.0.0.1:$port/hello?q=1", ["sentry-trace" => "$trace_id-$("1"^16)-1",
                                                          "Authorization" => "secret", "Content-Type" => "application/json"],
                      "{\"a\": 1}")
        @test r.status == 200
        @test_throws HTTP.StatusError HTTP.get("http://127.0.0.1:$port/boom"; retry=false)
        @test HTTP.get("http://127.0.0.1:$port/teapot"; status_exception=false).status == 418

        event = SentryTest.events()[1]
        @test event["request"]["method"] == "POST"
        @test event["request"]["url"] == "http://127.0.0.1:$port/hello"
        @test event["request"]["query_string"] == "q=1"
        @test event["request"]["headers"]["Authorization"] == "[Filtered]"
        @test event["request"]["data"] == Dict("a" => 1)
        @test event["contexts"]["trace"]["trace_id"] == trace_id

        txns = SentryTest.transactions()
        @test length(txns) == 3
        @test txns[1]["transaction"] == "POST /hello"
        @test txns[1]["contexts"]["trace"]["op"] == "http.server"
        @test txns[1]["contexts"]["trace"]["trace_id"] == trace_id
        @test txns[1]["contexts"]["trace"]["parent_span_id"] == "1"^16
        @test txns[2]["contexts"]["trace"]["status"] == "internal_error"
        @test txns[3]["contexts"]["trace"]["status"] == "invalid_argument"

        crash = SentryTest.events()[2]
        exc = only(crash["exception"]["values"])
        @test exc["value"] == "handler failed"
        @test exc["mechanism"] == Dict("type" => "http", "handled" => false)

        # Request sessions are aggregated.
        Sentry.flush()
        agg = only(SentryTest.items("sessions"))
        counts = only(agg["aggregates"])
        @test counts["exited"] == 2
        @test counts["crashed"] == 1

        # With send_default_pii, personal data such as the client address is kept;
        # credentials are still scrubbed.
        SentryTest.init!(; send_default_pii=true, max_request_body_size="never")
        HTTP.get("http://127.0.0.1:$port/hello"; headers=["Authorization" => "secret", "X-Forwarded-For" => "1.2.3.4, 5.6.7.8",
                                                         "Cookie" => "a=b"])
        event = SentryTest.last_event()
        @test event["request"]["headers"]["Authorization"] == "[Filtered]"
        @test event["request"]["headers"]["X-Forwarded-For"] == "1.2.3.4, 5.6.7.8"
        @test event["request"]["env"]["REMOTE_ADDR"] == "1.2.3.4"
        @test event["request"]["cookies"] == "a=b"
        @test !haskey(event["request"], "data")
    finally
        close(server)
    end

    # Without a client the handler runs as is.
    Sentry.close()
    req = HTTP.Request("GET", "/x")
    @test Sentry.http_middleware(r -> :plain)(req) === :plain
    @test Sentry.server_transaction_name(HTTP.Request("GET", "/p?q"), :path) == ("/p", "url")
    info = Sentry.request_info(HTTP.Request("POST", "/p", ["Content-Type" => "text/plain"], "text body"),
                               Sentry.make_options())
    @test info["url"] == "/p"
    @test info["data"] == "text body" || !haskey(info, "data")
end

@testitem "tasks" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0)
    set_tag("owner", "main")
    t = Sentry.errormonitor(Threads.@spawn error("task failed"))
    @test_throws TaskFailedException wait(t)
    @test timedwait(() -> !isempty(SentryTest.events()), 10) === :ok
    event = SentryTest.last_event()
    values = event["exception"]["values"]
    @test values[end]["value"] == "task failed"
    @test values[end]["mechanism"]["handled"] == false
    @test event["tags"]["owner"] == "main"
    @test Sentry.errormonitor(Threads.@spawn 1) isa Task

    # traced continues the trace wherever the function runs.
    start_transaction(name="spawner") do txn
        f = Sentry.traced(x -> (get_current_span().trace_id, x * 2); name="work")
        # In a task that inherits the scope, a child span is made.
        tid, v = fetch(Threads.@spawn f(2))
        @test tid == txn.trace_id
        @test v == 4
        # Elsewhere (a fresh isolation scope, as on another worker) the trace is continued.
        g = Sentry.traced(() -> get_current_span())
        span = Sentry.use_scope(Sentry.Scope()) do
            g()
        end
        @test span.trace_id == txn.trace_id
        @test span.is_transaction
    end
    Sentry.close()
    @test Sentry.traced(() -> :no_client)() === :no_client
end
