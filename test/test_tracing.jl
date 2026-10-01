@testitem "transactions" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0)
    result = start_transaction(name="job", op="task", tags=(; kind="batch")) do t
        @test get_current_span() === t
        @test t.sampled === true
        Sentry.set_tag(t, "stage", "one")
        Sentry.set_data(t, "rows", 10)
        start_span(op="db", name="query") do s
            @test get_current_span() === s
            @test s.parent_span_id == t.span_id
            @test s.trace_id == t.trace_id
            start_span(op="db.fetch", description="rows") do inner
                @test inner.parent_span_id == s.span_id
            end
        end
        @test get_current_span() === t
        set_measurement("rows", 10, "none")
        :done
    end
    @test result == :done
    @test get_current_span() === nothing

    env = last(SentryTest.envelopes())
    txn = Sentry.payload_json(only(env.items))
    @test txn["type"] == "transaction"
    @test txn["transaction"] == "job"
    @test txn["transaction_info"]["source"] == "custom"
    @test txn["release"] == "v1.2.3"
    @test txn["tags"]["kind"] == "batch"
    @test txn["tags"]["stage"] == "one"
    @test txn["measurements"]["rows"] == Dict("value" => 10, "unit" => "none")
    trace = txn["contexts"]["trace"]
    @test trace["op"] == "task"
    @test trace["data"]["rows"] == 10
    @test !haskey(trace, "dynamic_sampling_context")
    @test txn["start_timestamp"] < txn["timestamp"]
    spans = txn["spans"]
    @test length(spans) == 2
    query = spans[findfirst(s -> s["op"] == "db", spans)]
    @test query["parent_span_id"] == trace["span_id"]
    @test query["description"] == "query"
    @test query["trace_id"] == trace["trace_id"]

    # The envelope carries the dynamic sampling context.
    dsc = env.headers["trace"]
    @test dsc["trace_id"] == trace["trace_id"]
    @test dsc["transaction"] == "job"
    @test dsc["sampled"] == "true"
    @test dsc["sample_rate"] == "1.0"
    @test dsc["release"] == "v1.2.3"
    @test haskey(dsc, "sample_rand")
end

@testitem "errors in transactions" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0)
    @test_throws ErrorException start_transaction(name="failing") do t
        start_span(op="child") do s
            try
                error("inside")
            catch exc
                capture_exception(exc)
            end
            error("escapes")
        end
    end
    event = SentryTest.last_event()
    txn = SentryTest.last_transaction()
    # The error is linked to the span it happened in.
    @test event["contexts"]["trace"]["trace_id"] == txn["contexts"]["trace"]["trace_id"]
    @test event["contexts"]["trace"]["span_id"] == txn["spans"][1]["span_id"]
    @test txn["spans"][1]["status"] == "internal_error"
    @test txn["contexts"]["trace"]["status"] == "internal_error"
    @test SentryTest.envelopes()[1].headers["trace"]["transaction"] == "failing"
end

@testitem "transactions without a function" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0)
    t = start_transaction(name="manual", op="work")
    @test get_current_span() === t
    # A nameless transaction inside a span is a child span, as in earlier versions.
    child = start_transaction(op="child")
    @test child.parent_span_id == t.span_id
    @test !child.is_transaction
    s = start_span(op="grandchild")
    @test get_current_span() === s
    finish_span(s)
    @test get_current_span() === child
    finish_transaction(child)
    @test get_current_span() === t
    finish_transaction(t, nothing)
    @test get_current_span() === nothing
    @test finish_transaction(nothing) === nothing
    @test finish_span(nothing) === nothing
    txn = SentryTest.last_transaction()
    @test txn["transaction"] == "manual"
    @test length(txn["spans"]) == 2

    # Finishing twice does nothing.
    n = length(SentryTest.transactions())
    @test Sentry.finish(t) === nothing
    @test length(SentryTest.transactions()) == n

    # A transaction can be handed to a task.
    t2 = start_transaction(name="handed over")
    fetch(Threads.@spawn begin
        set_task_transaction(t2)
        start_span(op="in task") do _ end
    end)
    set_task_transaction(nothing)
    finish_transaction(t2)
    @test length(SentryTest.last_transaction()["spans"]) == 1
end

@testitem "spans in tasks" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0)
    start_transaction(name="parallel") do t
        tasks = [Threads.@spawn start_span(op="worker", name="w$i") do _
                     sleep(0.01)
                 end for i in 1:4]
        foreach(wait, tasks)
    end
    spans = SentryTest.last_transaction()["spans"]
    @test length(spans) == 4
    @test all(s -> s["op"] == "worker", spans)
end

@testitem "sampling decisions" setup=[SentryTest] begin
    # No tracing configured: nothing is sampled.
    SentryTest.init!()
    t = start_transaction(name="untraced")
    @test t.sampled === false
    finish_transaction(t)
    @test isempty(SentryTest.transactions())

    SentryTest.init!(; traces_sample_rate=0.0)
    start_transaction(name="rate zero") do t
        @test t.sampled === false
        start_span(op="child") do s
            @test s.sampled === false
        end
    end
    @test isempty(SentryTest.transactions())

    # The sampler sees the sampling context, including custom data.
    seen = Ref{Any}(nothing)
    SentryTest.init!(; traces_sampler=ctx -> (seen[] = ctx; ctx["transaction_context"]["name"] == "keep"))
    start_transaction(name="keep", custom_sampling_context=Dict("user" => "u")) do t
        @test t.sampled === true
        @test t.sample_rate == 1.0
    end
    @test seen[]["user"] == "u"
    @test seen[]["transaction_context"]["name"] == "keep"
    start_transaction(name="drop") do t
        @test t.sampled === false
    end

    # An explicit decision wins.
    start_transaction(name="forced", sampled=true) do t
        @test t.sampled === true
    end

    # Invalid and failing samplers unsample.
    SentryTest.init!(; traces_sampler=ctx -> 2.0)
    start_transaction(name="invalid") do t
        @test t.sampled === false
    end
    SentryTest.init!(; traces_sampler=ctx -> error("broken"))
    start_transaction(name="broken") do t
        @test t.sampled === false
    end

    # Samplers from earlier versions still work.
    SentryTest.init!(; traces_sampler=() -> true)
    start_transaction(name="zero args") do t
        @test t.sampled === true
    end
    SentryTest.init!(; traces_sampler=Sentry.RatioSampler(1.0))
    start_transaction(name="ratio") do t
        @test t.sampled === true
    end
    SentryTest.init!(; traces_sampler=Sentry.NoSamples())
    start_transaction(name="none") do t
        @test t.sampled === false
    end
    @test_throws AssertionError Sentry.RatioSampler(1.5)
    @test Sentry.RatioSampler(ratio=0.5).ratio == 0.5

    # trace_id=nothing means "do not trace", as in earlier versions.
    SentryTest.init!(; traces_sample_rate=1.0)
    start_transaction(name="inhibited", trace_id=nothing) do t
        @test t.sampled === false
    end
    start_transaction(name="given trace", trace_id="0"^32) do t
        @test t.trace_id == "0"^32
    end
end

@testitem "parent sampling" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=0.0)
    trace_id = "771a43a4192642f0b136d5159a501700"
    headers = Dict("sentry-trace" => "$trace_id-1234567890abcdef-1",
                   "baggage" => "other-vendor=x,sentry-trace_id=$trace_id,sentry-sample_rate=1.0,sentry-sample_rand=0.25,sentry-release=upstream")
    continue_trace(headers; name="continued", op="http.server") do t
        # The parent's decision is followed, even though our rate is 0.
        @test t.sampled === true
        @test t.trace_id == trace_id
        @test t.parent_span_id == "1234567890abcdef"
        @test t.sample_rand == 0.25
        @test get_traceparent() == "$trace_id-$(t.span_id)-1"
        baggage = get_baggage()
        # Incoming sentry baggage is frozen, and third party items are not passed on.
        @test occursin("sentry-release=upstream", baggage)
        @test !occursin("other-vendor", baggage)
    end
    txn = SentryTest.last_transaction()
    @test txn["contexts"]["trace"]["parent_span_id"] == "1234567890abcdef"
    @test SentryTest.envelopes()[end].headers["trace"]["release"] == "upstream"

    continue_trace(Dict("sentry-trace" => "$trace_id-1234567890abcdef-0"); name="unsampled parent") do t
        @test t.sampled === false
    end

    # Without a sentry-trace header a new trace starts.
    continue_trace(Dict("baggage" => "sentry-trace_id=abc"); name="fresh") do t
        @test t.trace_id != "abc"
        @test t.parent_span_id === nothing
    end
end

@testitem "continue_trace without a function" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0)
    trace_id = "a"^32
    isolation_scope() do
        txn = continue_trace(["sentry-trace" => "$trace_id-$("b"^16)"]; name="later", source="route")
        @test txn.trace_id == trace_id
        @test txn.parent_sampled === nothing
        @test txn.source == "route"
        # Errors are linked to the continued trace even before a transaction starts.
        capture_message("in continued trace")
        @test SentryTest.last_event()["contexts"]["trace"]["trace_id"] == trace_id
        start_transaction(; transaction=txn) do t
            @test t === txn
        end
    end
    @test SentryTest.last_transaction()["transaction_info"]["source"] == "route"

    # A W3C traceparent works too.
    t = continue_trace(Dict("traceparent" => "00-$trace_id-$("c"^16)-01"))
    @test t.trace_id == trace_id
    @test t.parent_sampled === true
    # And CGI style environments.
    t = continue_trace(Dict("HTTP_SENTRY_TRACE" => "$trace_id-$("d"^16)-0"))
    @test t.parent_span_id == "d"^16
    @test t.parent_sampled === false
end

@testitem "strict trace continuation" setup=[SentryTest] begin
    trace_id = "e"^32
    other_org = Dict("sentry-trace" => "$trace_id-$("f"^16)-1", "baggage" => "sentry-org_id=999")
    SentryTest.init!(; traces_sample_rate=1.0)
    # The DSN is for org 1, so a trace from org 999 is not continued.
    @test continue_trace(other_org).trace_id != trace_id

    no_org = Dict("sentry-trace" => "$trace_id-$("f"^16)-1")
    @test continue_trace(no_org).trace_id == trace_id
    SentryTest.init!(; traces_sample_rate=1.0, strict_trace_continuation=true)
    @test continue_trace(no_org).trace_id != trace_id
    SentryTest.init!(; traces_sample_rate=1.0, org_id="999")
    @test continue_trace(other_org).trace_id == trace_id
end

@testitem "trace headers" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0, trace_propagation_targets=["api.example.com", r"^https://internal\."])
    # Outside a transaction, headers come from the propagation context.
    tp = get_traceparent()
    @test occursin(r"^[0-9a-f]{32}-[0-9a-f]{16}$", tp)
    @test occursin("sentry-trace_id=", get_baggage())
    headers = Dict(Sentry.trace_propagation_headers())
    @test headers["sentry-trace"] == tp

    start_transaction(name="outgoing") do t
        h = Pair{String,String}["baggage" => "vendor=1,sentry-old=x", "sentry-trace" => "stale"]
        Sentry.add_trace_headers(h, "https://api.example.com/users")
        d = Dict(h)
        @test d["sentry-trace"] == Sentry.to_traceparent(t)
        @test startswith(d["baggage"], "vendor=1,")
        @test !occursin("sentry-old", d["baggage"])
        @test occursin("sentry-transaction=outgoing", d["baggage"])

        d2 = Dict("Accept" => "*/*")
        Sentry.add_trace_headers(d2, "https://internal.example.org/")
        @test haskey(d2, "sentry-trace")

        untouched = Pair{String,String}[]
        Sentry.add_trace_headers(untouched, "https://elsewhere.example.net/")
        @test isempty(untouched)
        # Requests to sentry itself are never traced.
        @test !Sentry.should_propagate_trace("https://o1.ingest.sentry.io/api/42/envelope/")

        meta = Sentry.trace_propagation_meta()
        @test occursin("<meta name=\"sentry-trace\"", meta)
        @test occursin("<meta name=\"baggage\"", meta)
    end

    SentryTest.init!(; traces_sample_rate=1.0, propagate_traces=false)
    @test isempty(Sentry.trace_propagation_headers())
    Sentry.close()
    @test isempty(Sentry.trace_propagation_headers())
    @test !Sentry.should_propagate_trace("https://api.example.com")
end

@testitem "before_send_transaction and filtering" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0,
                     before_send_transaction=(event, hint) -> begin
                         event["transaction"] == "drop" && return nothing
                         event["transaction"] == "fail" && error("broken")
                         filter!(s -> s["op"] != "noise", event["spans"])
                         event
                     end)
    start_transaction(name="drop") do _ end
    start_transaction(name="fail") do _ end
    @test isempty(SentryTest.transactions())
    start_transaction(name="keep") do _
        start_span(op="noise") do _ end
        start_span(op="signal") do _ end
    end
    @test [s["op"] for s in SentryTest.last_transaction()["spans"]] == ["signal"]

    SentryTest.init!(; traces_sample_rate=1.0, trace_ignore_status_codes=[404],
                     ignore_spans=["ignored span", r"^health.*", Dict("attributes" => Dict("skip" => true))])
    start_transaction(name="not found") do t
        Sentry.set_http_status(t, 404)
    end
    @test isempty(SentryTest.transactions())
    start_transaction(name="found") do t
        start_span(name="ignored span") do _ end
        start_span(name="healthcheck") do _ end
        start_span(name="kept", attributes=Dict("skip" => false)) do _ end
        Sentry.set_http_status(t, 200)
    end
    txn = SentryTest.last_transaction()
    @test [s["description"] for s in txn["spans"]] == ["kept"]
    @test txn["contexts"]["response"]["status_code"] == 200
    @test txn["contexts"]["trace"]["status"] == "ok"

    # Spans past max_spans are dropped.
    SentryTest.init!(; traces_sample_rate=1.0, max_spans=2)
    start_transaction(name="many") do _
        for i in 1:5
            start_span(op="s$i") do _ end
        end
    end
    @test length(SentryTest.last_transaction()["spans"]) == 2
end

@testitem "unfinished spans" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0, debug=true)
    t = start_transaction(name="leaky")
    s = start_span(op="never finished"; activate=false)
    @test_logs (:warn, r"didn't complete") match_mode=:any finish_transaction(t)
    @test isempty(SentryTest.last_transaction()["spans"])
    Sentry._debug_enabled[] = false

    # A transaction without a name gets a placeholder.
    SentryTest.init!(; traces_sample_rate=1.0)
    start_transaction(; force_new=true) do _ end
    @test SentryTest.last_transaction()["transaction"] == "<unlabeled transaction>"
end

@testitem "span api" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0)
    start_transaction(name="api") do t
        @test occursin("Transaction(name=\"api\"", repr(t))
        Sentry.update_current_span(; op="renamed.op", name="renamed", data=Dict("d" => 1), attributes=Dict("a" => :sym))
        @test t.op == "renamed.op"
        @test t.name == "renamed"
        @test t.data["a"] == "sym"
        set_transaction_name("final"; source="task")
        @test t.name == "final"
        Sentry.set_tags(t, (; x=1))
        Sentry.set_context(t, "custom", Dict("c" => 1))
        Sentry.remove_attribute(t, "d")
        Sentry.set_name(t, "named"; source="view")
        start_span(op="child") do s
            @test occursin("Span(op=\"child\"", repr(s))
            Sentry.set_status(s, "cancelled")
            Sentry.set_description(s, "described")
            Sentry.set_attributes(s, Dict("n" => 1))
            Sentry.set_name(s, "child name")
            Sentry.set_measurement(s, "on child", 2)
            Sentry.update_data(s, Dict("u" => 2))
            @test !Sentry.is_success(s)
            Sentry.set_http_status(s, 503)
            @test s.status == "unavailable"
        end
    end
    txn = SentryTest.last_transaction()
    @test txn["transaction"] == "named"
    @test txn["transaction_info"]["source"] == "view"
    @test txn["contexts"]["custom"]["c"] == 1
    @test txn["measurements"]["on child"]["value"] == 2
    child = only(txn["spans"])
    @test child["description"] == "child name"
    @test child["data"]["u"] == 2
    @test child["tags"]["status"] == "unavailable"

    @test Sentry.update_current_span(; op="none") === nothing
    @test set_measurement("outside", 1) === nothing

    for (code, status) in ((200, "ok"), (401, "unauthenticated"), (403, "permission_denied"), (404, "not_found"),
                           (409, "already_exists"), (413, "failed_precondition"), (429, "resource_exhausted"),
                           (400, "invalid_argument"), (500, "internal_error"), (501, "unimplemented"),
                           (504, "deadline_exceeded"), (600, "unknown_error"))
        @test Sentry.span_status_from_http_code(code) == status
    end
end

@testitem "standalone spans" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0)
    # Without a transaction a span still has an id in the current trace, but is not sent.
    start_span(op="alone") do s
        @test s.containing_transaction === nothing
        @test Sentry.iter_headers(s) == Pair{String,String}[]
        @test Sentry.get_baggage(s) === nothing
    end
    @test isempty(SentryTest.transactions())
end

@testitem "@trace" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0)

    Sentry.@trace function traced_add(a, b)
        return a + b
    end
    Sentry.@trace op="db" traced_mul(a::Int, b::Int)::Int = a * b
    Sentry.@trace name="custom name" function traced_where(x::T) where {T}
        x
    end

    start_transaction(name="traced") do _
        @test traced_add(1, 2) == 3
        @test traced_mul(2, 3) == 6
        @test traced_where(:x) == :x
        @test Sentry.@trace("block", 1 + 1) == 2
        @test (Sentry.@trace "configured block" op="compute" 2 * 2) == 4
    end
    spans = SentryTest.last_transaction()["spans"]
    descriptions = Set(s["description"] for s in spans)
    @test "$(@__MODULE__).traced_add" in descriptions
    @test "custom name" in descriptions
    @test "block" in descriptions
    @test spans[findfirst(s -> endswith(s["description"], "traced_mul"), spans)]["op"] == "db"
    @test spans[findfirst(s -> s["description"] == "configured block", spans)]["op"] == "compute"

    @test_throws LoadError @eval Sentry.@trace
    @test_throws LoadError @eval Sentry.@trace 1 2 3
    @test Sentry._function_name(:(Base.f(x))) == "f"
    @test Sentry._function_name(:x) == "anonymous"
    @test !Sentry._is_function_def(:(x = 1))
end

@testitem "streamed spans" setup=[SentryTest] begin
    SentryTest.init!(; traces_sample_rate=1.0, trace_lifecycle="stream",
                     before_send_span=(span, hint) -> begin
                         span["name"] == "rename me" && (span["name"] = "renamed")
                         span
                     end)
    start_transaction(name="segment", op="task") do t
        start_span(op="child", name="rename me") do s
            Sentry.set_tag(s, "tagged", "yes")
        end
        start_span(op="failing") do s
            Sentry.set_status(s, "internal_error")
        end
    end
    @test isempty(SentryTest.transactions())
    Sentry.flush()
    batch = only(SentryTest.items("span"))
    @test batch["version"] == 2
    spans = batch["items"]
    @test length(spans) == 3
    segment = spans[findfirst(s -> s["is_segment"], spans)]
    @test segment["name"] == "segment"
    @test segment["attributes"]["sentry.op"]["value"] == "task"
    @test segment["attributes"]["sentry.segment.name.source"]["value"] == "custom"
    child = spans[findfirst(s -> s["name"] == "renamed", spans)]
    @test child["attributes"]["tagged"]["value"] == "yes"
    @test child["parent_span_id"] == segment["span_id"]
    @test child["attributes"]["sentry.segment.id"]["value"] == segment["span_id"]
    @test spans[findfirst(s -> get(s["attributes"], "sentry.op", Dict())["value"] == "failing", spans)]["status"] == "error"
    env = only(SentryTest.envelopes_of("span"))
    @test env.headers["trace"]["transaction"] == "segment"
    @test only(env.items).headers["content_type"] == "application/vnd.sentry.items.span.v2+json"

    # The batcher drops spans beyond its limit, and flushes when full.
    lost = Any[]
    sent = Sentry.Envelope[]
    b = Sentry.SpanBatcher(e -> push!(sent, e), (r, c, q) -> push!(lost, r); flush_interval=3600.0)
    b.max_before_flush = 2
    b.max_before_drop = 2
    Sentry.add!(b, Dict{String,Any}("trace_id" => "t", "attributes" => Dict{String,Any}()), nothing)
    Sentry.add!(b, Dict{String,Any}("trace_id" => "t"), nothing)
    @test length(sent) == 1
    @test !haskey(only(Sentry.payload_json(only(sent[1].items))["items"][1:1]), "attributes")
    b.max_before_flush = 10
    Sentry.add!(b, Dict{String,Any}("trace_id" => "t"), nothing)
    Sentry.add!(b, Dict{String,Any}("trace_id" => "t"), nothing)
    Sentry.add!(b, Dict{String,Any}("trace_id" => "t"), nothing)
    @test lost == ["queue_overflow"]
    Sentry.kill!(b)
    Sentry.add!(b, Dict{String,Any}("trace_id" => "t"), nothing)
    @test length(Sentry.flush!(b)) == 1
end

@testitem "baggage" begin
    b = Sentry.baggage_from_header("sentry-trace_id=abc, sentry-public_key=k%20x,other=1,noequals")
    @test b.sentry_items == Dict("trace_id" => "abc", "public_key" => "k x")
    @test b.third_party_items == "other=1"
    @test !b.mutable
    @test Sentry.serialize_baggage(b) == "sentry-public_key=k%20x,sentry-trace_id=abc"
    @test Sentry.serialize_baggage(b; include_third_party=true) == "sentry-public_key=k%20x,sentry-trace_id=abc,other=1"
    @test Sentry.baggage_from_header(nothing).mutable
    @test Sentry.strip_sentry_baggage("a=1, sentry-x=2,b=3") == "a=1,b=3"
    @test Sentry.baggage_sample_rand(Sentry.Baggage(Dict("sample_rand" => "1.5"))) === nothing
    @test Sentry.baggage_sample_rate(Sentry.Baggage(Dict("sample_rate" => "0.5"))) == 0.5

    @test Sentry.extract_sentrytrace_data(nothing) === nothing
    @test Sentry.extract_sentrytrace_data("") === nothing
    @test Sentry.extract_sentrytrace_data(" , ") === nothing
    @test Sentry.extract_sentrytrace_data("not a header") === nothing
    d = Sentry.extract_sentrytrace_data(",$("a"^32)-$("b"^16)-1")
    @test d.parent_sampled === true
    d = Sentry.extract_sentrytrace_data("00-$("a"^32)-$("b"^16)-00")
    @test d.trace_id == "a"^32
    @test d.parent_sampled === nothing
    @test Sentry.extract_w3c_traceparent("junk") === nothing
    @test Sentry.extract_w3c_traceparent(nothing) === nothing

    # sample_rand is consistent with the incoming decision and rate.
    for (sampled, rate) in ((true, 0.3), (false, 0.3))
        p = Sentry.PropagationContext()
        p.trace_id = "a"^32
        p.parent_sampled = sampled
        p.baggage = Sentry.Baggage(Dict("sample_rate" => string(rate)))
        Sentry.fill_sample_rand!(p)
        r = parse(Float64, p.baggage.sentry_items["sample_rand"])
        @test sampled ? r < rate : r >= rate
    end
    # Inconsistent input leaves it missing.
    p = Sentry.PropagationContext()
    p.parent_sampled = true
    p.baggage = Sentry.Baggage(Dict("sample_rate" => "0"))
    Sentry.fill_sample_rand!(p)
    @test !haskey(p.baggage.sentry_items, "sample_rand")
    @test Sentry.fill_sample_rand!(Sentry.PropagationContext()) === nothing
    @test_throws ArgumentError Sentry.generate_sample_rand("x"; interval=(0.5, 0.5))
    @test Sentry.generate_sample_rand("x"; interval=(0.5, 0.5000001)) == 0.5
    @test Sentry.generate_sample_rand("same") == Sentry.generate_sample_rand("same")

    @test Sentry.normalize_incoming_data(nothing) == Dict{String,String}()
    @test Sentry.normalize_incoming_data((; HTTP_X_Y="1")) == Dict("x-y" => "1")
end

@testitem "backpressure downsampling" setup=[SentryTest] begin
    client = SentryTest.init!(; traces_sample_rate=1.0)
    client.monitor = Sentry.Monitor(client.transport; start=false)
    client.monitor.downsample_factor = 1
    start_transaction(name="downsampled") do t
        @test t.sample_rate == 0.5
    end
    client.monitor.downsample_factor = 10
    # Dropped for backpressure are recorded as such.
    t = start_transaction(name="dropped", sampled=false)
    finish_transaction(t)
end
