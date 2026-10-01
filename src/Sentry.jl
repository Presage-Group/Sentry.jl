module Sentry

using CodecZlib
using Dates
using HTTP
using JSON
using Logging
using PkgVersion
using Printf
using Profile
using Random
using ScopedValues
using TestItems
using URIs
using UUIDs

# These shadow the Base functions of the same name inside Sentry, so that
# `Sentry.flush()` and `Sentry.close()` can mirror the other SDKs. Declared
# before anything else so that no code in the module binds the Base ones.
function flush end
function close end

const VERSION = @PkgVersion.Version 0

include("utils.jl")
include("dsn.jl")
include("serializer.jl")
include("scrubber.jl")
include("options.jl")
include("envelope.jl")
include("transport.jl")
include("batcher.jl")
include("session.jl")
include("monitor.jl")
include("scope.jl")
include("stacktrace.jl")
include("tracing.jl")
include("client.jl")
include("integrations.jl")
include("logging.jl")
include("api.jl")
include("crons.jl")
include("profiler.jl")
include("http.jl")
include("db.jl")

export init,
    capture_message,
    capture_exception,
    capture_event,
    capture_checkin,
    add_breadcrumb,
    set_tag,
    set_tags,
    set_extra,
    set_context,
    set_user,
    set_level,
    set_fingerprint,
    add_attachment,
    Attachment,
    last_event_id,
    is_initialized,
    get_client,
    start_transaction,
    finish_transaction,
    start_span,
    finish_span,
    set_task_transaction,
    continue_trace,
    get_current_span,
    get_traceparent,
    get_baggage,
    set_transaction_name,
    set_measurement,
    new_scope,
    isolation_scope,
    get_current_scope,
    get_isolation_scope,
    get_global_scope,
    start_session,
    end_session,
    add_feature_flag,
    Info,
    Warn,
    Error

function __init__()
    _init_scopes!()
    return nothing
end

end
