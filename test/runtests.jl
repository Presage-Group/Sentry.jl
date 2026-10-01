using TestItemRunner

# Set SENTRY_TEST_FILTER to run only the test items whose name or file contains it.
const pattern = get(ENV, "SENTRY_TEST_FILTER", "")

@run_package_tests filter = ti -> isempty(pattern) || occursin(pattern, ti.name) || occursin(pattern, ti.filename)
