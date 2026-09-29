using TestItemRunner

"""
A local sentry server that records the envelopes Sentry.jl sends to it, plus the
one initialised hub that talks to it.

Test items run in the same process and share `Sentry.main_hub`, which can only be
initialised once, so the hub lives here rather than in any single test item. Use
it with `@testitem "..." setup=[FakeSentry] begin ... end`.
"""
@testmodule FakeSentry begin
    using Sentry

    # Reached through the package, so that the test environment does not need to
    # declare these as dependencies of its own.
    const HTTP = Sentry.HTTP
    const JSON = Sentry.JSON
    const GzipDecompressor = Sentry.CodecZlib.GzipDecompressor

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

    const port = HTTP.port(server)
    const dsn = "http://abcdef1234567890@127.0.0.1:$port/42"
    const shutdown_timeout = 20.0

    # Registered before `init` registers `clear_queue`, so that the LIFO atexit
    # order keeps the server up for the final flush.
    atexit(() -> close(server))

    Sentry.init(dsn; traces_sample_rate=1.0, release="v1.2.3", shutdown_timeout)

    """
    Wait for the next envelope and split it into its headers and payloads.
    """
    function next_envelope(timeout=60)
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

    """
    Drop whatever other test items left behind, so that the next `next_envelope`
    call is the envelope this test item caused. Call it before the action under
    test, not after, because a send may still be in flight.
    """
    function reset!(; settle=0.3, timeout=10.0)
        deadline = time() + timeout
        while true
            while isready(received)
                take!(received)
            end
            sleep(settle)
            (!isready(received) || time() > deadline) && break
        end

        empty!(Sentry.global_tags)
        return nothing
    end
end
