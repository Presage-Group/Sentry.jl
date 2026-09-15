using Sentry
using Test

using CodecZlib
using HTTP
using JSON

# Collects the envelopes that Sentry.jl would have sent to a real sentry server.
const received = Channel{String}(16)

# Delays the response, to emulate a sentry server that is slower than the local
# one. Nothing is recorded if the client gives up in the meantime.
const response_delay = Ref(0.0)

const server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
    sleep(response_delay[])
    put!(received, String(transcode(GzipDecompressor, Vector{UInt8}(request.body))))
    HTTP.Response(200, "ok")
end

Sentry.init("http://abcdef1234567890@127.0.0.1:$(HTTP.port(server))/42";
            traces_sample_rate=1.0,
            release="v1.2.3",
            shutdown_timeout=20.0)

"""
Wait for the next envelope and split it into its headers and payloads.
"""
function next_envelope(timeout=15)
    deadline = time() + timeout
    while !isready(received) && time() < deadline
        sleep(0.05)
    end
    if !isready(received)
        error("Timed out waiting for an envelope")
    end

    items = filter(!isempty, split(take!(received), '\n'))
    return map(JSON.parse, items), items
end

@testset "Sentry.jl" begin
    @test Sentry.parse_dsn("fake") == (upstream = "", project_id = "", public_key = "")
    @test_throws ErrorException Sentry.parse_dsn("https://0000000000000000000000000000000000000000.ingest.sentry.io/0000000")
    @test Sentry.parse_dsn("https://abcdef1234567890@a12345.us.sentry.io/1234567890123456789") == (upstream = "https://a12345.us.sentry.io", project_id = "1234567890123456789", public_key = "abcdef1234567890")

    set_tag("test", "message")
    @test Sentry.global_tags["test"] == "message"
    @test_warn "A 'release' tag is ignored by sentry upstream. You should instead set the release in the `init` call" set_tag("release", "v1.0")
    @test Sentry.global_tags["release"] == "v1.0"

    @test length(Sentry.generate_uuid4()) == 32

    @test Sentry.main_hub.shutdown_timeout == 20.0
    @test Sentry.Hub().shutdown_timeout == Sentry.DEFAULT_SHUTDOWN_TIMEOUT

    d = Sentry.FilterNothings([1, nothing, 2])
    @test d[3] == 2
    @test d[1] == 1

    @testset "capture_message" begin
        capture_message("hello", Warn; attachments=[(; command="ls")])
        parsed, items = next_envelope()
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

    @testset "capture_exception" begin
        try
            error("boom")
        catch exc
            capture_exception(exc)
        end
        parsed, _ = next_envelope()
        exception = parsed[3]["exception"]["values"][1]
        @test exception["type"] == "ErrorException"
        @test exception["value"] == "boom"

        # The zero argument method reads the current exception stack.
        try
            error("implicit boom")
        catch
            capture_exception()
        end
        parsed, _ = next_envelope()
        @test parsed[3]["exception"]["values"][1]["value"] == "implicit boom"
    end

    @testset "transactions" begin
        start_transaction(name="job", op="task") do _
            start_transaction(op="child", description="inner") do _ end
        end

        parsed, items = next_envelope()
        _, header, transaction = parsed

        @test header["type"] == "transaction"
        @test header["length"] == sizeof(items[3])
        @test transaction["transaction"] == "job"
        @test transaction["release"] == "v1.2.3"

        trace = transaction["contexts"]["trace"]
        @test trace["op"] == "task"
        @test length(transaction["spans"]) == 1
        @test transaction["spans"][1]["parent_span_id"] == trace["span_id"]
        @test transaction["spans"][1]["trace_id"] == trace["trace_id"]
    end

    @testset "inhibited transactions" begin
        # An inhibited transaction must not lock out tracing for the rest of the
        # task, so run this in its own task to keep the check honest. The
        # results are collected because the task has its own testset state.
        results = fetch(@async begin
            inhibited = start_transaction(trace_id=nothing)
            nested = start_transaction(op="nested")

            finish_transaction(inhibited)
            after_nested = task_local_storage(:sentry_transaction)
            finish_transaction(inhibited)
            after_outer = task_local_storage(:sentry_transaction)

            # Tracing works again now that the inhibition has been undone.
            t = start_transaction(name="after")
            finish_transaction(t)

            (; inhibited, nested, after_nested, after_outer, t)
        end)

        @test results.inhibited isa Sentry.InhibitTransaction
        @test results.nested === results.inhibited
        @test results.after_nested === results.inhibited
        @test results.after_outer === nothing
        @test results.t.transaction isa Sentry.Transaction

        parsed, _ = next_envelope()
        @test parsed[3]["transaction"] == "after"
    end

    @testset "flushing on exit" begin
        # Needs a real process exit to run the atexit handler, and deliberately
        # does not wait for the send itself. The response is delayed so that
        # just emptying the queue is not enough to get the event through.
        code = """
            using Sentry
            Sentry.init("http://abcdef1234567890@127.0.0.1:$(HTTP.port(server))/42")
            capture_message("sent while exiting")
            """

        response_delay[] = 3.0
        try
            elapsed = @elapsed run(`$(Base.julia_cmd()) --project=$(Base.active_project()) --eval $code`)

            # Exiting has to block until the send itself came back
            @test elapsed > response_delay[]

            parsed, _ = next_envelope()
            @test parsed[3]["message"]["formatted"] == "sent while exiting"
        finally
            response_delay[] = 0.0
        end
    end

    @testset "fake dsn" begin
        # The fake dsn pretty prints the envelope instead of sending it.
        dsn = Sentry.main_hub.dsn
        Sentry.main_hub.dsn = "fake"
        try
            @test_logs (:info, "Would have sent this body") match_mode=:any Sentry.send_envelope(Sentry.Event(message=(; formatted="dry run")))
        finally
            Sentry.main_hub.dsn = dsn
        end
    end

    # Kept last because re-initialising must not disturb the running hub.
    @testset "re-initialising" begin
        @test_warn "Sentry already initialised." Sentry.init("http://cafe@127.0.0.1:1/99")
        @test Sentry.main_hub.dsn == "http://abcdef1234567890@127.0.0.1:$(HTTP.port(server))/42"
    end
end

close(server)
