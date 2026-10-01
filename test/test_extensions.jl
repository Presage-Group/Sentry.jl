@testitem "DBInterface extension" setup=[SentryTest] begin
    using SQLite, DBInterface
    SentryTest.init!(; traces_sample_rate=1.0, db_query_source_threshold_ms=0)
    db = Sentry.traced_connection(SQLite.DB(); name="memory")
    @test db isa DBInterface.Connection
    start_transaction(name="queries") do _
        DBInterface.execute(db, "CREATE TABLE t (x INTEGER)")
        stmt = DBInterface.prepare(db, "INSERT INTO t VALUES (?)")
        DBInterface.execute(stmt, (1,))
        DBInterface.executemany(stmt, (x=[2, 3],))
        rows = [r.x for r in DBInterface.execute(db, "SELECT x FROM t ORDER BY x")]
        @test rows == [1, 2, 3]
        @test_throws SQLite.SQLiteException DBInterface.execute(db, "SELECT * FROM missing_table")
        DBInterface.executemultiple(db, "SELECT 1")
        DBInterface.close!(stmt)
    end
    spans = SentryTest.last_transaction()["spans"]
    creates = filter(s -> s["description"] == "CREATE TABLE t (x INTEGER)", spans)
    @test length(creates) == 1
    create = only(creates)
    @test create["op"] == "db"
    @test create["data"]["db.system"] == "sqlite"
    @test create["data"]["db.name"] == "memory"
    @test create["origin"] == "auto.db.julia"
    # With a threshold of 0 every query is attributed to its caller.
    @test endswith(create["data"]["code.filepath"], "test_extensions.jl")
    @test count(s -> s["description"] == "INSERT INTO t VALUES (?)", spans) == 3
    failed = only(filter(s -> s["description"] == "SELECT * FROM missing_table", spans))
    @test failed["status"] == "internal_error"

    capture_message("after queries")
    crumbs = filter(c -> get(c, "category", "") == "query", SentryTest.last_event()["breadcrumbs"]["values"])
    @test crumbs[1]["message"] == "CREATE TABLE t (x INTEGER)"
    @test !haskey(crumbs[2]["data"], "db.params")
    DBInterface.close!(db)

    # Parameters are only recorded with send_default_pii, and the system can be given.
    SentryTest.init!(; send_default_pii=true)
    db = Sentry.traced_connection(SQLite.DB(); system="custom")
    DBInterface.execute(db, "SELECT ?", (42,))
    capture_message("with params")
    crumb = last(SentryTest.last_event()["breadcrumbs"]["values"])
    @test crumb["data"]["db.params"] == [42]
    @test crumb["data"]["db.system"] == "custom"

    # Without a client the query just runs.
    Sentry.close()
    @test Sentry.db_span(() -> :ran, "SELECT 1") === :ran
end

@testitem "Distributed extension" setup=[SentryTest] begin
    using Distributed
    SentryTest.init!()
    @test Sentry.get_integration(get_client(), "DistributedIntegration") !== nothing
    capture_message("with worker context")
    ctx = SentryTest.last_event()["contexts"]["distributed"]
    @test ctx["worker_id"] == 1
    @test ctx["nprocs"] == nprocs()

    # Errors raised on a worker are unwrapped to the original error.
    pid = only(addprocs(1; exeflags=["--project=$(Base.active_project())", "--startup-file=no"]))
    try
        try
            remotecall_fetch(error, pid, "on the worker")
        catch exc
            capture_exception(exc)
        end
        values = SentryTest.last_event()["exception"]["values"]
        @test values[1]["value"] == "on the worker"
        @test values[end]["type"] == "RemoteException"

        # Workers can be set up with the current client's settings.
        Sentry.init_workers([pid]; auto_session_tracking=false)
        # Closures from this test module can not be sent, so evaluate expressions.
        @test Distributed.remotecall_eval(Main, pid, :(Sentry.is_initialized()))
        @test Distributed.remotecall_eval(Main, pid, :(Sentry.get_client().options.release)) == "v1.2.3"
    finally
        rmprocs(pid)
    end

    Sentry.close()
    @test_throws ArgumentError Sentry.init_workers(Int[])
end
