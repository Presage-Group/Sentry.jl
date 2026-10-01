@testitem "http transport" setup=[FakeSentry] begin
    FakeSentry.init!()
    id = capture_message("over http")
    env, headers = FakeSentry.next_envelope()
    @test env.headers["event_id"] == id
    @test Sentry.payload_json(env.items[1])["message"]["formatted"] == "over http"
    @test FakeSentry.header(headers, "Content-Type") == "application/x-sentry-envelope"
    @test FakeSentry.header(headers, "Content-Encoding") == "gzip"
    auth = FakeSentry.header(headers, "X-Sentry-Auth")
    @test occursin("sentry_key=abcdef1234567890", auth)
    @test occursin("sentry_version=7", auth)
    @test occursin("sentry_client=sentry.julia/", auth)
    @test startswith(FakeSentry.header(headers, "User-Agent"), "sentry.julia/")
    @test Sentry.flush()
    Sentry.close()
end

@testitem "a failed send does not stop the transport" setup=[FakeSentry] begin
    client = FakeSentry.init!()
    FakeSentry.response_status[] = 500
    capture_message("rejected")
    env, _ = FakeSentry.next_envelope()
    @test Sentry.payload_json(env.items[1])["message"]["formatted"] == "rejected"
    @test Sentry.flush_worker(client.transport.worker, 10)
    # The failure is recorded for the client report.
    @test client.transport.discarded[("error", "network_error")] == 1

    # Flushing sends the client report, after whatever was queued before it.
    FakeSentry.response_status[] = 200
    @test Sentry.flush()
    env, _ = FakeSentry.next_envelope()
    report = Sentry.payload_json(only(env.items))
    @test any(d -> d["reason"] == "network_error" && d["category"] == "error", report["discarded_events"])

    capture_message("after the failure")
    env, _ = FakeSentry.next_envelope()
    @test Sentry.payload_json(env.items[1])["message"]["formatted"] == "after the failure"
    @test !istaskdone(client.transport.worker.task)
    Sentry.close()
end

@testitem "unreachable server" begin
    # Nothing listens on this port, so every send fails, quietly.
    client = Sentry.init("http://key@127.0.0.1:1/5"; auto_session_tracking=false, shutdown_timeout=30)
    capture_message("nowhere to go")
    @test Sentry.flush_worker(client.transport.worker, 30)
    @test client.transport.discarded[("error", "network_error")] == 1
    # The client report can not be sent either, and is itself counted as lost.
    @test Sentry.flush()
    @test client.transport.discarded[("internal", "network_error")] == 1
    Sentry.close()
end

@testitem "rate limits" setup=[FakeSentry] begin
    client = FakeSentry.init!()
    t = client.transport

    FakeSentry.response_headers[] = ["X-Sentry-Rate-Limits" => "60:error;transaction:organization, 30::key"]
    capture_message("limits")
    FakeSentry.next_envelope()
    Sentry.flush()
    @test Sentry.is_disabled(t, "error")
    @test Sentry.is_disabled(t, "span")  # through the transaction limit
    @test Sentry.is_disabled(t, "session")  # through the global limit
    @test Sentry.is_rate_limited(t)
    @test !Sentry.is_healthy(t)

    # Rate limited items are dropped before sending, and recorded.
    capture_message("dropped")
    Sentry.flush_worker(t.worker, 10)
    @test !isready(FakeSentry.received)
    @test t.discarded[("error", "ratelimit_backoff")] >= 1

    # A 429 without the header limits everything for Retry-After seconds.
    empty!(t.disabled_until)
    FakeSentry.response_headers[] = ["Retry-After" => "120"]
    FakeSentry.response_status[] = 429
    capture_message("too many")
    FakeSentry.next_envelope()
    Sentry.flush()
    @test t.disabled_until[nothing] > time() + 100

    empty!(t.disabled_until)
    FakeSentry.response_headers[] = Pair{String,String}[]
    capture_message("default retry")
    FakeSentry.next_envelope()
    Sentry.flush()
    @test 50 < t.disabled_until[nothing] - time() <= 60

    # 413 means the envelope was too big.
    empty!(t.disabled_until)
    FakeSentry.response_status[] = 413
    capture_message("too big")
    FakeSentry.next_envelope()
    Sentry.flush_worker(t.worker, 10)
    @test t.discarded[("error", "send_error")] >= 1
    Sentry.close()
end

@testitem "rate limit parsing" begin
    @test Sentry.parse_rate_limits("60:error;transaction:org, 30::key, bad, x:y") ==
          [("error", 60.0), ("transaction", 60.0), (nothing, 30.0)]
    @test Sentry.parse_retry_after(nothing) === nothing
    @test Sentry.parse_retry_after(" 12 ") == 12.0
    @test Sentry.parse_retry_after("not a date") === nothing
    future = Sentry.Dates.format(Sentry.Dates.now(Sentry.Dates.UTC) + Sentry.Dates.Second(100), Sentry.Dates.RFC1123Format) * " GMT"
    @test 90 < Sentry.parse_retry_after(future) <= 101
end

@testitem "client reports" setup=[FakeSentry] begin
    client = FakeSentry.init!(; send_client_reports=true)
    t = client.transport
    Sentry.record_lost_event(t, "sample_rate", "error"; quantity=2)
    Sentry.record_lost_event(t, "sample_rate", "error")
    Sentry.record_lost_event(t, "x", "error"; quantity=0)
    Sentry.record_lost_event(t, "queue_overflow", Sentry.json_item("transaction", Dict("spans" => [1, 2])))
    Sentry.record_lost_event(t, "queue_overflow", Sentry.Item("transaction", Vector{UInt8}("not json")))
    Sentry.record_lost_event(t, "queue_overflow", Sentry.Item("log", UInt8[1, 2, 3]; item_count=4))
    Sentry.record_lost_event(t, "queue_overflow", Sentry.Item("attachment", UInt8[1, 2, 3]))
    Sentry.record_lost_event(t, "queue_overflow", Sentry.Item("trace_metric", UInt8[]; item_count=7))
    @test t.discarded[("error", "sample_rate")] == 3
    @test !haskey(t.discarded, ("error", "x"))
    @test t.discarded[("span", "queue_overflow")] == 4
    @test t.discarded[("transaction", "queue_overflow")] == 2
    @test t.discarded[("log_byte", "queue_overflow")] == 3
    @test t.discarded[("log_item", "queue_overflow")] == 4
    @test t.discarded[("attachment", "queue_overflow")] == 3
    @test t.discarded[("trace_metric", "queue_overflow")] == 7

    # Not due yet unless forced.
    @test Sentry.fetch_client_report(t) === nothing
    Sentry.flush()
    env, _ = FakeSentry.next_envelope()
    report = Sentry.payload_json(only(env.items))
    @test Sentry.item_type(only(env.items)) == "client_report"
    @test any(d -> d == Dict("reason" => "sample_rate", "category" => "error", "quantity" => 3), report["discarded_events"])
    @test isempty(t.discarded)
    @test Sentry.fetch_client_report(t; force=true) === nothing
    Sentry.close()

    client = FakeSentry.init!(; send_client_reports=false)
    Sentry.record_lost_event(client.transport, "sample_rate", "error")
    @test isempty(client.transport.discarded)
    @test Sentry.fetch_client_report(client.transport; force=true) === nothing
    Sentry.close()
end

@testitem "queue overflow" setup=[FakeSentry] begin
    client = FakeSentry.init!(; transport_queue_size=1)
    FakeSentry.response_delay[] = 1.0
    for i in 1:5
        capture_message("burst $i")
    end
    @test client.transport.discarded[("error", "queue_overflow")] >= 1
    @test Sentry.flush(; timeout=30)
    FakeSentry.response_delay[] = 0.0
    Sentry.close()
end

@testitem "flushing on exit" setup=[FakeSentry] begin
    # Needs a real process exit to run the atexit handler, and deliberately
    # does not wait for the send itself. The response is delayed so that
    # just emptying the queue is not enough to get the event through.
    code = """
        using Sentry
        Sentry.init("$(FakeSentry.dsn)"; shutdown_timeout=60.0, auto_session_tracking=false)
        capture_message("sent while exiting")
        """

    FakeSentry.reset!()
    FakeSentry.response_delay[] = 3.0
    try
        elapsed = @elapsed run(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) --eval $code`)
        # Exiting has to block until the send itself came back
        @test elapsed > FakeSentry.response_delay[]
        env, _ = FakeSentry.next_envelope()
        @test Sentry.payload_json(env.items[1])["message"]["formatted"] == "sent while exiting"
    finally
        FakeSentry.response_delay[] = 0.0
    end
end

@testitem "giving up on a stuck sender" begin
    blocked = Base.Event()
    t = Sentry.BackgroundWorker(_ -> wait(blocked), 1)
    Sentry.submit!(t, 1)
    @test !Sentry.kill_worker(t, 0.2)
    notify(blocked)

    # The transport warns when it has to give up at shutdown.
    client = Sentry.init("http://key@127.0.0.1:1/5"; auto_session_tracking=false)
    tr = client.transport
    stuck = Base.Event()
    tr.worker = Sentry.BackgroundWorker(_ -> wait(stuck), 1)
    Sentry.submit!(tr.worker, 1)
    @test_logs (:warn, "Timed out sending queued events to sentry") Sentry.kill_transport(tr, 0.2)
    notify(stuck)
    client.closed = true
    Sentry.close()
end

@testitem "unhandled errors at exit" setup=[FakeSentry] begin
    # Run as a script, which is how programs usually run (Julia does not keep
    # the error around for `julia -e`).
    script = tempname() * ".jl"
    write(script, """
        using Sentry
        Sentry.init("$(FakeSentry.dsn)"; shutdown_timeout=30.0, release="crashy@1")
        error("uncaught at the top level")
        """)
    FakeSentry.reset!()
    p = run(pipeline(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $script`; stderr=devnull); wait=false)
    wait(p)
    @test p.exitcode == 1
    envs = Sentry.Envelope[]
    while true
        try
            push!(envs, FakeSentry.next_envelope(10)[1])
        catch
            break
        end
    end
    items = [i for e in envs for i in e.items]
    events = [Sentry.payload_json(i) for i in items if Sentry.item_type(i) == "event"]
    @test length(events) == 1
    exc = only(events[1]["exception"]["values"])
    @test exc["value"] == "uncaught at the top level"
    @test exc["mechanism"]["handled"] == false
    @test exc["mechanism"]["type"] == "excepthook"
    @test events[1]["level"] == "fatal"
    sessions = [Sentry.payload_json(i) for i in items if Sentry.item_type(i) == "session"]
    @test length(sessions) == 1
    @test sessions[1]["status"] == "crashed"
    @test sessions[1]["errors"] == 1
    @test sessions[1]["attrs"]["release"] == "crashy@1"
end

@testitem "fake dsn" begin
    Sentry.init("fake"; auto_session_tracking=false)
    io = IOBuffer()
    get_client().transport = Sentry.PrintTransport(io)
    @test_logs (:info, "Would have sent this body") capture_message("dry run"; attachments=[Attachment(bytes=UInt8[1, 2])])
    out = String(take!(io))
    @test occursin("dry run", out)
    @test occursin("<2 bytes>", out)
    @test Sentry.PrintTransport().io === stdout
    Sentry.close()
end

@testitem "spotlight" setup=[FakeSentry] begin
    url = "http://127.0.0.1:$(FakeSentry.port)/stream"
    @test Sentry.spotlight_url(true) == Sentry.DEFAULT_SPOTLIGHT_URL
    @test Sentry.spotlight_url(false) === nothing
    @test Sentry.spotlight_url("") === nothing
    @test Sentry.spotlight_url(1) === nothing

    # Without a DSN, spotlight gets everything.
    withenv("SENTRY_DSN" => nothing) do
        Sentry.close()
        FakeSentry.reset!()
        client = Sentry.init(; spotlight=url, auto_session_tracking=false, sample_rate=0.0)
        @test client.options.send_default_pii
        @test capture_message("to spotlight") isa String
        env, headers = FakeSentry.next_envelope()
        @test Sentry.payload_json(env.items[1])["message"]["formatted"] == "to spotlight"
        @test FakeSentry.header(headers, "Content-Encoding") === nothing
        start_transaction(name="spotlit") do t
            @test t.sampled === true
        end
        @test Sentry.flush()
        Sentry.close()
    end
end

@testitem "tls options" begin
    mktempdir() do dir
        ca = joinpath(dir, "ca.pem")
        write(ca, "not a certificate")
        # A bad configuration is reported, and the default client used instead.
        c = @test_logs (:warn, r"could not configure TLS") match_mode=:any Sentry.init("https://k@example.com/1"; ca_certs=ca, cert_file=ca, auto_session_tracking=false)
        @test c.transport.http_client === nothing
        Sentry.close()
    end
    c = @test_logs (:warn, r"proxy_headers") Sentry.init("https://k@example.com/1"; https_proxy="http://proxy:3128",
                                                          proxy_headers=Dict("X" => "1"), auto_session_tracking=false)
    @test c.transport.proxy == "http://proxy:3128"
    Sentry.close()
    c = Sentry.init("http://k@example.com/1"; http_proxy="http://proxy:3128", auto_session_tracking=false)
    @test c.transport.proxy == "http://proxy:3128"
    Sentry.close()
end
