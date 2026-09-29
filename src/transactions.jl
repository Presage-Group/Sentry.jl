
##############################
# * Transactions
#----------------------------

# Mimics a transaction, so that it is cleared from the task local storage once
# the outermost inhibited transaction finishes. Otherwise a single declined
# sample would lock out tracing for the remaining life of the task.
mutable struct InhibitTransaction
    num_open_spans::Int
end
InhibitTransaction() = InhibitTransaction(0)

function start_transaction(func ; kwds...)
    previous = get(task_local_storage(), :sentry_transaction, nothing)
    t = start_transaction(; kwds...)

    try
        return func(t)
    finally
        finish_transaction(t, previous)
    end
end

function start_transaction(; name="", force_new=(name!=""), trace_id=:auto, parent_span_id=nothing, span_kwds...)
    # trace_id === nothing && return nothing
    # Need to pass through nothings so that we can hit an InhibitTransaction
    t = get_transaction(; name, trace_id, force_new)
    if t === nothing || t isa InhibitTransaction
        return t
    end

    transaction, parent_span = t

    if parent_span !== nothing
        parent_span_id = parent_span.span_id
    end

    span = Span(; parent_span_id=parent_span_id, span_kwds...)
    task_local_storage(:sentry_parent_span, span)
    if transaction.root_span === nothing
        transaction.root_span = span
    end
    transaction.num_open_spans += 1

    (; transaction, parent_span, span)
end

function finish_transaction(current, previous)
    finish_transaction(current)
    task_local_storage(:sentry_transaction, previous)
end
finish_transaction(::Nothing) = nothing
function finish_transaction(inhibit::InhibitTransaction)
    inhibit.num_open_spans -= 1
    if inhibit.num_open_spans <= 0
        task_local_storage(:sentry_transaction, nothing)
    end
    nothing
end

@testitem "inhibited transactions" setup=[FakeSentry] begin
    FakeSentry.reset!()

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

    parsed, _ = FakeSentry.next_envelope()
    @test parsed[3]["transaction"] == "after"
end
function finish_transaction((transaction, parent_span, span))
    complete(span)
    if transaction.root_span !== span
        push!(transaction.spans, span)
    end
    task_local_storage(:sentry_parent_span, parent_span)
    transaction.num_open_spans -= 1
    if transaction.num_open_spans == 0
        complete(transaction)
    end
end



function get_transaction(; force_new=false, trace_id=:auto, kwds...)
    main_hub.initialised || return nothing

    if force_new
        task_local_storage(:sentry_transaction, nothing)
        transaction = nothing
    else
        transaction = get(task_local_storage(), :sentry_transaction, nothing)
    end

    if transaction isa InhibitTransaction
        transaction.num_open_spans += 1
        return transaction
    elseif transaction === nothing
        if trace_id === nothing
            transaction = InhibitTransaction(1)
            task_local_storage(:sentry_transaction, transaction)
            return transaction
        elseif sample(main_hub.traces_sampler)
            if trace_id == :auto
                trace_id = generate_uuid4()
            end
            transaction = Transaction(; trace_id = trace_id, kwds...)
        else
            transaction = InhibitTransaction(1)
            task_local_storage(:sentry_transaction, transaction)
            return transaction
        end
        task_local_storage(:sentry_transaction, transaction)
        return (; transaction, parent_span=nothing)
    else
        transaction::Transaction
        if trace_id != :auto
            transaction.trace_id != trace_id && main_hub.debug && @warn "Trying to start a transaction with a new trace id, inside of an old transaction"
        end
        parent_span = task_local_storage(:sentry_parent_span)::Span
        return (; transaction, parent_span)
    end
end

@testitem "a declined sample inhibits the transaction" setup=[FakeSentry] begin
    old_sampler = Sentry.main_hub.traces_sampler
    Sentry.main_hub.traces_sampler = Sentry.NoSamples()
    try
        # In a task of its own, so the inhibition cannot leak into other test items.
        inhibited = fetch(@async start_transaction(name="declined"))
        @test inhibited isa Sentry.InhibitTransaction
        @test inhibited.num_open_spans == 1
    finally
        Sentry.main_hub.traces_sampler = old_sampler
    end
end

@testitem "a new trace id inside an open transaction warns" setup=[FakeSentry] begin
    old_debug = Sentry.main_hub.debug
    Sentry.main_hub.debug = true
    try
        start_transaction(name="outer") do _
            @test_warn "new trace id" start_transaction(trace_id="0"^32) do _ end
        end
    finally
        Sentry.main_hub.debug = old_debug
    end
end

set_task_transaction(::Nothing) = nothing
function set_task_transaction(::InhibitTransaction)
    # Starts at 1 with no matching finish, so that the parent's sampling
    # decision holds for the whole life of this task.
    task_local_storage(:sentry_transaction, InhibitTransaction(1))
end
function set_task_transaction((transaction, ignored, parent_span))
    task_local_storage(:sentry_transaction, transaction)
    task_local_storage(:sentry_parent_span, parent_span)
    nothing
end

@testitem "set_task_transaction" setup=[FakeSentry] begin
    @test set_task_transaction(nothing) === nothing

    # An inhibited parent has to stop the new task from tracing as well. The
    # results are collected because the task has its own testset state.
    inherited = fetch(@async begin
        set_task_transaction(Sentry.InhibitTransaction(3))
        task_local_storage(:sentry_transaction)
    end)
    @test inherited isa Sentry.InhibitTransaction
    # One open span with no matching finish, so it lasts the life of the task.
    @test inherited.num_open_spans == 1

    # A traced parent hands the new task its current span to hang spans off.
    start_transaction(name="outer") do current
        inherited = fetch(@async begin
            set_task_transaction(current)
            (task_local_storage(:sentry_transaction), task_local_storage(:sentry_parent_span))
        end)
        @test inherited[1] === current.transaction
        @test inherited[2] === current.span
    end
end


function complete(transaction::Transaction)
    main_hub.initialised || error("Can't get here without sentry being initialised")
    capture_event(transaction)
    nothing
end

function complete(span::Span)
    if span.timestamp !== nothing
        main_hub.debug && @warn "Span attempted to be completed twice"
    else
        span.timestamp = nowstr()
    end
    nothing
end

@testitem "Span completion" begin
    span = Sentry.Span()
    @test span.timestamp === nothing
    Sentry.complete(span)
    @test span.timestamp isa String

    old_debug = Sentry.main_hub.debug
    Sentry.main_hub.debug = true
    @test_warn "Span attempted to be completed twice" Sentry.complete(span)
    Sentry.main_hub.debug = old_debug
end

@testitem "Transaction lifecycle" begin
    old_init = Sentry.main_hub.initialised
    old_sampler = Sentry.main_hub.traces_sampler
    Sentry.main_hub.initialised = true
    Sentry.main_hub.traces_sampler = Sentry.RatioSampler(1.0)
    delete!(task_local_storage(), :sentry_transaction)

    @test Sentry.finish_transaction(nothing) === nothing
    @test Sentry.finish_transaction(Sentry.InhibitTransaction()) === nothing

    Sentry.main_hub.initialised = false
    @test Sentry.start_transaction(name="uninit") === nothing
    Sentry.main_hub.initialised = true

    result = start_transaction(name="test_tx") do t
        @test t.transaction.name == "test_tx"
        @test t.span === t.transaction.root_span
        @test t.transaction.num_open_spans == 1
        :done
    end
    @test result == :done

    Sentry.main_hub.initialised = old_init
    Sentry.main_hub.traces_sampler = old_sampler
end

@testitem "Nested spans" begin
    old_init = Sentry.main_hub.initialised
    old_sampler = Sentry.main_hub.traces_sampler
    Sentry.main_hub.initialised = true
    Sentry.main_hub.traces_sampler = Sentry.RatioSampler(1.0)
    delete!(task_local_storage(), :sentry_transaction)
    delete!(task_local_storage(), :sentry_parent_span)

    start_transaction(name="outer") do outer
        start_transaction(op="child") do inner
            @test inner.transaction === outer.transaction
            @test inner.span.parent_span_id == outer.span.span_id
            @test inner.transaction.num_open_spans == 2
        end
        @test outer.transaction.num_open_spans == 1
        @test length(outer.transaction.spans) == 1
    end

    Sentry.main_hub.initialised = old_init
    Sentry.main_hub.traces_sampler = old_sampler
end

@testitem "transaction envelope" setup=[FakeSentry] begin
    FakeSentry.reset!()

    start_transaction(name="job", op="task") do _
        start_transaction(op="child", description="inner") do _ end
    end

    parsed, items = FakeSentry.next_envelope()
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
