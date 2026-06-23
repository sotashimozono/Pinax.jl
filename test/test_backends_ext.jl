using Pinax
using Test

# A fake backend figure that exercises the is_figure / pinax_save extension contract WITHOUT
# pulling in a real plotting backend (Plots/Makie precompile is heavy). The shipped extensions
# (ext/PinaxPlotsExt.jl, ext/PinaxMakieExt.jl) plug in exactly the same way.
struct MockFig
    tag::String
end
Pinax.is_figure(::MockFig) = true
function Pinax.pinax_save(f::MockFig, base, fmt)
    return Pinax._save_with(
        (obj, dest) -> write(dest, "MOCK:$(obj.tag):$(fmt)"), f, base, fmt
    )
end
# a mock plot exposes its plotted data, exercising the `:table` pseudo-format without a real backend
function Pinax._figure_table(::MockFig)
    return (;
        xlabel="t",
        ylabel="v",
        series=[(; label="s1", x=[0.0, 1.0, 2.0], y=[10.0, 11.0, 12.0])],
    )
end

_has_parse_error(ex) = ex isa Expr && (ex.head === :error || any(_has_parse_error, ex.args))

@testset "backend extension contract" begin
    tmp = mktempdir()

    @testset "figure object -> pinax_save per requested format" begin
        fig = Pinax.Figure(
            :f, "f", "", nothing, () -> MockFig("z"), "code", false, String[]
        )
        base = joinpath(tmp, "m", "f")
        out = Pinax._materialize(fig, base, [:svg, :pdf])
        @test out == [string(base, ".svg"), string(base, ".pdf")]
        @test read(out[1], String) == "MOCK:z:svg"
        @test read(out[2], String) == "MOCK:z:pdf"
    end

    @testset "renders a backend figure into the gallery" begin
        outdir = joinpath(tmp, "site")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure MockFig("a") caption = "mock"
            end
        end
        html = read(Pinax.render(; out=outdir), String)
        @test isfile(joinpath(outdir, "assets", "figures", "p", "s", "s_fig1.svg"))
        @test occursin("s_fig1.svg", html)
        @test occursin("mock", html)
    end

    @testset "unknown value still errors (no pinax_save method)" begin
        @test_throws ErrorException Pinax.pinax_save(42, "x", :svg)
    end

    @testset "is_figure dispatch (default false, override true)" begin
        @test Pinax.is_figure(MockFig("x"))
        @test !Pinax.is_figure(42)
        @test !Pinax.is_figure("a/path.svg")
    end

    @testset "_materialize errors on a non-file, non-figure value" begin
        fig = Pinax.Figure(:bad, "bad", "", nothing, () -> 42, "code", false, String[])
        @test_throws ErrorException Pinax._materialize(fig, joinpath(tmp, "bad"), [:svg])
    end

    @testset "_save_with errors when the saver writes no file" begin
        @test_throws ErrorException Pinax._save_with(
            (obj, dest) -> nothing, MockFig("x"), joinpath(tmp, "noop"), :svg
        )
    end

    @testset "shipped extension files are present and parse cleanly" begin
        for f in ("PinaxPlotsExt.jl", "PinaxMakieExt.jl")
            path = joinpath(pkgdir(Pinax), "ext", f)
            @test isfile(path)
            @test !_has_parse_error(Meta.parseall(read(path, String); filename=f))
        end
    end
end

@testset "figure data table" begin
    tmp = mktempdir()

    @testset ":table pseudo-format writes a CSV of the plotted data" begin
        fig = Pinax.Figure(
            :f, "f", "", nothing, () -> MockFig("z"), "code", false, String[]
        )
        base = joinpath(tmp, "f")
        out = Pinax._materialize(fig, base, [:svg, :table])
        @test out == [string(base, ".svg"), string(base, ".csv")]   # image + data table
        csv = read(out[2], String)
        @test occursin("series,x,y", csv)
        @test occursin("s1,0.0,10.0", csv)
        @test occursin("xlabel=t", csv)
    end

    @testset "a pre-made file path exposes no data (no csv)" begin
        src = joinpath(tmp, "p.svg")
        write(src, "<svg/>")
        fig = Pinax.Figure(:g, "g", "", nothing, () -> src, "c", false, String[])
        out = Pinax._materialize(fig, joinpath(tmp, "g"), [:svg, :table])
        @test all(p -> !endswith(p, ".csv"), out)
    end

    @testset "dense series is downsampled with a note" begin
        io = IOBuffer()
        tbl = (;
            xlabel="x",
            ylabel="y",
            series=[(; label="a", x=collect(0.0:9.0), y=collect(0.0:9.0))],
        )
        Pinax._print_csv_table(io, tbl, 3)   # 10 pts, cap 3 -> stride cld(10,3)=4 -> i=1,5,9
        s = String(take!(io))
        @test occursin("downsampled", s)
        @test count("a,", s) == 3
    end

    @testset "agent backend emits the data table as a distinct `data` field" begin
        out = joinpath(tmp, "agent")
        Pinax.reset!(; title="d")
        @page :p "P" begin
            @figure MockFig("a") caption = "m"
        end
        ap = Pinax.render(; out=out, theme=:agent)
        j = read(ap, String)
        @test occursin("\"data\":\"", j)     # distinct field (not lumped into assets)
        @test occursin(".csv\"", j)          # ...pointing at the csv
        md = read(joinpath(out, "agent.md"), String)
        @test occursin("data table:", md)
    end
end
