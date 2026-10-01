##############################
# * Background worker
#----------------------------

"""
Processes queued values on a task of its own, so that sending never blocks the
program being monitored. The queue is bounded: when it is full, new values are
refused rather than making the caller wait.
"""
mutable struct BackgroundWorker
    queue::Channel{Any}
    task::Task
    pending::Threads.Atomic{Int}
end

function BackgroundWorker(f, size::Integer)
    queue = Channel{Any}(max(size, 1))
    pending = Threads.Atomic{Int}(0)
    task = Threads.@spawn begin
        # Iterating the channel drains whatever is still buffered once it has
        # been closed, and then finishes, which is what lets a shutdown wait for
        # the sends themselves rather than just for the queue to empty.
        for x in queue
            try
                f(x)
            catch exc
                _report_internal_exception(exc, catch_backtrace())
            finally
                Threads.atomic_sub!(pending, 1)
            end
        end
    end
    bind(queue, task)
    return BackgroundWorker(queue, task, pending)
end

"""Queues `x`, returning false when the queue is full or closed."""
function submit!(w::BackgroundWorker, x)
    lock(w.queue)
    try
        isopen(w.queue) || return false
        Base.n_avail(w.queue) >= w.queue.sz_max && return false
        Threads.atomic_add!(w.pending, 1)
        put!(w.queue, x)
        return true
    catch exc
        exc isa InvalidStateException || rethrow() # COV_EXCL_LINE
        Threads.atomic_sub!(w.pending, 1) # COV_EXCL_LINE
        return false # COV_EXCL_LINE
    finally
        unlock(w.queue)
    end
end

is_full(w::BackgroundWorker) = Base.n_avail(w.queue) >= w.queue.sz_max

"""Waits until everything queued so far has been processed. Returns false on timeout."""
function flush_worker(w::BackgroundWorker, timeout::Real)
    w.pending[] <= 0 && return true
    return timedwait(() -> w.pending[] <= 0, timeout; pollint=0.01) === :ok
end

"""Stops accepting work, and waits up to `timeout` for the queue to drain."""
function kill_worker(w::BackgroundWorker, timeout::Real)
    Base.close(w.queue)
    istaskdone(w.task) && return true
    return timedwait(() -> istaskdone(w.task), timeout; pollint=0.01) === :ok
end

@testitem "background worker" begin
    seen = Int[]
    w = Sentry.BackgroundWorker(2) do x
        x == 0 && error("a failure does not stop the worker")
        sleep(0.05)
        push!(seen, x)
    end
    @test Sentry.submit!(w, 0)
    @test Sentry.submit!(w, 1)
    @test Sentry.flush_worker(w, 10)
    @test seen == [1]

    # A full queue refuses more work instead of blocking.
    blocker = Base.Event()
    w2 = Sentry.BackgroundWorker(x -> wait(blocker), 1)
    @test Sentry.submit!(w2, 1)
    sleep(0.2)  # let the worker pick up the first value and block on it
    @test Sentry.submit!(w2, 2)
    @test Sentry.is_full(w2)
    @test !Sentry.submit!(w2, 3)
    @test !Sentry.flush_worker(w2, 0.1)
    @test !Sentry.kill_worker(w2, 0.1)
    notify(blocker)
    @test Sentry.flush_worker(w2, 10)

    @test Sentry.kill_worker(w, 10)
    @test Sentry.kill_worker(w, 10)
    # Nothing can be queued once the worker has been stopped.
    @test !Sentry.submit!(w, 5)
end

##############################
# * Transports
#----------------------------

"""
    AbstractTransport

Sends envelopes to sentry. Subtype this and implement
`Sentry.capture_envelope(transport, envelope)` to send them somewhere else, then
pass an instance as the `transport` option to `init`. A plain function taking
an [`Envelope`](@ref) works as a transport too.
"""
abstract type AbstractTransport end

function capture_envelope end
flush_transport(::AbstractTransport, timeout::Real) = true
kill_transport(::AbstractTransport, timeout::Real=0.0) = nothing
record_lost_event(::AbstractTransport, reason, category; quantity::Integer=1) = nothing
record_lost_event(t::AbstractTransport, reason, item::Item) = record_lost_event(t, reason, data_category(item))
is_healthy(::AbstractTransport) = true

"""Adapts a function taking an envelope into a transport."""
struct FunctionTransport <: AbstractTransport
    f::Any
end
capture_envelope(t::FunctionTransport, env::Envelope) = (t.f(env); nothing)

"""
Pretty prints envelopes instead of sending them. Used for the `"fake"` DSN, which
is handy for trying out what would be sent.
"""
struct PrintTransport <: AbstractTransport
    io::IO
end
PrintTransport() = PrintTransport(stdout)

function capture_envelope(t::PrintTransport, env::Envelope)
    @info "Would have sent this body"
    println(t.io, JSON.json(env.headers, 4))
    for item in env.items
        println(t.io, JSON.json(item.headers, 4))
        content_type = get(item.headers, "content_type", "")
        if occursin("json", content_type)
            println(t.io, JSON.json(JSON.parse(String(copy(item.payload))), 4))
        else
            println(t.io, "<$(length(item.payload)) bytes>")
        end
    end
    return nothing
end

"""
The default transport. Envelopes are gzipped and sent over HTTP from a
background task, honouring sentry's rate limits and reporting what was dropped
through client reports.
"""
mutable struct HttpTransport <: AbstractTransport
    options::Options
    dsn::Dsn
    url::String
    auth::String
    worker::BackgroundWorker
    lock::ReentrantLock
    disabled_until::Dict{Union{Nothing,String},Float64}
    discarded::Dict{Tuple{String,String},Int}
    last_client_report::Float64
    http_client::Any
    proxy::Any
end

const CLIENT_REPORT_INTERVAL = 30.0
const HTTP_TIMEOUT = 30

function HttpTransport(options::Options, dsn::Dsn)
    url = envelope_url(dsn)
    proxy = dsn.scheme == "https" ? options.https_proxy : options.http_proxy
    if proxy === nothing
        # An explicit http_proxy is used for https too, as in the other SDKs.
        proxy = options.http_proxy
    end
    isempty(options.proxy_headers) || @warn "Sentry: proxy_headers are not supported by HTTP.jl and are ignored; put proxy credentials in the proxy url instead."

    http_client = nothing
    if options.ca_certs !== nothing || options.cert_file !== nothing || options.key_file !== nothing
        http_client = try
            tls = HTTP.TLS.Config(; ca_file=options.ca_certs, cert_file=options.cert_file, key_file=options.key_file)
            HTTP.Client(; transport=HTTP.Transport(; tls_config=tls, proxy=something(proxy, HTTP.ProxyFromEnvironment())))
        catch exc
            @warn "Sentry: could not configure TLS for the transport" exception=exc
            nothing
        end
    end

    t = HttpTransport(options, dsn, url, auth_header(dsn, "$SDK_NAME/$VERSION"),
                      BackgroundWorker(identity, 1), ReentrantLock(),
                      Dict{Union{Nothing,String},Float64}(), Dict{Tuple{String,String},Int}(),
                      time(), http_client, proxy)
    # The placeholder above only exists because the worker needs the transport.
    kill_worker(t.worker, 0)
    # Besides envelopes, the worker runs jobs (functions) queued behind them.
    t.worker = BackgroundWorker(x -> x isa Envelope ? send_envelope(t, x) : x(), options.transport_queue_size)
    return t
end

function capture_envelope(t::HttpTransport, env::Envelope)
    if !submit!(t.worker, env)
        sdk_debug("Dropping envelope, the transport queue is full")
        for item in env.items
            record_lost_event(t, "queue_overflow", item)
        end
    end
    return nothing
end

function flush_transport(t::HttpTransport, timeout::Real)
    # Queued behind what is already waiting, so the report covers those sends too.
    submit!(t.worker, () -> flush_client_reports(t; force=true))
    return flush_worker(t.worker, timeout)
end

function kill_transport(t::HttpTransport, timeout::Real=0.0)
    ok = kill_worker(t.worker, timeout)
    ok || @warn "Timed out sending queued events to sentry"
    return nothing
end

is_full(t::HttpTransport) = is_full(t.worker)
is_healthy(t::HttpTransport) = !(is_full(t) || is_rate_limited(t))

function record_lost_event(t::HttpTransport, reason, category; quantity::Integer=1)
    t.options.send_client_reports || return nothing
    quantity <= 0 && return nothing
    @lock t.lock begin
        key = (String(category), String(reason))
        t.discarded[key] = get(t.discarded, key, 0) + quantity
    end
    return nothing
end

function record_lost_event(t::HttpTransport, reason, item::Item)
    category = data_category(item)
    quantity = 1
    if category == "transaction"
        spans = try
            length(get(payload_json(item), "spans", ())) + 1
        catch
            1
        end
        record_lost_event(t, reason, "span"; quantity=spans)
    elseif category == "log_item"
        record_lost_event(t, reason, "log_byte"; quantity=length(item.payload))
        quantity = get(item.headers, "item_count", 1)
    elseif category == "trace_metric" || category == "span"
        quantity = get(item.headers, "item_count", 1)
    elseif category == "attachment"
        quantity = max(length(item.payload), 1)
    end
    return record_lost_event(t, reason, category; quantity=quantity)
end

"""Takes the pending client report as an envelope item, if one is due."""
function fetch_client_report(t::HttpTransport; force::Bool=false, interval::Real=CLIENT_REPORT_INTERVAL)
    t.options.send_client_reports || return nothing
    discarded = @lock t.lock begin
        (force || t.last_client_report < time() - interval) || return nothing
        d = t.discarded
        t.discarded = Dict{Tuple{String,String},Int}()
        t.last_client_report = time()
        d
    end
    isempty(discarded) && return nothing
    payload = Dict{String,Any}(
        "timestamp" => time(),
        "discarded_events" => [Dict("reason" => r, "category" => c, "quantity" => q)
                               for ((c, r), q) in discarded],
    )
    return json_item("client_report", payload)
end

"""Sends the pending client report now. Runs on the worker."""
function flush_client_reports(t::HttpTransport; force::Bool=false)
    item = fetch_client_report(t; force=force)
    item === nothing && return nothing
    env = Envelope(Dict{String,Any}("sent_at" => nowstr()))
    push!(env, item)
    send_envelope(t, env)
    return nothing
end

##############################
# * Rate limits
#----------------------------

"""
Parses an `X-Sentry-Rate-Limits` header into `(category, seconds)` pairs, where
a category of `nothing` limits everything.
"""
function parse_rate_limits(header::AbstractString)
    out = Tuple{Union{Nothing,String},Float64}[]
    for limit in split(header, ',')
        parts = split(strip(limit), ':')
        length(parts) >= 2 || continue
        secs = tryparse(Float64, parts[1])
        secs === nothing && continue
        categories = parts[2]
        if isempty(categories)
            push!(out, (nothing, secs))
        else
            for c in split(categories, ';')
                push!(out, (String(c), secs))
            end
        end
    end
    return out
end

function parse_retry_after(value)
    value === nothing && return nothing
    secs = tryparse(Float64, strip(value))
    secs !== nothing && return secs
    # An HTTP date.
    try
        dt = DateTime(strip(replace(value, r"\s*GMT$" => "")), dateformat"e, d u y H:M:S")
        return max(datetime2unix(dt) - time(), 0.0)
    catch
        return nothing
    end
end

function update_rate_limits!(t::HttpTransport, status::Integer, header_lookup)
    now_ = time()
    limits = header_lookup("X-Sentry-Rate-Limits")
    if limits !== nothing && !isempty(limits)
        sdk_warn("Rate-limited via x-sentry-rate-limits")
        @lock t.lock for (cat, secs) in parse_rate_limits(limits)
            t.disabled_until[cat] = now_ + secs
        end
    elseif status == 429
        sdk_warn("Rate-limited via 429")
        secs = something(parse_retry_after(header_lookup("Retry-After")), 60.0)
        @lock t.lock t.disabled_until[nothing] = now_ + secs
    end
    return nothing
end

function is_disabled(t::HttpTransport, category::AbstractString)
    now_ = time()
    @lock t.lock begin
        get(t.disabled_until, category, 0.0) > now_ && return true
        # Transactions being limited also limits their spans, and vice versa.
        category == "span" && get(t.disabled_until, "transaction", 0.0) > now_ && return true
        return get(t.disabled_until, nothing, 0.0) > now_
    end
end

is_rate_limited(t::HttpTransport) = @lock t.lock any(>(time()), values(t.disabled_until))

##############################
# * Sending
#----------------------------

"""Removes rate limited items and attaches a due client report."""
function prepare_envelope(t::HttpTransport, env::Envelope)
    items = Item[]
    for item in env.items
        if is_disabled(t, data_category(item))
            record_lost_event(t, "ratelimit_backoff", item)
        else
            push!(items, item)
        end
    end
    isempty(items) && return nothing
    out = Envelope(env.headers, items)
    report = fetch_client_report(t)
    report === nothing || push!(out, report)
    return out
end

gzip_envelope(env::Envelope) = transcode(GzipCompressor, Vector{UInt8}(serialize_envelope(env)))

function send_envelope(t::HttpTransport, env::Envelope)
    prepared = prepare_envelope(t, env)
    prepared === nothing && return nothing

    body = gzip_envelope(prepared)
    headers = ["Content-Type" => "application/x-sentry-envelope",
               "Content-Encoding" => "gzip",
               "User-Agent" => "$SDK_NAME/$VERSION",
               "X-Sentry-Auth" => t.auth]

    sdk_debug("Sending envelope [", describe(prepared), "] project:", t.dsn.project_id, " host:", t.dsn.host)

    response = try
        kwargs = (; status_exception=false, retry=false, redirect=false, request_timeout=HTTP_TIMEOUT)
        if t.http_client !== nothing
            HTTP.request("POST", t.url, headers, body; client=t.http_client, kwargs...)
        elseif t.proxy !== nothing
            HTTP.request("POST", t.url, headers, body; proxy=t.proxy, kwargs...)
        else
            HTTP.request("POST", t.url, headers, body; kwargs...)
        end
    catch exc
        sdk_warn("Failed to send an envelope: ", sprint(showerror, exc))
        for item in prepared.items
            record_lost_event(t, "network_error", item)
        end
        return nothing
    end

    handle_response(t, response, prepared)
    return response
end

function handle_response(t::HttpTransport, response, env::Envelope)
    status = response.status
    lookup = name -> begin
        v = HTTP.header(response, name, "")
        isempty(v) ? nothing : v
    end
    update_rate_limits!(t, status, lookup)

    if status == 413
        sdk_warn("HTTP 413: Event dropped due to exceeded envelope size limit")
        for item in env.items
            record_lost_event(t, "send_error", item)
        end
    elseif status == 429
        # Relay records the outcome of rate limited events itself.
    elseif !(200 <= status < 300)
        sdk_warn("Unexpected status code: ", status)
        for item in env.items
            record_lost_event(t, "network_error", item)
        end
    end
    return nothing
end

##############################
# * Spotlight
#----------------------------

const DEFAULT_SPOTLIGHT_URL = "http://localhost:8969/stream"

"""
Sends a copy of every envelope to a local [Spotlight](https://spotlightjs.com)
sidecar, for debugging during development.
"""
mutable struct SpotlightTransport <: AbstractTransport
    url::String
    worker::BackgroundWorker
end

function SpotlightTransport(url::AbstractString)
    worker = BackgroundWorker(DEFAULT_QUEUE_SIZE) do env
        HTTP.request("POST", url, ["Content-Type" => "application/x-sentry-envelope"],
                     serialize_envelope(env); status_exception=false, retry=false,
                     request_timeout=5)
    end
    return SpotlightTransport(String(url), worker)
end

capture_envelope(t::SpotlightTransport, env::Envelope) = (submit!(t.worker, env); nothing)
flush_transport(t::SpotlightTransport, timeout::Real) = flush_worker(t.worker, timeout)
kill_transport(t::SpotlightTransport, timeout::Real=0.0) = (kill_worker(t.worker, timeout); nothing)

function spotlight_url(setting)
    (setting === nothing || setting === false) && return nothing
    setting === true && return DEFAULT_SPOTLIGHT_URL
    setting isa AbstractString && return isempty(setting) ? nothing : String(setting)
    return nothing
end

"""Picks the transport for a set of options."""
function make_transport(options::Options)
    t = options.transport
    t isa AbstractTransport && return t
    t === nothing || return FunctionTransport(t)
    options.dsn === nothing && return nothing
    options.dsn == "fake" && return PrintTransport()
    return HttpTransport(options, parse_dsn(options.dsn))
end
