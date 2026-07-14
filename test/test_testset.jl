using Pinax
using Pinax: _approx_numbers, _margin_svg, Check
using Test

# The AbstractTestSet subtype lives in the extension — `Test` is a weakdep, because Pinax is a
# rendering package and `using Pinax` must not drag Test into every user's session. Loading `Test`
# (which you necessarily did, to write `@testset`) loads the extension.
const Ext = Base.get_extension(Pinax, :PinaxTestExt)
const PinaxTestSet = Ext.PinaxTestSet
const _result_data_expr = Ext._result_data_expr
const _check_for = Ext._check_for

# The real entry point is `@testset PinaxTestSet … begin … end` at the ROOT of a runtests.jl, and a
# root PinaxTestSet deliberately `error`s when the suite is red. That cannot run *inside* this
# suite, so the end-to-end case runs in a subprocess — which also pins down the contract that
# matters most: a failing suite still fails the process, report or no report.
@testset "PinaxTestSet" begin
    @testset "off by default — the suite is stock Test" begin
        # Test is a WEAKDEP: `using Pinax` alone must not drag in Test (and Random/Logging/
        # Serialization/InteractiveUtils with it) for the majority who never render a suite.
        @test Ext !== nothing                       # `using Test` above loaded the extension
        @test PinaxTestSet <: Test.AbstractTestSet

        # THE load-bearing claim: with PINAX_TEST_REPORT unset, `testset_type()` is *literally*
        # DefaultTestSet — not a Pinax set that skips rendering. So switching the bridge on cannot
        # regress a passing suite: with it off there is no new code in the test path at all.
        withenv("PINAX_TEST_REPORT" => nothing) do
            @test !Pinax.report_enabled()
            @test Pinax.testset_type() === Test.DefaultTestSet
        end
        for on in ("1", "true", "YES", "on")
            withenv("PINAX_TEST_REPORT" => on) do
                @test Pinax.testset_type() === PinaxTestSet
            end
        end
        withenv("PINAX_TEST_REPORT" => "0") do
            @test Pinax.testset_type() === Test.DefaultTestSet
        end
        withenv("PINAX_TEST_OUT" => "somewhere") do
            @test Pinax.report_out() == "somewhere"
        end
    end

    @testset "numbers survive both verdicts" begin
        # Pass.data is an Expr with evaluated args; Fail.data is a String. The asymmetry is the
        # whole trap: parse only the Expr and every FAILING check silently loses its numbers.
        pass = Test.Pass(
            :test, :(isapprox(a, b)), :(isapprox(1.0, 1.0098; rtol=0.01)), nothing
        )
        @test _approx_numbers(_result_data_expr(pass)) == (1.0, 1.0098, 0.01, :rel)

        fail = Test.Fail(
            :test,
            :(isapprox(a, b)),
            "isapprox(0.5, 0.9; rtol = 0.01)",
            nothing,
            nothing,
            LineNumberNode(1),
            false,
        )
        @test _approx_numbers(_result_data_expr(fail)) == (0.5, 0.9, 0.01, :rel)
    end

    @testset "check carries the margin, not just a verdict" begin
        pass = Test.Pass(:test, :x, :(isapprox(1.0, 1.0098; rtol=0.01)), nothing)
        c = _check_for(pass, 1)
        @test c.pass
        @test c.got == 1.0 && c.want == 1.0098 && c.tol == 0.01 && c.kind === :rel
        @test c.delta / c.tol > 0.9   # passed, but spent 97% of its budget

        # `pass` comes from Julia's own verdict, never from delta <= tol: isapprox mixes atol and
        # rtol in a way a single-kind Check cannot reproduce, and a report that disagrees with the
        # test runner is worse than no report.
        atol_pass = Test.Pass(
            :test, :x, :(isapprox(0.0, 1.0e-9; atol=1.0e-8, rtol=0.01)), nothing
        )
        @test _check_for(atol_pass, 1).pass

        # A non-numeric assertion still becomes a check — every @test must show up somewhere.
        b = _check_for(Test.Pass(:test, :x, :(1 + 1 == 2), nothing), 2)
        @test b.pass && b.got == 1.0
    end

    @testset "atol governs when there is no usable reference" begin
        p = Test.Pass(:test, :x, :(isapprox(0.001, 0.0; atol=0.01)), nothing)
        @test _approx_numbers(_result_data_expr(p)) == (0.001, 0.0, 0.01, :abs)
    end

    @testset "margin figure needs no plotting backend" begin
        checks = [
            Check(:t1, "tight", 1.0, 1.0098, 0.0097, 0.01, :rel, true),
            Check(:t2, "broken", 0.5, 0.9, 0.444, 0.01, :rel, false),
        ]
        svg = _margin_svg(checks, joinpath(mktempdir(), "m.svg"))
        s = read(svg, String)
        @test startswith(s, "<svg")
        @test occursin("#d9534f", s)          # the failing bar is red
        @test occursin("44×", s)              # …and labelled with its real overshoot
        @test occursin("</svg>", s)
    end

    @testset "end-to-end: env-driven, and a red suite still fails the process" begin
        dir = mktempdir()
        write(
            joinpath(dir, "test_demo.jl"),
            """
            @testset "converges" begin
                @test isapprox(-0.10203402715213993, -0.10242223073749557; rtol=0.01)
            end
            @testset "does not" begin
                @test isapprox(0.5, 0.9; rtol=0.01)
            end
            """,
        )
        # Exactly what a real runtests.jl looks like: ONE line, and not one Pinax-specific option —
        # `out` and the on/off switch are the CI's business, not the test code's.
        script = joinpath(dir, "run.jl")
        write(
            script,
            """
            using Pinax, Test
            @pinaxtestset "demo" begin
                @testset "test_demo.jl" begin
                    include($(repr(joinpath(dir, "test_demo.jl"))))
                end
                @testset "noisy fixture" begin
                    @pinaxignore
                    @test true
                end
            end
            """,
        )
        # `addenv`, never `setenv`: setenv REPLACES the environment, which would strip
        # JULIA_DEPOT_PATH/PATH and make the child fail for a reason that has nothing to do with the
        # test — and the OFF assertions below would then pass for entirely the wrong reason.
        function run_suite(env...)
            log = tempname()
            cmd = addenv(
                `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) $script`,
                "PINAX_TEST_OUT" => joinpath(dir, "rep"),
                "PINAX_TEST_REPORT" => nothing,
                env...,
            )
            p = run(pipeline(ignorestatus(cmd); stdout=log, stderr=log))
            return (; ok=success(p), log=read(log, String))
        end

        # ---- report OFF: stock Test, nothing written, and the red suite still fails ----
        r = run_suite()
        @test !r.ok
        @test occursin("Test Summary", r.log)          # it really ran, as a DefaultTestSet…
        @test !occursin("Pinax test report", r.log)    # …and Pinax stayed out of it entirely
        @test !isdir(joinpath(dir, "rep_agent"))

        # ---- report ON ----
        r = run_suite("PINAX_TEST_REPORT" => "1")
        @test !r.ok   # a red suite must still fail CI — a report never turns it green
        @test occursin("Pinax test report", r.log)

        # Pinax writes agent.json/agent.md by hand (no JSON dep), so assert on the text — which is
        # also exactly what a reviewing agent reads.
        md = read(joinpath(dir, "rep_agent", "agent.md"), String)
        @test occursin("1/2 FAIL", md)
        # the failing check kept its real numbers — the entire point of the bridge
        @test occursin("[FAIL]", md)
        @test occursin("got 0.5, want 0.9", md)
        @test occursin("tol 0.01 rel", md)
        # …and the passing one reports how much of its budget it spent, not just "green"
        @test occursin("got -0.10203402715213993, want -0.10242223073749557", md)
        @test occursin(
            "\"verdict\"", read(joinpath(dir, "rep_agent", "agent.json"), String)
        )
        @test isfile(joinpath(dir, "rep_html", "test_demo_jl.html"))
        # @pinaxignore: gone from the document, but it still RAN (and would still fail the suite)
        @test !occursin("noisy fixture", md)
    end
end
