##############################
# * Event scrubber
#----------------------------

const DEFAULT_DENYLIST = [
    # stolen from relay
    "password", "passwd", "secret", "api_key", "apikey", "auth", "credentials",
    "mysql_pwd", "privatekey", "private_key", "token", "session",
    # web frameworks
    "csrftoken", "sessionid", "x_csrftoken", "x_forwarded_for", "set_cookie",
    "cookie", "authorization", "proxy-authorization", "x_api_key",
    "x-csrftoken", "set-cookie", "x-api-key",
    # other common names used in the wild
    "connect.sid", "csrf_token", "csrf", "_csrf", "_csrf_token", "PHPSESSID",
    "_session", "user_session", "_xsrf", "XSRF-TOKEN",
]

const DEFAULT_PII_DENYLIST = ["x_forwarded_for", "x_real_ip", "x-forwarded-for", "x-real-ip",
                              "ip_address", "remote_addr"]

const FILTERED = "[Filtered]"

"""
    EventScrubber(; denylist=DEFAULT_DENYLIST, recursive=false, send_default_pii=false, pii_denylist=DEFAULT_PII_DENYLIST)

Removes sensitive values from events before they are sent: any key in the
denylist (compared case-insensitively) in the request, extra data, user,
breadcrumb data and span data has its value replaced by `"[Filtered]"`. When
`send_default_pii` is false, the `pii_denylist` is scrubbed as well.

Pass one as `event_scrubber` to `init` to customize this.
"""
struct EventScrubber
    denylist::Set{String}
    recursive::Bool
end

function EventScrubber(; denylist=DEFAULT_DENYLIST, recursive::Bool=false,
                       send_default_pii::Bool=false, pii_denylist=DEFAULT_PII_DENYLIST)
    keys = String[lowercase(string(k)) for k in denylist]
    send_default_pii || append!(keys, lowercase.(string.(pii_denylist)))
    return EventScrubber(Set(keys), recursive)
end

function scrub_dict!(s::EventScrubber, d)
    d isa AbstractDict || return nothing
    for k in collect(keys(d))
        if k isa AbstractString && lowercase(k) in s.denylist
            d[k] = FILTERED
        elseif s.recursive
            scrub_dict!(s, d[k])
            scrub_list!(s, d[k])
        end
    end
    return nothing
end

function scrub_list!(s::EventScrubber, l)
    l isa AbstractVector || return nothing
    for v in l
        scrub_dict!(s, v)
        scrub_list!(s, v)
    end
    return nothing
end

function scrub_event!(s::EventScrubber, event::AbstractDict)
    @ignore_exception begin
        req = get(event, "request", nothing)
        if req isa AbstractDict
            scrub_dict!(s, get(req, "headers", nothing))
            scrub_dict!(s, get(req, "cookies", nothing))
            data = get(req, "data", nothing)
            scrub_dict!(s, data)
            scrub_list!(s, data)
        end
    end
    @ignore_exception scrub_dict!(s, get(event, "extra", nothing))
    @ignore_exception begin
        user = get(event, "user", nothing)
        if user isa AbstractDict
            "ip_address" in s.denylist && delete!(user, "ip_address")
            scrub_dict!(s, user)
        end
    end
    @ignore_exception begin
        crumbs = get(event, "breadcrumbs", nothing)
        if crumbs isa AbstractDict
            for crumb in get(crumbs, "values", ())
                crumb isa AbstractDict && scrub_dict!(s, get(crumb, "data", nothing))
            end
        end
    end
    @ignore_exception for span in get(event, "spans", ())
        span isa AbstractDict && scrub_dict!(s, get(span, "data", nothing))
    end
    return event
end

# A user supplied scrubber may be any callable taking the event.
scrub_event!(f, event::AbstractDict) = (f(event); event)

@testitem "event scrubber" begin
    s = Sentry.EventScrubber()
    event = Dict{String,Any}(
        "request" => Dict{String,Any}("headers" => Dict{String,Any}("Authorization" => "Bearer x", "Accept" => "*/*"),
                                      "cookies" => Dict{String,Any}("sessionid" => "abc"),
                                      "data" => Any[Dict{String,Any}("password" => "hunter2")]),
        "extra" => Dict{String,Any}("api_key" => "k", "fine" => 1, "nested" => Dict{String,Any}("token" => "t")),
        "user" => Dict{String,Any}("id" => 1, "ip_address" => "1.2.3.4"),
        "breadcrumbs" => Dict{String,Any}("values" => Any[Dict{String,Any}("data" => Dict{String,Any}("secret" => 1))]),
        "spans" => Any[Dict{String,Any}("data" => Dict{String,Any}("credentials" => "c"))],
    )
    Sentry.scrub_event!(s, event)
    @test event["request"]["headers"]["Authorization"] == "[Filtered]"
    @test event["request"]["headers"]["Accept"] == "*/*"
    @test event["request"]["cookies"]["sessionid"] == "[Filtered]"
    @test event["request"]["data"][1]["password"] == "[Filtered]"
    @test event["extra"]["api_key"] == "[Filtered]"
    @test event["extra"]["fine"] == 1
    # Not recursive by default.
    @test event["extra"]["nested"]["token"] == "t"
    @test !haskey(event["user"], "ip_address")
    @test event["breadcrumbs"]["values"][1]["data"]["secret"] == "[Filtered]"
    @test event["spans"][1]["data"]["credentials"] == "[Filtered]"

    r = Sentry.EventScrubber(; recursive=true, send_default_pii=true)
    event = Dict{String,Any}("extra" => Dict{String,Any}("nested" => Dict{String,Any}("token" => "t"),
                                                          "list" => Any[Dict{String,Any}("auth" => 1)]),
                             "user" => Dict{String,Any}("ip_address" => "1.2.3.4"))
    Sentry.scrub_event!(r, event)
    @test event["extra"]["nested"]["token"] == "[Filtered]"
    @test event["extra"]["list"][1]["auth"] == "[Filtered]"
    # With send_default_pii the ip address is kept.
    @test event["user"]["ip_address"] == "1.2.3.4"

    # A plain function works as a scrubber too.
    ev = Sentry.scrub_event!(e -> (e["x"] = 1), Dict{String,Any}())
    @test ev["x"] == 1
end
