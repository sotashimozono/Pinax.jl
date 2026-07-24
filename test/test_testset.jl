using Pinax
using Pinax:
    _approx_numbers,
    _check_from,
    _margin_svg,
    _parse_binding,
    _is_swept,
    _looks_like_a_file,
    render_test_report,
    Check,
    CodeBlock,
    TestNode
using Test
using Test: DefaultTestSet   # explicit stock context for report-off (inert) assertions

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
        @testset DefaultTestSet "stock inner" begin
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

    @testset "hierarchical + collision-free ids (B)" begin
        # A flat `_slug(desc)` would collide for same-named files or sections. Page ids are made
        # globally unique, section ids page-qualified, and any true collision gets a `-2` suffix + a
        # loud diagnostic — never a silent overwrite / duplicate `agent.json` id.
        sec(name) = TestNode(name; checks=[Check(:t0, "c", 1.0, 1.0, 0.0, 0.5, :abs, true)])
        file(name, secs) = TestNode(name; children=secs)
        root = TestNode(
            "Pkg";
            children=[
                file("test_a.jl", [sec("basics"), sec("basics")]),  # sibling collision within one page
                file("test_a.jl", [sec("basics")]),                 # duplicate FILE (page) name
            ],
        )
        dir = mktempdir()
        Pinax.render_test_report(root; out=joinpath(dir, "r"), title="T")
        # duplicate page ids disambiguated → both files render (no silent overwrite)
        @test isfile(joinpath(dir, "r_html", "test_a_jl.html"))
        @test isfile(joinpath(dir, "r_html", "test_a_jl-2.html"))
        # section ids are page-qualified; the sibling collision within test_a.jl took the `-2` suffix
        html = read(joinpath(dir, "r_html", "test_a_jl.html"), String)
        @test occursin("test_a_jl_basics", html) && occursin("test_a_jl_basics-2", html)
        # both collisions are surfaced as loud diagnostics (never silent)
        dups = count(
            e -> occursin("duplicate id", e.message), Pinax.current_document().diag.entries
        )
        @test dups >= 2
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
                `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $script`,
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
            cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $script`
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

    @testset "a `@testset for` is a SAMPLE, not a section — the sweep fold (C)" begin
        # An unnamed `@testset for χ in …` is not N sections; it is a sweep. We read the axis ONLY from
        # the canonical string Test itself generates ("χ = 8"), fold the iterations into a convergence +
        # margin figure keyed by the test expression, and never touch the verdict. Tested on the
        # Test-free `TestNode` shape (the fold walks the live `PinaxTestSet` and a merged dump the same).
        mkchk(g, w, rt) = Check(
            :t,
            "isapprox(E, oracle; rtol = $(rt))",
            g,
            w,
            abs(g - w) / abs(w),
            rt,
            :rel,
            abs(g - w) / abs(w) <= rt,
        )

        @testset "the binding parser reads ONLY the canonical form (invariant III)" begin
            @test _parse_binding("χ = 8") == [:χ => "8"]            # Unicode loop var
            @test _parse_binding("χ = 8, β = 0.1") == [:χ => "8", :β => "0.1"]
            @test _parse_binding("N = (1, 2)") == [:N => "(1, 2)"]  # a comma inside a tuple value
            @test _parse_binding("a plain sentence") === nothing    # a human description does not fold
            @test _parse_binding("MyPkg") === nothing               # a grouping name has no binding
            @test _parse_binding("x == y") === nothing              # a comparison is not a binding
        end

        @testset "numeric sweep → one convergence + margin figure, verdict preserved" begin
            samp(χ, got) = TestNode("χ = $(χ)"; checks=[mkchk(got, 1.0, 0.05)])
            file = TestNode(
                "test_conv.jl"; children=[samp(8, 1.2), samp(16, 1.05), samp(32, 1.01)]
            )
            @test _is_swept(file, _looks_like_a_file)
            out = joinpath(mktempdir(), "rep")
            render_test_report(TestNode("Test report"; children=[file]); out=out)
            html = read(joinpath(out * "_html", "test_conv_jl.html"), String)
            md = read(joinpath(out * "_agent", "agent.md"), String)
            @test occursin("Convergence of", html)                 # the derived figure
            @test occursin("test_conv_jl_conv_1", md)              # convergence fig id
            @test occursin("test_conv_jl_swpmargin_1", md)         # margin-vs-axis fig id
            @test occursin("1/3 FAIL", md)                         # verdict untouched (2 of 3 fail)
            @test occursin("[χ = 8]", md) && occursin("[χ = 32]", md)  # checks binding-tagged
            @test !occursin("[id: test_conv_jl_8]", md)            # NOT rendered as a per-value section
        end

        @testset "nested loops: innermost = x-axis, outer = legend (C3)" begin
            inner(β, got) = TestNode("β = $(β)"; checks=[mkchk(got, 1.0, 0.05)])
            outer(χ, gots) = TestNode("χ = $(χ)"; children=[inner(b, g) for (b, g) in gots])
            file = TestNode(
                "test_nest.jl";
                children=[
                    outer(8, [(0.1, 1.2), (0.2, 1.1)]),
                    outer(16, [(0.1, 1.05), (0.2, 1.02)]),
                ],
            )
            @test _is_swept(file, _looks_like_a_file)
            out = joinpath(mktempdir(), "rep")
            render_test_report(TestNode("Test report"; children=[file]); out=out)
            html = read(joinpath(out * "_html", "test_nest_jl.html"), String)
            @test occursin("χ = 8", html) && occursin("χ = 16", html)   # the two legend series
        end

        @testset "non-numeric axis → categorical ticks (C1)" begin
            csamp(m, got) = TestNode("model = $(m)"; checks=[mkchk(got, 1.0, 0.05)])
            file = TestNode(
                "test_cat.jl"; children=[csamp("TFIM", 1.01), csamp("Heisenberg", 1.03)]
            )
            @test _is_swept(file, _looks_like_a_file)
            out = joinpath(mktempdir(), "rep")
            render_test_report(TestNode("Test report"; children=[file]); out=out)
            html = read(joinpath(out * "_html", "test_cat_jl.html"), String)
            @test occursin("TFIM", html) && occursin("Heisenberg", html) # string ticks, not numbers
        end

        @testset "mixed / inconsistent siblings do NOT fold — kept as sections, warned (III)" begin
            file = TestNode(
                "test_mix.jl";
                children=[
                    TestNode("χ = 8"; checks=[mkchk(1.01, 1.0, 0.05)]),
                    TestNode("a smoke check"; checks=[mkchk(1.0, 1.0, 0.05)]),
                ],
            )
            @test !_is_swept(file, _looks_like_a_file)              # not a consistent sweep
            out = joinpath(mktempdir(), "rep")
            render_test_report(TestNode("Test report"; children=[file]); out=out)
            files = readdir(out * "_html")
            txt = join(
                read(joinpath(out * "_html", f), String) for
                f in files if endswith(f, ".html")
            )
            @test occursin("a smoke check", txt)                   # rendered as an ordinary section
            @test occursin("could not be folded", txt)             # never silent (a loud diagnostic)
        end

        @testset "a real `@testset for` folds through the delegation preamble (end-to-end)" begin
            # The same fold, but driven by Test's own `testset_forloop` (the canonical descriptions are
            # machine-generated, not hand-written) through the capturing root — at depth 0, so subprocess.
            dir = mktempdir()
            write(
                joinpath(dir, "runtests.jl"),
                """
                @testset "test_sweep.jl" begin
                    @testset for χ in (8, 16, 32)
                        E = 1.0 + 1.0 / χ            # → 1.0 as χ grows
                        @test isapprox(E, 1.0; rtol=0.05)
                    end
                end
                """,
            )
            script = tempname() * ".jl"
            write(
                script,
                "using Pinax, Test\nPinax._install_test_capture!()\ninclude($(repr(joinpath(dir, "runtests.jl"))))\n",
            )
            cmd = addenv(
                `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $script`,
                "PINAX_TEST_OUT" => joinpath(dir, "rep"),
            )
            run(pipeline(ignorestatus(cmd); stdout=devnull, stderr=devnull))
            md = read(joinpath(dir, "rep_agent", "agent.md"), String)
            @test occursin("Convergence of", md)                   # the sweep figure, from a real forloop
            @test occursin("[χ = 8]", md) && occursin("[χ = 32]", md)
            @test occursin("1/3", md)                              # verdict preserved (only χ=32 passes)
        end
    end

    @testset "provenance — the report records WHEN / WHAT / WHERE it ran (H)" begin
        # A green report with no commit or date is indistinguishable from a stale one. Provenance is
        # captured non-fatally (any unreadable field is omitted, never an error), with CI variables
        # preferred over a local `git` probe (reliable inside the `Pkg.test` sandbox).
        withenv(
            "GITHUB_SHA" => "0123456789abcdef",
            "GITHUB_REF_NAME" => "feat/x",
            "GITHUB_REPOSITORY" => "Org/Pkg.jl",
        ) do
            rows = Pinax._provenance_rows()
            @test any(r -> r.field == "generated", rows)
            @test any(r -> r.field == "julia" && r.value == string(VERSION), rows)
            @test any(r -> r.field == "commit" && r.value == "0123456789ab", rows)  # 12 chars, from CI
            @test any(r -> r.field == "repo" && r.value == "Org/Pkg.jl", rows)

            # …and it reaches the rendered overview + agent.json
            n = TestNode(
                "Test report";
                children=[
                    TestNode(
                        "test_a.jl";
                        checks=[Check(:t, "ok", 1.0, 1.0, 0.0, 0.5, :abs, true)],
                    ),
                ],
            )
            out = joinpath(mktempdir(), "rep")
            render_test_report(n; out=out)
            md = read(joinpath(out * "_agent", "agent.md"), String)
            @test occursin("Provenance", md) && occursin("feat/x", md)
        end

        # the package line reads name@version from a project file; empty/absent → "" (never an error)
        proj = joinpath(mktempdir(), "Project.toml")
        write(proj, "name = \"Demo\"\nversion = \"1.2.3\"\n")
        @test Pinax._package_line(proj) == "Demo v1.2.3"
        @test Pinax._package_line(nothing) == ""
        @test Pinax._package_line(joinpath(tempdir(), "nope-missing.toml")) == ""
        write(proj, "version = \"1.2.3\"\n")   # no name → ""
        @test Pinax._package_line(proj) == ""

        # with the CI variables unset, the local `git` probe runs and empty CI fields are omitted
        withenv(
            "GITHUB_SHA" => nothing,
            "GITHUB_REPOSITORY" => nothing,
            "GITHUB_REF_NAME" => nothing,
        ) do
            rows = Pinax._provenance_rows()
            @test any(r -> r.field == "generated", rows)
            @test !any(r -> r.field == "repo", rows)   # an empty CI repo is omitted, not blank
        end
    end

    @testset "@caption after a @test names the check's quantity (C follow-up)" begin
        # A swept `@testset for` folds by the check's label; `@caption` sets that label to a human name,
        # so a convergence figure is titled `energy` rather than the raw `isapprox(...)` expression.
        root = PinaxTestSet("cap")
        Test.push_testset(root)
        try
            @test isapprox(1.0, 1.0009; rtol=0.01)   # records a check into the captured testset
            @caption "energy"
        finally
            Test.pop_testset()
        end
        @test root.checks[end].label == "energy"     # the caption renamed the quantity

        # …and with nothing before it (no figure, no check) it is a loud diagnostic, not an error
        Pinax.reset!()
        @page :orphan "P" begin
            @caption "nothing to name"
        end
        @test any(
            e -> occursin("no preceding", e.message), Pinax.current_document().diag.entries
        )
    end

    @testset "@expect inside a captured test is forbidden — @test is the assertion (F)" begin
        # `@expect` is manuscript vocabulary. Directly inside a test — here a captured `PinaxTestSet`,
        # the report-ON path — it errors and points to `@test`, so a check can never be recorded but
        # left unenforced (which under a bare `Pkg.test()` would be a green run for a failing check).
        root = PinaxTestSet("cap")
        Test.push_testset(root)
        try
            @test_throws "manuscript check" Pinax._push_check!(;
                id=:E, label="energy", got=1.0, want=1.0, tol=1e-3
            )
        finally
            Test.pop_testset()
        end
    end

    @testset "a failing check carries file:line — the failure payload (I)" begin
        # A failing @test records WHERE it failed (its LineNumberNode), so the report says where to
        # look, not just what failed. Captured duck-typed (a Pass may carry no source), carried through
        # a shard dump, and emitted as a structured field in agent.json.
        fail = Test.Fail(
            :test,
            :(isapprox(a, b)),
            "isapprox(0.5, 0.9; rtol = 0.01)",
            nothing,
            nothing,
            LineNumberNode(42, Symbol("/proj/test/test_x.jl")),
            false,
        )
        @test Ext._source_str(fail) == "test_x.jl:42"          # basename:line, not the full path
        @test Ext._source_str(Test.Pass(:test, :x, :(1 == 1), nothing)) == ""   # no usable source → ""

        # recorded onto the check, alongside its (failing) verdict…
        root = PinaxTestSet("cap")
        Test.push_testset(root)
        try
            Test.record(root, fail)
        finally
            Test.pop_testset()
        end
        @test root.checks[end].source == "test_x.jl:42" && !root.checks[end].pass

        # …round-trips through a shard dump…
        dir = mktempdir()
        srcchk() = Check(:t, "e", 0.5, 0.9, 0.44, 0.01, :rel, false, "test_x.jl:42")
        d = Pinax.dump_test_report(
            TestNode("test_x.jl"; checks=[srcchk()]), joinpath(dir, "s.toml")
        )
        @test Pinax.load_test_dump(d).checks[1].source == "test_x.jl:42"

        # …and is emitted as a structured field in agent.json (an agent reads WHERE, not just what).
        render_test_report(
            TestNode("Test report"; children=[TestNode("test_x.jl"; checks=[srcchk()])]);
            out=joinpath(dir, "rep"),
        )
        aj = read(joinpath(dir, "rep_agent", "agent.json"), String)
        @test occursin("\"source\":\"test_x.jl:42\"", aj)
    end

    @testset "at scale the human gallery caps rows; agent.json stays complete (J)" begin
        # A 10k-check page is an unusable HTML table, so the gallery caps rows — FAILURES first and
        # never silently (a summary row counts the hidden) — while agent.json and the shard dump stay
        # complete and the verdict is over ALL checks.
        mk(i, pass) = Check(
            Symbol("t", i),
            "chk $(i)",
            pass ? 1.0 : 2.0,
            1.0,
            pass ? 0.0 : 1.0,
            0.5,
            :abs,
            pass,
        )
        fails = (3, 50, 480)
        checks = [mk(i, !(i in fails)) for i in 1:500]

        shown, hf, hp = Pinax._cap_gallery_checks(checks, Pinax._MAX_CHECK_ROWS)
        @test length(shown) == Pinax._MAX_CHECK_ROWS
        @test count(c -> !c.pass, shown) == length(fails)          # every failure survives the cap
        @test hf == 0 && hp == 500 - Pinax._MAX_CHECK_ROWS
        small = checks[1:10]
        @test Pinax._cap_gallery_checks(small, Pinax._MAX_CHECK_ROWS) == (small, 0, 0)  # small = all

        out = joinpath(mktempdir(), "rep")
        render_test_report(
            TestNode("Test report"; children=[TestNode("big.jl"; checks=checks)]); out=out
        )
        html = read(joinpath(out * "_html", "big_jl.html"), String)
        @test occursin("more not shown", html)                     # the loud summary row
        @test occursin("$(500 - length(fails))/500", html)         # verdict over ALL 500
        @test count("pinax-pass\"", html) + count("pinax-fail\"", html) <=
            Pinax._MAX_CHECK_ROWS
        @test occursin("worst of 500", html)                       # the margin figure capped too
        aj = read(joinpath(out * "_agent", "agent.json"), String)
        @test count("\"pass\":", aj) >= 500                        # agent.json enumerates every check
    end

    @testset "a CI matrix merges as parts, not shards — the cell is a binding (K)" begin
        # A matrix runs the SAME files in every cell (unlike shards, which partition files), so merging
        # by concatenation would fold the cells away. Each cell is a `@part` instead: one report, file
        # structure preserved, page ids qualified per cell, per-cell verdicts, cell = the provenance.
        dir = mktempdir()
        cellnode(pass) = TestNode(
            "root";
            children=[
                TestNode(
                    "test_foo.jl";
                    checks=[
                        Check(
                            :t,
                            "chk",
                            pass ? 1.0 : 2.0,
                            1.0,
                            pass ? 0.0 : 1.0,
                            0.5,
                            :abs,
                            pass,
                        ),
                    ],
                ),
            ],
        )
        dA = withenv("PINAX_TEST_MATRIX" => "julia 1.11 · ubuntu") do
            Pinax.dump_test_report(cellnode(true), joinpath(dir, "a.toml"))
        end
        dB = withenv("PINAX_TEST_MATRIX" => "julia 1.10 · ubuntu") do
            Pinax.dump_test_report(cellnode(false), joinpath(dir, "b.toml"))
        end
        @test occursin("matrix", read(dA, String))              # the cell rides in the dump

        out = joinpath(dir, "m")
        render_test_report([dA, dB]; out=out, title="Matrix")
        idx = read(joinpath(out * "_html", "index.html"), String)
        md = read(joinpath(out * "_agent", "agent.md"), String)
        files = readdir(out * "_html")
        @test occursin("julia 1.11 · ubuntu", idx) && occursin("julia 1.10 · ubuntu", idx)  # both parts
        # the SAME file in two cells → two pages, ids qualified per cell (no collision)
        @test count(f -> occursin("test_foo_jl", f) && endswith(f, ".html"), files) == 2
        @test occursin("1/1 PASS", md) && occursin("0/1 FAIL", md)   # per-cell verdict, not merged

        # a single-cell (non-matrix) run is self-identifying: the cell is a provenance row
        withenv("PINAX_TEST_MATRIX" => "julia 1.11 · ubuntu") do
            @test any(
                r -> r.field == "matrix" && r.value == "julia 1.11 · ubuntu",
                Pinax._provenance_rows(),
            )
        end
    end

    @testset "derived figures are data-keyed — no stale figure on rebuild (L)" begin
        # The margin / convergence SVGs fold a fingerprint of the checks they draw into the figure
        # `code`, so the render cache (keyed on code+params, computed without calling `gen`) re-draws a
        # figure iff its numbers changed — a docs rebuild with unchanged checks reuses the SVG, and a
        # stale figure can never survive a real change (which `code=""` used to allow: a constant key).
        c1 = [Check(:t, "c", 1.0, 1.0, 0.0, 0.5, :abs, true)]
        c2 = [Check(:t, "c", 5.0, 1.0, 4.0, 0.5, :abs, false)]
        @test Pinax._checks_fingerprint(c1) == Pinax._checks_fingerprint(c1)   # stable
        @test Pinax._checks_fingerprint(c1) != Pinax._checks_fingerprint(c2)   # data-dependent

        out = joinpath(mktempdir(), "rep")
        rep(chk) = render_test_report(
            TestNode("T"; children=[TestNode("f.jl"; checks=chk)]); out=out
        )
        svgfor() = read(
            only(
                filter(
                    p -> occursin("margins", p),
                    readdir(
                        joinpath(out * "_html", "assets", "figures", "f_jl"); join=true
                    ),
                ),
            ),
            String,
        )
        rep(c1)
        s1 = svgfor()
        rep(c1)
        @test svgfor() == s1        # unchanged checks → identical SVG (cache-consistent)
        rep(c2)
        @test svgfor() != s1        # changed checks → the SVG reflects the new numbers (never stale)
    end

    @testset "@code shows the computation behind a figure/check" begin
        # `@code` renders source (+ optional captured output) as a snippet — a sibling to
        # `@figure`/`@table`. A simple assignment leaks + shows its value; a pure expression shows its
        # value; a definition runs BARE (natural scoping, no wrapper that would relocalise it).
        Pinax.reset!()
        @page :p "P" begin
            @code y = 6 * 7
            @code 2^10
            @code midpoint(x) = 2x
            @code run = false z = boom()
            @assert y == 42 && midpoint(3) == 6      # the assignment + definition leaked to here
        end
        codes = Pinax.current_document().pages[1].codes
        @test [c.output for c in codes] == ["42", "1024", "", ""]  # value / value / defn / show-only
        @test codes[1].source == "y = 6 * 7" && codes[4].source == "z = boom()"

        # it renders in every backend (gallery/agent covered below; here the LaTeX verbatim)
        tex = read(Pinax.render(; out=joinpath(mktempdir(), "tex"), theme=:latex), String)
        @test occursin("y = 6 * 7", tex) && occursin("\\begin{verbatim}", tex)

        # captured into a test (a PinaxTestSet), rides a dump, and renders in every backend
        root = PinaxTestSet("cap")
        Test.push_testset(root)
        try
            @code E = 1.0 + 1.0 / 8
            @assert E ≈ 1.125
        finally
            Test.pop_testset()
        end
        @test length(root.codes) == 1 && root.codes[1].output == "1.125"

        dir = mktempdir()
        n = TestNode(
            "f.jl"; codes=[CodeBlock(:c1, "c1", "E = f(x)", "1.125", "energy", "julia")]
        )
        d = Pinax.dump_test_report(TestNode("r"; children=[n]), joinpath(dir, "s.toml"))
        @test Pinax.load_test_dump(d).children[1].codes[1].source == "E = f(x)"   # round-trips a shard
        render_test_report(TestNode("T"; children=[n]); out=joinpath(dir, "rep"))
        @test occursin("E = f(x)", read(joinpath(dir, "rep_html", "f_jl.html"), String))
        @test occursin(
            "\"source\":\"E = f(x)\"",
            read(joinpath(dir, "rep_agent", "agent.json"), String),
        )
    end

    @testset "each @test auto-captures its source region — code + profile together (default)" begin
        # A test's computation + assertion is read from its file at record time and shown WITH its
        # profile; the region runs from just after the PREVIOUS test (bounded), so consecutive tests
        # don't repeat each other's setup.
        f = joinpath(mktempdir(), "t.jl")
        write(f, "a = 1\nb = 2\n@test a + b == 3\nc = 4\n@test c == 4\n")
        mk(line) = Test.Fail(
            :test, :x, "x", nothing, nothing, LineNumberNode(line, Symbol(f)), false
        )
        empty!(Ext._REGION_LAST)
        r3 = Ext._capture_region(mk(3))
        r5 = Ext._capture_region(mk(5))
        @test occursin("a = 1", r3) && occursin("@test a + b == 3", r3)   # first test: from the top
        @test occursin("c = 4", r5) && !occursin("a = 1", r5)             # second: no bleed from the first

        # the code renders WITH the profile (gallery row + agent.json field) and rides a dump
        dir = mktempdir()
        chk = Check(:t, "chk", 1.0, 1.0, 0.0, 0.5, :abs, true, "", "x = compute()")
        n = TestNode("f.jl"; checks=[chk])
        d = Pinax.dump_test_report(TestNode("r"; children=[n]), joinpath(dir, "s.toml"))
        @test Pinax.load_test_dump(d).children[1].checks[1].code == "x = compute()"  # round-trips a shard
        render_test_report(TestNode("T"; children=[n]); out=joinpath(dir, "rep"))
        html = read(joinpath(dir, "rep_html", "f_jl.html"), String)
        @test occursin("x = compute()", html) && occursin("pinax-code-row", html)
        @test occursin(
            "\"code\":\"x = compute()\"",
            read(joinpath(dir, "rep_agent", "agent.json"), String),
        )
    end
end
