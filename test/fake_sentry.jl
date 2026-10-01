using TestItemRunner

"""
A client whose transport keeps the envelopes it is given, so that tests can
look at exactly what would have been sent. Every `init!` starts from fresh
scopes and an empty transport.

Use it with `@testitem "..." setup=[SentryTest] begin ... end`.
"""
@testmodule SentryTest begin
    using Sentry

    struct TestTransport <: Sentry.AbstractTransport
        envelopes::Vector{Sentry.Envelope}
        lock::ReentrantLock
    end

    # Round trip through the wire format, so that tests see what sentry would.
    function Sentry.capture_envelope(t::TestTransport, env::Sentry.Envelope)
        parsed = Sentry.parse_envelope(Sentry.serialize_envelope(env))
        lock(t.lock) do
            push!(t.envelopes, parsed)
        end
        return nothing
    end

    const transport = TestTransport(Sentry.Envelope[], ReentrantLock())
    const DSN = "https://public@o1.ingest.sentry.io/42"

    function reset_state!()
        Sentry.close()
        Sentry._init_scopes!()
        delete!(task_local_storage(), :sentry_current_scope)
        Sentry.reset_dedupe!()
        lock(() -> empty!(transport.envelopes), transport.lock)
        return nothing
    end

    function init!(; kwargs...)
        reset_state!()
        defaults = (; transport=transport, release="v1.2.3", auto_session_tracking=false,
                    enable_backpressure_handling=false)
        return Sentry.init(DSN; merge(defaults, values(kwargs))...)
    end

    envelopes() = lock(() -> copy(transport.envelopes), transport.lock)
    clear!() = lock(() -> empty!(transport.envelopes), transport.lock)

    function items(type)
        out = Any[]
        for env in envelopes(), item in env.items
            Sentry.item_type(item) == type && push!(out, Sentry.payload_json(item))
        end
        return out
    end
    events() = items("event")
    transactions() = items("transaction")
    last_event() = last(events())
    last_transaction() = last(transactions())

    """Envelopes whose first item has the given type."""
    envelopes_of(type) = filter(e -> !isempty(e.items) && Sentry.item_type(e.items[1]) == type, envelopes())
end

"""
A local sentry server that records the envelopes Sentry.jl sends to it over
HTTP, for testing the transport itself.

Use it with `@testitem "..." setup=[FakeSentry] begin ... end`.
"""
@testmodule FakeSentry begin
    using Sentry

    # Reached through the package, so that the test environment does not need to
    # declare these as dependencies of its own.
    const HTTP = Sentry.HTTP
    const JSON = Sentry.JSON
    const GzipDecompressor = Sentry.CodecZlib.GzipDecompressor

    # Envelopes (decompressed) and the headers of the requests that carried them.
    const received = Channel{Tuple{String,Vector{Pair{String,String}}}}(1024)

    # Delays the response, to emulate a sentry server that is slower than the local
    # one. Nothing is recorded if the client gives up in the meantime.
    const response_delay = Ref(0.0)
    const response_status = Ref(200)
    const response_headers = Ref(Pair{String,String}[])

    const server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        sleep(response_delay[])
        body = Vector{UInt8}(request.body)
        if HTTP.header(request, "Content-Encoding", "") == "gzip"
            body = transcode(GzipDecompressor, body)
        end
        headers = Pair{String,String}[string(k) => string(v) for (k, v) in request.headers]
        put!(received, (String(body), headers))
        HTTP.Response(response_status[], response_headers[], "ok")
    end

    const port = HTTP.port(server)
    const dsn = "http://abcdef1234567890@127.0.0.1:$port/42"
    const shutdown_timeout = 20.0

    # Registered before `init` registers its own hook, so that the LIFO atexit
    # order keeps the server up for the final flush.
    atexit(() -> close(server))

    function init!(; kwargs...)
        Sentry.close()
        Sentry._init_scopes!()
        delete!(task_local_storage(), :sentry_current_scope)
        Sentry.reset_dedupe!()
        response_status[] = 200
        response_headers[] = Pair{String,String}[]
        response_delay[] = 0.0
        defaults = (; release="v1.2.3", shutdown_timeout=shutdown_timeout, auto_session_tracking=false,
                    traces_sample_rate=1.0, enable_backpressure_handling=false)
        client = Sentry.init(dsn; merge(defaults, values(kwargs))...)
        reset!()
        return client
    end

    """
    Wait for the next envelope, returning it and the request headers.
    """
    function next_envelope(timeout=60)
        if timedwait(() -> isready(received), timeout; pollint=0.05) !== :ok
            error("Timed out waiting for an envelope")
        end
        body, headers = take!(received)
        return Sentry.parse_envelope(body), headers
    end

    """
    Drop whatever other test items left behind, so that the next `next_envelope`
    call is the envelope this test item caused.
    """
    function reset!(; settle=0.2)
        while true
            while isready(received)
                take!(received)
            end
            sleep(settle)
            isready(received) || break
        end
        return nothing
    end

    function header(headers, name)
        for (k, v) in headers
            lowercase(k) == lowercase(name) && return v
        end
        return nothing
    end
end
