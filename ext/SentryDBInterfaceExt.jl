module SentryDBInterfaceExt

using Sentry
using DBInterface

"""A connection whose queries are recorded as sentry spans."""
struct TracedConnection{C<:DBInterface.Connection} <: DBInterface.Connection
    conn::C
    system::Union{Nothing,String}
    name::Union{Nothing,String}
end

struct TracedStatement{S} <: DBInterface.Statement
    stmt::S
    conn::TracedConnection
    sql::String
end

# The database system of the connection types that are commonly used.
function guess_system(conn)
    name = lowercase(string(nameof(parentmodule(typeof(conn)))))
    name == "sqlite" && return "sqlite"
    name == "libpq" && return "postgresql"
    name == "mysql" && return "mysql"
    name == "odbc" && return "odbc"
    name == "duckdb" && return "duckdb"
    return name
end

function Sentry.traced_connection(conn::DBInterface.Connection; system=nothing, name=nothing)
    return TracedConnection(conn, system === nothing ? guess_system(conn) : string(system),
                            name === nothing ? nothing : string(name))
end

DBInterface.prepare(c::TracedConnection, sql::AbstractString) =
    TracedStatement(DBInterface.prepare(c.conn, sql), c, String(sql))

function DBInterface.execute(s::TracedStatement, params)
    return Sentry.db_span(s.sql; system=s.conn.system, name=s.conn.name, params=params) do
        DBInterface.execute(s.stmt, params)
    end
end

function DBInterface.executemultiple(s::TracedStatement, params)
    return Sentry.db_span(s.sql; system=s.conn.system, name=s.conn.name, params=params) do
        DBInterface.executemultiple(s.stmt, params)
    end
end

# Queries run on the connection directly include preparing them in the span,
# since that is where many errors (such as a missing table) are raised.
function DBInterface.execute(c::TracedConnection, sql::AbstractString, params)
    return Sentry.db_span(sql; system=c.system, name=c.name, params=params) do
        DBInterface.execute(c.conn, sql, params)
    end
end

function DBInterface.executemultiple(c::TracedConnection, sql::AbstractString, params)
    return Sentry.db_span(sql; system=c.system, name=c.name, params=params) do
        DBInterface.executemultiple(c.conn, sql, params)
    end
end

DBInterface.getconnection(s::TracedStatement) = s.conn
DBInterface.close!(c::TracedConnection) = DBInterface.close!(c.conn)
DBInterface.close!(s::TracedStatement) = DBInterface.close!(s.stmt)
DBInterface.transaction(f, c::TracedConnection) = DBInterface.transaction(f, c.conn)

end
