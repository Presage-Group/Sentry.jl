using Documenter
using Sentry

makedocs(;
    modules=[Sentry],
    sitename="Sentry.jl",
    format=Documenter.HTML(; prettyurls=get(ENV, "CI", "false") == "true"),
    pages=[
        "Home" => "index.md",
        "Configuration" => "configuration.md",
        "Enriching events" => "enriching.md",
        "Tracing" => "tracing.md",
        "Logs and metrics" => "logs_metrics.md",
        "Release health, crons and flags" => "health.md",
        "Profiling" => "profiling.md",
        "Integrations" => "integrations.md",
        "Parity with sentry-python" => "parity.md",
        "Migrating from 0.2" => "migration.md",
        "API reference" => "api.md",
    ],
    checkdocs=:none,
    warnonly=[:missing_docs, :cross_references],
)

deploydocs(; repo="github.com/Presage-Group/Sentry.jl.git", push_preview=true)
