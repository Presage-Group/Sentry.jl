##############################
# * DSN
#----------------------------

"""
A parsed sentry DSN, of the form
`{scheme}://{public_key}[:{secret_key}]@{host}[:{port}]/[{path}/]{project_id}`.
"""
struct Dsn
    scheme::String
    public_key::String
    secret_key::Union{Nothing,String}
    host::String
    port::Union{Nothing,Int}
    path::String
    project_id::String
    org_id::Union{Nothing,String}
end

"""
    parse_dsn(dsn) -> Dsn

Parses a DSN string, throwing an `ArgumentError` when it is malformed.
"""
function parse_dsn(dsn::AbstractString)
    m = match(r"^(?<scheme>[A-Za-z][A-Za-z0-9+.-]*)://(?<userinfo>[^@/]*)@(?<host>\[[^\]]+\]|[^:/]+)(?::(?<port>\d+))?(?<path>/.*)?$", dsn)
    m === nothing && throw(ArgumentError("dsn does not fit correct format"))

    scheme = lowercase(m[:scheme])
    scheme in ("http", "https") || throw(ArgumentError("Unsupported DSN scheme: $scheme"))

    userinfo = split(m[:userinfo], ':'; limit=2)
    public_key = String(userinfo[1])
    isempty(public_key) && throw(ArgumentError("Missing public key in DSN"))
    secret_key = length(userinfo) == 2 && !isempty(userinfo[2]) ? String(userinfo[2]) : nothing

    path = m[:path] === nothing ? "" : String(m[:path])
    parts = split(rstrip(path, '/'), '/')
    project_id = String(pop!(parts))
    (isempty(project_id) || !all(isdigit, project_id)) && throw(ArgumentError("Invalid project id in DSN"))
    prefix = join(parts, "/")

    host = String(m[:host])
    port = m[:port] === nothing ? nothing : parse(Int, m[:port])

    org_match = match(r"^o(\d+)\.", host)
    org_id = org_match === nothing ? nothing : String(org_match[1])

    return Dsn(scheme, public_key, secret_key, host, port, prefix, project_id, org_id)
end

function netloc(d::Dsn)
    d.port === nothing && return d.host
    default = (d.scheme == "https" && d.port == 443) || (d.scheme == "http" && d.port == 80)
    return default ? d.host : "$(d.host):$(d.port)"
end

upstream(d::Dsn) = "$(d.scheme)://$(netloc(d))"
envelope_url(d::Dsn) = "$(upstream(d))$(d.path)/api/$(d.project_id)/envelope/"

function auth_header(d::Dsn, client::AbstractString)
    parts = ["sentry_key=$(d.public_key)", "sentry_version=7", "sentry_client=$client"]
    d.secret_key === nothing || push!(parts, "sentry_secret=$(d.secret_key)")
    return "Sentry " * join(parts, ", ")
end

Base.print(io::IO, d::Dsn) = print(io, d.scheme, "://", d.public_key,
                                   d.secret_key === nothing ? "" : ":" * d.secret_key,
                                   "@", netloc(d), d.path, "/", d.project_id)

@testitem "DSN parsing" begin
    d = Sentry.parse_dsn("https://abcdef1234567890@a12345.us.sentry.io/1234567890123456789")
    @test d.public_key == "abcdef1234567890"
    @test d.project_id == "1234567890123456789"
    @test Sentry.upstream(d) == "https://a12345.us.sentry.io"
    @test Sentry.envelope_url(d) == "https://a12345.us.sentry.io/api/1234567890123456789/envelope/"
    @test d.org_id === nothing
    @test d.secret_key === nothing

    d = Sentry.parse_dsn("https://key:secret@o42.ingest.sentry.io:8443/prefix/path/7")
    @test d.secret_key == "secret"
    @test d.org_id == "42"
    @test d.port == 8443
    @test d.path == "/prefix/path"
    @test Sentry.envelope_url(d) == "https://o42.ingest.sentry.io:8443/prefix/path/api/7/envelope/"
    @test occursin("sentry_secret=secret", Sentry.auth_header(d, "x/1"))
    @test string(d) == "https://key:secret@o42.ingest.sentry.io:8443/prefix/path/7"

    # Default ports are left out of the url.
    @test Sentry.netloc(Sentry.parse_dsn("https://k@host:443/1")) == "host"
    @test Sentry.netloc(Sentry.parse_dsn("http://k@host:80/1")) == "host"
    @test Sentry.netloc(Sentry.parse_dsn("http://k@[::1]:9000/1")) == "[::1]:9000"

    @test_throws ArgumentError Sentry.parse_dsn("https://0000000000000000000000000000000000000000.ingest.sentry.io/0000000")
    @test_throws ArgumentError Sentry.parse_dsn("ftp://k@host/1")
    @test_throws ArgumentError Sentry.parse_dsn("https://@host/1")
    @test_throws ArgumentError Sentry.parse_dsn("https://k@host/abc")
    @test_throws ArgumentError Sentry.parse_dsn("https://k@host/")
end
