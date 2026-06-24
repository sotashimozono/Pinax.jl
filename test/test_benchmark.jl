using Pinax
using Test

# A theme variant overriding emit_check — proves the new contract point dispatches like emit_table.
struct CheckOverrideAgent <: Pinax.AgentBase end
function Pinax.emit_check(::CheckOverrideAgent, chk, ctx)
    return print(ctx.io, "{\"custom_chk\":\"", chk.id, "\"}")
end

# `@expect` / `@benchmark` — a physics test set. `@expect` is a single PASS/FAIL check; `@benchmark`
# is a page (status=:benchmark) grouping checks into a verdict. One node set renders to a
# machine-readable `benchmark` block (agent), a fixed test-report (gallery), and a tabular (latex).
@testset "@benchmark / @expect" begin
    @testset "_push_check! resolves rel/abs deviation" begin
        # rel when want != 0
        Pinax.reset!(; title="t")
        @page :p "P" begin
            chk = @expect "E1" "energy density e" got = -0.81034 want = -0.81031 tol = 1e-2
        end
        c = Pinax.current_document().pages[1].checks[1]
        @test c.id == :E1
        @test c.label == "energy density e"
        @test c.kind == :rel
        @test c.delta ≈ abs(-0.81034 - -0.81031) / abs(-0.81031)
        @test c.pass

        # abs when want == 0 (a residual)
        Pinax.reset!(; title="t")
        @page :p "P" begin
            @expect "R" "residual" got = 1e-5 tol = 1e-3
        end
        c = Pinax.current_document().pages[1].checks[1]
        @test c.kind == :abs
        @test c.delta ≈ 1e-5
        @test c.want == 0.0
        @test c.pass

        # kind=:abs forces abs even with a nonzero reference
        Pinax.reset!(; title="t")
        @page :p "P" begin
            @expect "A" "absolute" got = 1.5 want = 1.0 tol = 1.0 kind = :abs
        end
        c = Pinax.current_document().pages[1].checks[1]
        @test c.kind == :abs
        @test c.delta ≈ 0.5     # abs(1.5 - 1.0), NOT the relative 0.5/1.0
        @test c.pass

        # a deliberately failing check
        Pinax.reset!(; title="t")
        @page :p "P" begin
            @expect "F" "fails" got = 2.0 want = 0.0 tol = 1e-3
        end
        c = Pinax.current_document().pages[1].checks[1]
        @test c.kind == :abs
        @test !c.pass
    end

    @testset "id accepts a Symbol or a String" begin
        Pinax.reset!(; title="t")
        @page :p "P" begin
            @expect :S1 "sym id" got = 1.0 want = 1.0 tol = 1e-3
            @expect "S2" "str id" got = 1.0 want = 1.0 tol = 1e-3
        end
        cs = Pinax.current_document().pages[1].checks
        @test cs[1].id == :S1
        @test cs[2].id == :S2
    end

    @testset "@benchmark is a status=:benchmark page" begin
        Pinax.reset!(; title="t")
        @benchmark :aa_tl "AA TL test set" begin
            @expect "E1" "energy density e" got = -0.81034 want = -0.81031 tol = 1e-2
        end
        pg = Pinax.current_document().pages[1]
        @test pg.id == :aa_tl
        @test pg.title == "AA TL test set"
        @test pg.status === :benchmark
        @test length(pg.checks) == 1
    end

    @testset "renders to agent + gallery (mixed verdict)" begin
        tmp = mktempdir()
        Pinax.reset!(; title="T")
        # one rel-pass, one abs-pass (want=0 residual), one abs-FAIL
        @benchmark :aa_tl "AA TL test set" begin
            @desc md"A deliberate mix of passing and failing checks."
            @expect "E1" "energy density e" got = -0.81034 want = -0.81031 tol = 1e-2  # rel pass
            @expect "R0" "residual" got = 3.0e-5 tol = 1e-3                              # abs pass (want=0)
            @expect "G2" "gap" got = 0.5 want = 0.0 tol = 1e-3                           # abs FAIL
        end

        # ----- agent backend (the machine-readable verdict contract) -----
        Pinax.render(; out=joinpath(tmp, "a"), theme=:agent)
        aj = read(joinpath(tmp, "a", "agent.json"), String)
        @test occursin("\"kind\":\"benchmark\"", aj)
        @test occursin("\"id\":\"aa_tl\"", aj)
        @test occursin("\"verdict\":\"FAIL\"", aj)
        @test occursin("\"passed\":2", aj)
        @test occursin("\"total\":3", aj)
        @test occursin("\"failed\":[\"G2\"]", aj)
        # each check's fields, native-typed numerics
        @test occursin("\"id\":\"E1\",\"label\":\"energy density e\"", aj)
        @test occursin("\"kind\":\"rel\"", aj)
        @test occursin("\"kind\":\"abs\"", aj)
        @test occursin("\"got\":0.5,\"want\":0.0", aj)
        @test occursin("\"pass\":false", aj)
        @test occursin("\"pass\":true", aj)
        # the existing page object is intact (additive contract): status still present
        @test occursin("\"status\":\"benchmark\"", aj)

        am = read(joinpath(tmp, "a", "agent.md"), String)
        @test occursin("2/3 FAIL", am)
        @test occursin("[FAIL] G2", am)

        # ----- gallery backend (the fixed test-report UI) -----
        g = read(Pinax.render(; out=joinpath(tmp, "g"), theme=:gallery), String)
        @test occursin("pinax-benchmark", g)
        @test occursin("pinax-verdict-fail", g)
        @test occursin("AA TL test set   2/3 FAIL", g)   # verdict band text
        @test occursin("class=\"pinax-checks\"", g)
        # one row per check (3 checks)
        @test count("<tr class=\"pinax-pass\"", g) == 2
        @test count("<tr class=\"pinax-fail\"", g) == 1
        @test occursin("energy density e", g)
        @test occursin("gap", g)
    end

    @testset "all-pass -> PASS verdict" begin
        tmp = mktempdir()
        Pinax.reset!(; title="T")
        @benchmark :ok "all good" begin
            @expect "A" "a" got = 1.0 want = 1.0 tol = 1e-3
            @expect "B" "b" got = 0.0 tol = 1e-3
        end
        Pinax.render(; out=joinpath(tmp, "a"), theme=:agent)
        aj = read(joinpath(tmp, "a", "agent.json"), String)
        @test occursin("\"verdict\":\"PASS\"", aj)
        @test occursin("\"passed\":2", aj)
        @test occursin("\"failed\":[]", aj)
        g = read(Pinax.render(; out=joinpath(tmp, "g"), theme=:gallery), String)
        @test occursin("pinax-verdict-pass", g)
        @test occursin("all good   2/2 PASS", g)
    end

    @testset "figures render below the report" begin
        tmp = mktempdir()
        svg = joinpath(tmp, "o.svg")
        write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
        Pinax.reset!(; title="T")
        @benchmark :b "bench with figure" begin
            @expect "E" "e" got = 1.0 want = 1.0 tol = 1e-3
            @figure svg
            @caption "FIGBELOW"
        end
        g = read(Pinax.render(; out=joinpath(tmp, "g"), theme=:gallery), String)
        # the verdict band precedes the figure (report leads, figures follow)
        @test first(findfirst("pinax-verdict", g)) < first(findfirst("FIGBELOW", g))
        @test occursin("class=\"figgrid", g)
    end

    @testset "latex renders a tabular + verdict line" begin
        tmp = mktempdir()
        Pinax.reset!(; title="T")
        @benchmark :b "bench" begin
            @expect "E1" "e" got = 1.0 want = 1.0 tol = 1e-3
            @expect "G2" "g" got = 0.5 want = 0.0 tol = 1e-3
        end
        lx = read(Pinax.render(; out=joinpath(tmp, "l"), theme=:latex), String)
        @test occursin("\\begin{tabular}", lx)
        @test occursin("Verdict: FAIL", lx)
        @test occursin("PASS", lx)
        @test occursin("FAIL", lx)
    end

    @testset "emit_check is an overridable dispatch point" begin
        tmp = mktempdir()
        Pinax.reset!(; title="x")
        @benchmark :b "B" begin
            @expect "E" "e" got = 1.0 want = 1.0 tol = 1e-3
        end
        Pinax.render(; out=joinpath(tmp, "a"), theme=CheckOverrideAgent())
        j = read(joinpath(tmp, "a", "agent.json"), String)
        @test occursin("\"custom_chk\":\"E\"", j)   # override fired via _agent_benchmark! dispatch
    end

    @testset "@expect outside a container errors" begin
        Pinax.reset!()
        @test_throws ErrorException Pinax._push_check!(;
            id=:x, label="y", got=1.0, tol=1e-3
        )
    end
end
