##############################
# * HTTP client
#----------------------------

"""
Instruments HTTP.jl: [`Sentry.http_request`](@ref) records outgoing requests
as spans and breadcrumbs and propagates the trace, and
[`Sentry.http_middleware`](@ref) turns incoming requests into transactions.
"""
struct HTTPIntegration <: Integration end
register_auto_integration(HTTPIntegration)

"""Splits a url into the parts sentry records, without any credentials."""
function parse_url_parts(url)
    try
        u = URIs.URI(string(url))
        port = isempty(u.port) ? "" : ":" * u.port
        base = string(u.scheme, isempty(u.scheme) ? "" : "://", u.host, port, u.path)
        return (; url=base, query=u.query, fragment=u.fragment)
    catch
        return (; url=string(url), query="", fragment="")
    end
end

function http_breadcrumb(method, url, status::Union{Nothing,Integer}, reason=nothing)
    data = Dict{String,Any}("url" => url, "method" => method)
    status === nothing || (data["status_code"] = status)
    reason === nothing || (data["reason"] = reason)
    level = status === nothing ? "error" : status >= 500 ? "error" : status >= 400 ? "warning" : "info"
    add_breadcrumb(; type="http", category="httplib", level=level, data=data)
    return nothing
end

"""
    http_request(method, url, headers=[], body=nothing; kwargs...)

`HTTP.request` with sentry instrumentation: the request is recorded as an
`http.client` span of the active transaction and as a breadcrumb, and the
trace headers are added when `url` matches `trace_propagation_targets`.
Takes the same arguments as `HTTP.request`.
"""
function http_request(method, url, headers=Pair{String,String}[], body=nothing; kwargs...)
    client = get_client()
    if client === nothing || get_integration(client, HTTPIntegration) === nothing
        return HTTP.request(method, url, headers, body; kwargs...)
    end
    m = uppercase(string(method))
    parts = parse_url_parts(url)
    hdrs = Pair{String,String}[string(k) => string(v) for (k, v) in (headers isa AbstractDict ? pairs(headers) : headers)]
    return start_span(; op="http.client", name="$m $(parts.url)", origin="auto.http.julia") do span
        set_data(span, "http.request.method", m)
        set_data(span, "url", parts.url)
        isempty(parts.query) || set_data(span, "http.query", parts.query)
        isempty(parts.fragment) || set_data(span, "http.fragment", parts.fragment)
        add_trace_headers(hdrs, string(url))
        t0 = time()
        response = try
            HTTP.request(method, url, hdrs, body; kwargs...)
        catch exc
            if exc isa HTTP.StatusError
                set_http_status(span, Int(exc.status))
                http_breadcrumb(m, parts.url, Int(exc.status), exc.response.reason)
            else
                set_status(span, "internal_error")
                http_breadcrumb(m, parts.url, nothing, safe_repr(exc; max_length=200))
            end
            rethrow()
        end
        set_http_status(span, response.status)
        http_breadcrumb(m, parts.url, response.status, response.reason)
        # Point slow requests at the code that made them.
        if client.options.enable_http_request_source &&
           (time() - t0) * 1000 >= client.options.http_request_source_threshold_ms
            add_code_source!(span, client.options)
        end
        response
    end
end

##############################
# * HTTP server
#----------------------------

const SENSITIVE_HEADERS = ("authorization", "cookie", "set-cookie", "x-forwarded-for", "x-real-ip",
                           "proxy-authorization", "x-api-key", "x-csrftoken")

const REQUEST_BODY_LIMITS = Dict("never" => 0, "small" => 1_000, "medium" => 10_000, "always" => typemax(Int))

"""The `request` interface of an event, for an `HTTP.Request`."""
function request_info(req, options)
    host = HTTP.header(req, "Host", "")
    scheme = HTTP.header(req, "X-Forwarded-Proto", "http")
    target = req.target
    path, query = occursin('?', target) ? split(target, '?'; limit=2) : (target, "")
    headers = Dict{String,Any}()
    for (k, v) in req.headers
        if !options.send_default_pii && lowercase(k) in SENSITIVE_HEADERS
            headers[k] = FILTERED
        else
            headers[k] = v
        end
    end
    info = Dict{String,Any}(
        "method" => req.method,
        "url" => isempty(host) ? String(path) : "$scheme://$host$path",
        "query_string" => String(query),
        "headers" => headers,
    )
    if options.send_default_pii
        ip = HTTP.header(req, "X-Forwarded-For", "")
        isempty(ip) || (info["env"] = Dict{String,Any}("REMOTE_ADDR" => strip(split(ip, ',')[1])))
        cookie = HTTP.header(req, "Cookie", "")
        isempty(cookie) || (info["cookies"] = cookie)
    end
    limit = REQUEST_BODY_LIMITS[options.max_request_body_size]
    body = hasproperty(req.body, :data) ? req.body.data : nothing
    if body isa AbstractVector{UInt8} && 0 < length(body) <= limit
        text = String(copy(body))
        ctype = lowercase(HTTP.header(req, "Content-Type", ""))
        info["data"] = if occursin("json", ctype)
            try
                JSON.parse(text)
            catch
                text
            end
        else
            text
        end
    end
    return info
end

function server_transaction_name(req, style::Symbol)
    path = split(req.target, '?')[1]
    style === :path && return String(path), "url"
    return "$(req.method) $path", "url"
end

"""
    http_middleware(handler; transaction_style=:method_and_path)

Wraps an HTTP.jl request handler (`Request -> Response`), so that each request
runs in its own isolation scope, continues the trace of the caller, is
recorded as an `http.server` transaction, adds the request to events, counts
towards release health, and has its errors reported:

```julia
HTTP.serve!(Sentry.http_middleware(router), "0.0.0.0", 8080)
```

It has the shape of an Oxygen.jl middleware as well. Server errors (5xx)
mark the transaction as failed; exceptions
are always captured, and rethrown.
"""
function http_middleware(handler; transaction_style::Symbol=:method_and_path)
    return function sentry_http_handler(req)
        client = get_client()
        client === nothing && return handler(req)
        isolation_scope() do iso
            info = request_info(req, client.options)
            add_event_processor(iso, (event, hint) -> begin
                get(event, "request", nothing) === nothing && (event["request"] = info)
                event
            end)
            if client.options.auto_session_tracking
                start_session(; session_mode="request")
            end
            name, source = server_transaction_name(req, transaction_style)
            headers = Dict{String,String}(string(k) => string(v) for (k, v) in req.headers)
            iso.propagation_context = propagation_context_from_incoming(headers)
            txn = _transaction_from_propagation_context(iso.propagation_context;
                                                       name=name, op="http.server", source=source,
                                                       origin="auto.http.julia")
            set_data(txn, "http.request.method", req.method)
            crashed = false
            try
                start_transaction(; transaction=txn) do t
                    response = try
                        handler(req)
                    catch exc
                        crashed = true
                        set_http_status(t, 500)
                        capture_exception(current_exceptions(); handled=false, mechanism_type="http")
                        rethrow()
                    end
                    status = hasproperty(response, :status) ? Int(response.status) : 200
                    set_http_status(t, status)
                    response
                end
            finally
                end_session(; status=crashed ? "crashed" : nothing)
            end
        end
    end
end
