##############################
# * Stack frames
#----------------------------

const SOURCE_CONTEXT_LINES = 5
const _SOURCE_CACHE = Dict{String,Union{Nothing,Vector{String}}}()
const _SOURCE_CACHE_LOCK = ReentrantLock()
const _SOURCE_CACHE_MAX = 64

function source_lines(path::AbstractString)
    @lock _SOURCE_CACHE_LOCK begin
        haskey(_SOURCE_CACHE, path) && return _SOURCE_CACHE[path]
    end
    lines = try
        isfile(path) ? readlines(path) : nothing
    catch
        nothing
    end
    @lock _SOURCE_CACHE_LOCK begin
        length(_SOURCE_CACHE) >= _SOURCE_CACHE_MAX && empty!(_SOURCE_CACHE)
        _SOURCE_CACHE[path] = lines
    end
    return lines
end

function add_source_context!(frame::Dict{String,Any}, path, lineno::Integer; max_length::Integer=DEFAULT_MAX_VALUE_LENGTH)
    (path === nothing || lineno <= 0) && return frame
    lines = source_lines(path)
    (lines === nothing || lineno > length(lines)) && return frame
    trim(s) = strip_string(s, min(max_length, 512))
    frame["pre_context"] = [trim(l) for l in lines[max(1, lineno - SOURCE_CONTEXT_LINES):lineno-1]]
    frame["context_line"] = trim(lines[lineno])
    frame["post_context"] = [trim(l) for l in lines[lineno+1:min(length(lines), lineno + SOURCE_CONTEXT_LINES)]]
    return frame
end

"""The full path of a frame's file, resolving the relative paths of Base."""
function frame_abs_path(file::AbstractString)
    (isempty(file) || startswith(file, "REPL[") || file == "none") && return nothing
    try
        p = Base.find_source_file(file)
        p === nothing || return p
    catch # COV_EXCL_LINE
    end
    return isabspath(file) ? file : nothing
end

function frame_module(f::Base.StackTraces.StackFrame)
    try
        m = parentmodule(f)
        m === nothing && return nothing
        return string(m)
    catch
        return nothing # COV_EXCL_LINE
    end
end

const _EXTERNAL_MODULES = ("Base", "Core", "Main.Base")

function _is_external_path(path::AbstractString)
    p = replace(path, '\\' => '/')
    for depot in DEPOT_PATH
        d = replace(depot, '\\' => '/')
        for sub in ("packages", "artifacts", "compiled", "juliaup")
            startswith(p, d * "/" * sub * "/") && return true
        end
    end
    share = replace(normpath(joinpath(Sys.BINDIR, "..", "share", "julia")), '\\' => '/')
    startswith(p, share) && return true
    startswith(p, replace(Sys.STDLIB, '\\' => '/')) && return true
    return false
end

"""
Whether a frame belongs to the application: frames of Base, Core, the standard
library and installed packages do not; `in_app_include` and `in_app_exclude`
(module name prefixes) override that.
"""
function is_in_app(mod::Union{Nothing,String}, abs_path::Union{Nothing,String}, options)
    if mod !== nothing && options !== nothing
        any(p -> mod == p || startswith(mod, p * "."), options.in_app_exclude) && return false
        any(p -> mod == p || startswith(mod, p * "."), options.in_app_include) && return true
    end
    if mod !== nothing
        root = split(mod, '.')[1]
        root in ("Base", "Core") && return false
        (mod == "Sentry" || startswith(mod, "Sentry.")) && return false
    end
    abs_path === nothing && return mod === nothing || !startswith(mod, "Base")
    _is_external_path(abs_path) && return false
    return true
end

function frame_to_dict(f::Base.StackTraces.StackFrame, options)
    file = string(f.file)
    abs_path = frame_abs_path(file)
    mod = frame_module(f)
    d = Dict{String,Any}(
        "function" => string(f.func),
        "lineno" => f.line,
        "in_app" => is_in_app(mod, abs_path, options),
    )
    root = options === nothing ? nothing : options.project_root
    d["filename"] = if abs_path !== nothing && root !== nothing && startswith(abs_path, root * Base.Filesystem.path_separator)
        relpath(abs_path, root)
    else
        file
    end
    abs_path === nothing || (d["abs_path"] = abs_path)
    mod === nothing || (d["module"] = mod)
    f.inlined && (d["vars"] = Dict{String,Any}("inlined" => true))
    if abs_path !== nothing && (options === nothing || options.include_source_context)
        add_source_context!(d, abs_path, f.line; max_length=options === nothing ? DEFAULT_MAX_VALUE_LENGTH : options.max_value_length)
    end
    return d
end

"""
Converts a backtrace into sentry frames, ordered from the outermost call to
the innermost one as sentry expects.
"""
function frames_from_backtrace(bt, options; drop_sentry::Bool=false)
    stack = if bt isa AbstractVector{Base.StackTraces.StackFrame}
        bt
    elseif bt isa AbstractVector && !isempty(bt) && first(bt) isa Tuple
        # A CapturedException's processed backtrace.
        [first(x) for x in bt]
    else
        try
            Base.scrub_repl_backtrace(bt)
        catch
            stacktrace(bt)
        end
    end
    if drop_sentry
        # Leave out the frames of the SDK itself at the innermost end.
        i = findfirst(f -> frame_module(f) != "Sentry", stack)
        stack = i === nothing ? stack : stack[i:end]
    end
    frames = [frame_to_dict(f, options) for f in stack]
    reverse!(frames)
    maxf = options === nothing ? DEFAULT_MAX_STACK_FRAMES : options.max_stack_frames
    length(frames) > maxf && (frames = frames[end-maxf+1:end])
    return frames
end

"""The stack trace of the caller, for `attach_stacktrace`."""
current_stacktrace(options) = Dict{String,Any}("frames" => frames_from_backtrace(stacktrace(backtrace()), options; drop_sentry=true))

##############################
# * Exceptions
#----------------------------

exception_type_name(exc) = string(nameof(typeof(exc)))
exception_module(exc) = string(parentmodule(typeof(exc)))

function exception_value(exc, options)
    s = try
        sprint(showerror, exc; context=:limit => true)
    catch
        safe_repr(exc)
    end
    # showerror usually starts with the type, which sentry shows separately.
    prefix = exception_type_name(exc) * ": "
    startswith(s, prefix) && (s = s[length(prefix)+1:end])
    return strip_string(s, options === nothing ? DEFAULT_MAX_VALUE_LENGTH : options.max_value_length)
end

"""
A node of the exception tree: an exception, its frames, and the exceptions
that caused it (for errors raised while handling another, and for the errors
wrapped by a task failure or a composite).
"""
struct ExceptionNode
    exc::Any
    frames::Vector{Dict{String,Any}}
    children::Vector{ExceptionNode}
    is_group::Bool
end

function _node(exc, bt, options)
    children = ExceptionNode[]
    is_group = false
    name = nameof(typeof(exc))
    if exc isa TaskFailedException
        try
            for (e, b) in current_exceptions(exc.task)
                push!(children, _node(e, b, options))
            end
        catch # COV_EXCL_LINE
        end
    elseif exc isa CompositeException
        is_group = true
        for e in exc.exceptions
            push!(children, _node(e, e isa CapturedException ? e.processed_bt : nothing, options))
        end
    elseif exc isa CapturedException
        return _node(exc.ex, exc.processed_bt, options)
    elseif exc isa LoadError
        # The error of a script or `include`, rather than the wrapper.
        return _node(exc.error, bt, options)
    elseif name == :RemoteException && hasproperty(exc, :captured)
        push!(children, _node(exc.captured, nothing, options))
    end
    frames = bt === nothing ? Dict{String,Any}[] : frames_from_backtrace(bt, options)
    return ExceptionNode(exc, frames, children, is_group)
end

"""
    exceptions_from_error(stack, options; handled=true, mechanism_type="generic")

Converts an exception stack (pairs of an exception and its backtrace, oldest
first, as given by `current_exceptions()`) into the `values` of sentry's
exception interface.
"""
function exceptions_from_error(stack, options; handled::Bool=true, mechanism_type::String="generic")
    nodes = ExceptionNode[]
    for (exc, bt) in stack
        push!(nodes, _node(exc, bt, options))
    end
    isempty(nodes) && return Dict{String,Any}[]

    # Exceptions thrown while handling another are chained: each has the one
    # it was handling as its cause. Build ids from the newest (the error being
    # reported) down, so that it gets id 0.
    values = Dict{String,Any}[]
    counter = Ref(0)
    function emit(node::ExceptionNode, parent_id)
        id = counter[]
        counter[] += 1
        # Causes come before the exception they caused.
        for child in node.children
            emit(child, id)
        end
        v = Dict{String,Any}(
            "type" => exception_type_name(node.exc),
            "module" => exception_module(node.exc),
            "value" => exception_value(node.exc, options),
            "mechanism" => Dict{String,Any}("type" => mechanism_type, "handled" => handled,
                                             "exception_id" => id),
        )
        parent_id === nothing || (v["mechanism"]["parent_id"] = parent_id)
        node.is_group && (v["mechanism"]["is_exception_group"] = true)
        isempty(node.frames) || (v["stacktrace"] = Dict{String,Any}("frames" => node.frames))
        push!(values, v)
        return nothing
    end

    # The chain from the exception stack: the newest is the root of the tree,
    # and each older one hangs off the next newer.
    chain = reverse(nodes)
    root = chain[1]
    for i in length(chain):-1:2
        # Attach older exceptions as causes of the newer ones.
        push!(chain[i-1].children, chain[i])
    end
    emit(root, nothing)

    if length(values) == 1
        # A single exception needs no ids.
        delete!(values[1]["mechanism"], "exception_id")
    end
    return values
end

"""
    event_from_exception(stack, options; handled=true, mechanism_type="generic")

Builds an error event and its hint from an exception stack.
"""
function event_from_exception(stack, options; handled::Bool=true, mechanism_type::String="generic")
    values = exceptions_from_error(stack, options; handled, mechanism_type)
    event = Dict{String,Any}("level" => "error", "exception" => Dict{String,Any}("values" => values))
    last_exc = isempty(stack) ? nothing : last(stack)[1]
    hint = Dict{String,Any}("exception" => last_exc, "exception_stack" => stack)
    return event, hint
end

"""All frames of all exceptions in an event."""
function iter_event_frames(event::AbstractDict)
    out = Dict{String,Any}[]
    exc = get(event, "exception", nothing)
    if exc isa AbstractDict
        for v in get(exc, "values", ())
            st = get(v, "stacktrace", nothing)
            st isa AbstractDict && append!(out, get(st, "frames", ()))
        end
    end
    threads = get(event, "threads", nothing)
    if threads isa AbstractDict
        for t in get(threads, "values", ())
            st = get(t, "stacktrace", nothing)
            st isa AbstractDict && append!(out, get(st, "frames", ()))
        end
    end
    return out
end
