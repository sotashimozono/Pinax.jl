using Pinax
using Pinax: _approx_numbers, _check_from, _margin_svg, Check, TestNode
using Test

# The AbstractTestSet subtype lives in the extension — `Test` is a weakdep, because Pinax is a
# rendering package and `using Pinax` must not drag Test into every user's session. Loading `Test`
# (which you necessarily did, to write `@testset`) loads the extension.
const Ext = Base.get_extension(Pinax, :PinaxTestExt)
const PinaxTestSet = Ext.PinaxTestSet
const _result_data_expr = Ext._result_data_expr
_check_for(r, i) = _check_from(_result_data_expr(r), Ext._label(r), r isa Test.Pass, i)

# The entry point is `Pinax.test` — a suite with NO token, plain `@testset`. Its two forms (in-process
# on a file, and `Pkg.test` delegation via a `-L` preamble) both install a capturing root that renders
# and re-imposes the verdict; that can only be exercised at depth 0, so those cases run in a subprocess.
# The contract that matters most: a failing suite still fails the process, report or no report.
@testset "PinaxTestSet" begin
    @testset "off by default — a bare @testset is stock Test" begin
        # Test is a WEAKDEP: `using Pinax` alone must not drag it in. There is no token and no env
        # switch — a bare `@testset` is a `DefaultTestSet`, so a plain `Pkg.test()` is untouched and
        # produces no report; the report exists only when `Pinax.test` installs a capturing root.
        @test Ext !== nothing                       # `using Test` above loaded the extension
        @test PinaxTestSet <: Test.AbstractTestSet
        withenv("PINAX_TEST_OUT" => "somewhere") do
            @test Pinax.report_out() == "somewhere"
        end
        withenv("PINAX_TEST_TITLE" => "My Suite") do
            @test Pinax.report_title() == "My Suite"
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

    @testset "dump → merge → one gallery (how sharded CI works)" begin
        dir = mktempdir()
        # Two shards, each holding a DISJOINT set of test files — which is exactly what the fleet's
        # 8-way shard split produces. Rendering per shard would give N disconnected galleries; the
        # shards dump their trees instead, and one later job merges and renders once.
        shard(desc, files) = TestNode("MyPkg"; elapsed=1.0, children=files)
        file(name, checks; nbroken=0) =
            TestNode(name; elapsed=0.5, checks=checks, nbroken=nbroken)
        c(label, got, want, tol, pass) =
            Check(:t0, label, got, want, abs(got - want) / abs(want), tol, :rel, pass)

        d1 = Pinax.dump_test_report(
            shard("MyPkg", [file("test_a.jl", [c("close", 1.0, 1.0098, 0.01, true)])]),
            joinpath(dir, "shard-1.toml"),
        )
        d2 = Pinax.dump_test_report(
            shard("MyPkg", [file("test_b.jl", [c("broken", 0.5, 0.9, 0.01, false)])]),
            joinpath(dir, "shard-2.toml"),
        )

        # round-trip: TOML keeps Float64 exactly, which is the only reason a dump is honest
        back = Pinax.load_test_dump(d1)
        @test back.children[1].description == "test_a.jl"
        @test back.children[1].checks[1].want === 1.0098

        Pinax.render_test_report([d1, d2]; out=joinpath(dir, "m"), title="Merged")
        md = read(joinpath(dir, "m_agent", "agent.md"), String)
        # ONE gallery, one page per test FILE — the shard boundary is invisible in the output…
        @test occursin("test_a.jl", md) && occursin("test_b.jl", md)
        @test !occursin("shard", lowercase(md))
        # …and the check ids are renumbered across the merge rather than colliding at t1
        @test occursin("t1 —", md) && occursin("t2 —", md)
    end

    @testset "a broken test is counted, never painted red" begin
        # Test.Broken is not a Pass, so encoding it as a Check would give pass=false — a red bar and
        # a FAIL verdict for a test the runner is perfectly happy about.
        n = TestNode(
            "test_x.jl";
            checks=[Check(:t0, "ok", 1.0, 1.0, 0.0, 0.5, :abs, true)],
            nbroken=1,
        )
        @test Pinax._ntests(n) == 2
        @test Pinax._nfail(n) == 0
        @test occursin("1 broken", Pinax._summary_line(n))
        @test occursin("1/2 passed", Pinax._summary_line(n))
    end

    @testset "the seam: content macros route into the open testset (A)" begin
        # A PinaxTestSet on the stack IS the container — @figure/@desc land in it, in declaration
        # order, through the one seam Pinax._current_container(). No @page/@section, no CTX; the
        # gens are deferred, so nothing is plotted here.
        root = PinaxTestSet("cap-root")
        captured = nothing
        Test.push_testset(root)
        try
            captured = Pinax._current_container()
            @figure "plotA"
            @desc md"a description"
            @figure "plotB"
        finally
            Test.pop_testset()
        end
        @test captured === root
        @test length(root.figures) == 2
        @test root.desc !== nothing && occursin("a description", root.desc.source)
        @test root.content == [:figure => 1, :figure => 2]   # @desc sets desc, not content order
    end

    @testset "the seam is inert inside a stock testset, report off (invariant V)" begin
        # A DefaultTestSet is the innermost and no manuscript is open → :inert → @figure no-ops, and
        # its argument (a deferred gen) is never evaluated. It must neither error nor capture.
        @testset "stock inner" begin
            @test Pinax._current_container() === :inert
            ## every content macro is inert here — none stores anything, none errors
            @figure error("this gen must never run")   # gen deferred + inert → never evaluated
            @table (; N=[1, 2], E=[3, 4])
            @raw "<b>x</b>"
            @desc md"d"
            @caption "c"
        end
    end

    @testset "fold places captured tables / panels / figures; dump warns on a figure" begin
        # Drive the fold over a node carrying every content kind (a live PinaxTestSet and a merged
        # TestNode share this duck-typed shape), so the :table / :panel / :figure branches all run and
        # land on the page in declaration order.
        fig = Pinax.Figure(
            :f,
            "f",
            "cap",
            nothing,
            () -> (p=tempname() * ".svg"; write(p, "<svg/>"); p),
            "code",
            false,
            String[],
            nothing,
        )
        tbl = Pinax.Table(
            :tb,
            "tb",
            "a table caption",
            ["N", "E"],
            [Any[10, -0.1], Any[20, -0.11]],
            "tc",
            nothing,
        )
        node = TestNode(
            "test_x.jl";
            elapsed=0.1,
            checks=[Check(:t0, "chk", 1.0, 1.0, 0.0, 0.5, :abs, true)],
            figures=[fig],
            tables=[tbl],
            panels=["<p>hand built</p>"],
            content=[:panel => 1, :table => 1, :figure => 1, :check => 1],
        )
        root = TestNode("Pkg"; children=[node])
        dir = mktempdir()
        Pinax.render_test_report(root; out=joinpath(dir, "r"), title="T")
        html = read(joinpath(dir, "r_html", "test_x_jl.html"), String)
        @test occursin("a table caption", html)   # the @table folded onto the page
        @test occursin("hand built", html)         # the @raw panel folded onto the page
        # the dump carries checks + structure and WARNS (never silently drops) a test's figure
        @test isfile(Pinax.dump_test_report(root, joinpath(dir, "d.toml")))
    end

    @testset "a manuscript built inside a test still writes to CTX, not :inert (A)" begin
        # Pinax's own suite builds manuscripts inside @testset. An open CTX container must win over
        # the enclosing stock testset — otherwise every manuscript test would silently go inert.
        doc = Pinax.document() do
            @page :p "P" begin
                @section :s "S" begin
                    @figure "fig-in-manuscript"
                end
            end
        end
        @test length(doc.pages[1].sections[1].figures) == 1
    end

    @testset "Pkg.test delegation: the -L preamble captures a plain suite, fails on red (G)" begin
        # Mimic what `Pinax.test()` sets up in a `Pkg.test` subprocess: the `-L` preamble runs
        # `_install_test_capture!()` (an unbalanced capturing root), THEN the runner `include`s the
        # runtests — a plain `@testset` tree that inherits the root — and an `atexit` hook renders and
        # imposes the exit code. Contrast with a bare run (no preamble): stock Test, no report.
        dir = mktempdir()
        write(
            joinpath(dir, "runtests.jl"),
            """
            @testset "tests" begin            # a grouping wrapper — flattened, like a real runtests.jl
                @testset "test_demo.jl" begin
                    @desc md"convergence of E against the oracle"
                    @test isapprox(-0.10203402715213993, -0.10242223073749557; rtol=0.01)
                    @test isapprox(0.5, 0.9; rtol=0.01)
                end
                @testset "noisy fixture" begin
                    @pinaxignore
                    @test true
                end
            end
            """,
        )
        runtests = repr(joinpath(dir, "runtests.jl"))
        run_script = function (body)
            script = tempname() * ".jl"
            write(script, body)
            log = tempname()
            cmd = addenv(
                `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) $script`,
                "PINAX_TEST_OUT" => joinpath(dir, "rep"),
            )
            p = run(pipeline(ignorestatus(cmd); stdout=log, stderr=log))
            return (; ok=success(p), log=read(log, String))
        end

        # ---- bare run (no preamble): stock Test, red fails, nothing rendered ----
        r = run_script("using Pinax, Test\ninclude($(runtests))\n")
        @test !r.ok                                   # the top-level DefaultTestSet throws on red
        @test !isdir(joinpath(dir, "rep_agent"))      # no report — a bare run is untouched

        # ---- delegation preamble: capture + render + exit code + @pinaxignore ----
        r = run_script(
            "using Pinax, Test\nPinax._install_test_capture!()\ninclude($(runtests))\n"
        )
        @test !r.ok                                   # red suite fails the process (atexit exit(1))
        @test occursin("Pinax test report", r.log)
        md = read(joinpath(dir, "rep_agent", "agent.md"), String)
        @test occursin("1/2 FAIL", md)                # verdict preserved on the file's page
        @test occursin("got 0.5, want 0.9", md)       # the failing check kept its real numbers
        @test occursin("convergence of E against the oracle", md)  # a @desc inside a test reached it
        @test isfile(joinpath(dir, "rep_html", "test_demo_jl.html"))
        @test !occursin("noisy fixture", md)          # @pinaxignore dropped it (it still ran)
    end

    @testset "Pinax.test renders a plain @testset suite (the interface, G)" begin
        # The featured entry point: a suite with NO Pinax token — plain `@testset`/`@test` (it may
        # also `@desc`) — rendered by calling `Pinax.test` instead of `include`. Runs at depth 0 in a
        # subprocess so the root actually renders (and, for a red suite, re-throws).
        dir = mktempdir()
        write(
            joinpath(dir, "suite.jl"),
            """
            using Pinax, Test
            @testset "ok.jl" begin
                @desc md"a description written inside a plain @testset"
                @test isapprox(1.0, 1.0009; rtol=0.01)
            end
            """,
        )
        write(
            joinpath(dir, "bad.jl"),
            """
            using Pinax, Test
            @testset "bad.jl" begin
                @test isapprox(0.5, 0.9; rtol=0.01)
            end
            """,
        )
        run_it = function (suite, out)
            script = joinpath(dir, "run_" * basename(out) * ".jl")
            write(
                script,
                "using Pinax, Test\nPinax.test($(repr(suite)); out=$(repr(out)), title=\"demo\")\n",
            )
            cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) $script`
            return success(run(pipeline(ignorestatus(cmd); stdout=devnull, stderr=devnull)))
        end

        # green suite → Pinax.test succeeds and renders, from a suite with no @pinaxtestset in sight
        out = joinpath(dir, "rep")
        @test run_it(joinpath(dir, "suite.jl"), out)
        @test isfile(joinpath(out * "_html", "ok_jl.html"))
        md = read(joinpath(out * "_agent", "agent.md"), String)
        @test occursin("a description written inside a plain @testset", md)

        # red suite → Pinax.test re-throws (process fails): a report never turns a red suite green
        @test !run_it(joinpath(dir, "bad.jl"), joinpath(dir, "badrep"))
    end
end
