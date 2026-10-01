##############################
# * Database spans
#----------------------------

"""
Adds the location of the code that started a slow span (the first frame that
belongs to the application) as `code.*` data, so that sentry can point at it.
"""
function add_code_source!(span::Span, options)
    frames = try
        stacktrace(backtrace())
    catch
        return nothing # COV_EXCL_LINE
    end
    for f in frames
        mod = frame_module(f)
        mod === nothing && continue
        (mod == "Sentry" || startswith(mod, "Sentry")) && continue
        path = frame_abs_path(string(f.file))
        is_in_app(mod, path, options) || continue
        set_data(span, "code.lineno", f.line)
        set_data(span, "code.namespace", mod)
        set_data(span, "code.function", string(f.func))
        set_data(span, "code.filepath", something(path, string(f.file)))
        return nothing
    end
    return nothing # COV_EXCL_LINE
end

"""
    db_span(f, query; system=nothing, name=nothing, op="db", params=nothing)

Runs `f()` as a database span for `query`, recording a breadcrumb for it. Used
by the database integrations; call it to instrument other database clients.
`system` is the kind of database (such as `"postgresql"` or `"sqlite"`), and
`name` the database's name.
"""
function db_span(f, query; system=nothing, name=nothing, op="db", params=nothing, origin="auto.db.julia")
    client = get_client()
    client === nothing && return f()
    q = strip_string(string(query), 2048)
    return start_span(; op=op, name=q, origin=origin) do span
        system === nothing || set_data(span, "db.system", string(system))
        name === nothing || set_data(span, "db.name", string(name))
        t0 = time()
        result = try
            f()
        catch
            set_status(span, "internal_error")
            rethrow()
        finally
            data = Dict{String,Any}()
            system === nothing || (data["db.system"] = string(system))
            if params !== nothing && client.options.send_default_pii
                data["db.params"] = params
            end
            add_breadcrumb(; category="query", message=q, data=data)
        end
        if client.options.enable_db_query_source && (time() - t0) * 1000 >= client.options.db_query_source_threshold_ms
            add_code_source!(span, client.options)
        end
        result
    end
end

"""
    traced_connection(conn; system=nothing, name=nothing)

Wraps a `DBInterface.Connection` (from SQLite.jl, LibPQ.jl, MySQL.jl, ...)
so that every query made through it is recorded as a `db` span and a
breadcrumb. The wrapper is itself a `DBInterface.Connection`. Available once
DBInterface is loaded.
"""
function traced_connection end

"""
    init_workers(pids=workers(); kwargs...)

Loads and initialises Sentry on Distributed.jl worker processes, with the DSN,
release, environment and sample rates of the current client, overridden by
`kwargs`. Available once Distributed is loaded.
"""
function init_workers end
