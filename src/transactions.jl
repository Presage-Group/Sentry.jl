
##############################
# * Transactions
#----------------------------

struct InhibitTransaction end

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
    if t === nothing || t === InhibitTransaction()
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
finish_transaction(::InhibitTransaction) = nothing
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

    if transaction === InhibitTransaction()
        return transaction
    elseif transaction === nothing
        if trace_id === nothing
            transaction = InhibitTransaction()
            task_local_storage(:sentry_transaction, transaction)
            return transaction
        elseif sample(main_hub.traces_sampler)
            if trace_id == :auto
                trace_id = generate_uuid4()
            end
            transaction = Transaction(; trace_id = trace_id, kwds...)
        else
            transaction = InhibitTransaction()
            task_local_storage(:sentry_transaction, transaction)
            return transaction
        end
        # TODO: Note that the cases which store an InhibitTransaction in here
        # are bad. They will lock out the start_transaction context manager from
        # taking effect in any future cases. Instead, we should track this and
        # later undo its effects once the outermost transaction is completed
        # (meaning the InhibitTransaction itself should mimic a transaction).
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

set_task_transaction(::Nothing) = nothing
function set_task_transaction(::InhibitTransaction)
    task_local_storage(:sentry_transaction, InhibitTransaction())
end
function set_task_transaction((transaction, ignored, parent_span))
    task_local_storage(:sentry_transaction, transaction)
    task_local_storage(:sentry_parent_span, parent_span)
    nothing
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
