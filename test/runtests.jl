using Sentry
using Test

Sentry.init()

@testset "Sentry.jl" begin
    @test Sentry.parse_dsn("fake") == (upstream = "", project_id = "", public_key = "")
    @test_throws ErrorException Sentry.parse_dsn("https://0000000000000000000000000000000000000000.ingest.sentry.io/0000000")
    @test Sentry.parse_dsn("https://abcdef1234567890@a12345.us.sentry.io/1234567890123456789") == (upstream = "https://a12345.us.sentry.io", project_id = "1234567890123456789", public_key = "abcdef1234567890")

    set_tag("test", "message")
    @test Sentry.global_tags["test"] == "message"
    @test_warn "A 'release' tag is ignored by sentry upstream. You should instead set the release in the `init` call" set_tag("release", "v1.0")
    @test Sentry.global_tags["release"] == "v1.0"

    @test length(generate_uuid4()) == 32
end
