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

# a theme variant that opts OUT of presenting figures as tables (figure_as_table = false)
struct PlainAgent <: Pinax.AgentBase end
Pinax.figure_as_table(::PlainAgent) = false

_has_parse_error(ex) = ex isa Expr && (ex.head === :error || any(_has_parse_error, ex.args))

@testset "backend extension contract" begin
    tmp = mktempdir()

    @testset "figure object -> pinax_save per requested format" begin
        fig = Pinax.Figure(
            :f, "f", "", nothing, () -> MockFig("z"), "code", false, String[], nothing
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
        fig = Pinax.Figure(
            :bad, "bad", "", nothing, () -> 42, "code", false, String[], nothing
        )
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
            :f, "f", "", nothing, () -> MockFig("z"), "code", false, String[], nothing
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
        fig = Pinax.Figure(:g, "g", "", nothing, () -> src, "c", false, String[], nothing)
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
        @test occursin("| series | x | y |", md)   # figure_as_table inlines the data (Phase B)
    end

    @testset "figure_as_table (default agent): figure carries its data table inline" begin
        out = joinpath(tmp, "fat")
        Pinax.reset!(; title="x")
        @page :p "P" begin
            @figure MockFig("z") caption = "f"
        end
        Pinax.render(; out=out, theme=:agent)
        j = read(joinpath(out, "agent.json"), String)
        @test occursin("\"table\":{\"header\":[\"series\",\"x\",\"y\"]", j)   # the figure's data table
        @test occursin("[\"s1\",0.0,10.0]", j)                                # native-typed rows
        @test occursin("\"total\":3", j)
        md = read(joinpath(out, "agent.md"), String)
        @test occursin("| series | x | y |", md)
        @test occursin("| s1 | 0.0 | 10.0 |", md)
    end

    @testset "figure_as_table=false keeps figure as figure (csv reference, no inline table)" begin
        out = joinpath(tmp, "plain")
        Pinax.reset!(; title="x")
        @page :p "P" begin
            @figure MockFig("z") caption = "f"
        end
        Pinax.render(; out=out, theme=PlainAgent())
        j = read(joinpath(out, "agent.json"), String)
        @test occursin("\"table\":null", j)
        md = read(joinpath(out, "agent.md"), String)
        @test occursin("- data table:", md)            # referenced, not inlined
        @test !occursin("| series | x | y |", md)
    end

    @testset "_read_csv_table parses quoted fields + downsamples" begin
        csv = joinpath(tmp, "t.csv")
        write(csv, "# meta\nseries,x,y\n\"a,b\",0.0,1.5\nc,2.0,3.0\n")
        t = Pinax._read_csv_table(csv)
        @test t.header == ["series", "x", "y"]
        @test t.rows[1] == ["a,b", 0.0, 1.5]   # quoted comma; numbers re-typed
        @test t.total == 2
        write(csv, "series,x,y\n" * join(["r$i,$i,$i" for i in 1:100], "\n") * "\n")
        t2 = Pinax._read_csv_table(csv; maxrows=10)
        @test t2.total == 100 && length(t2.rows) <= 10
    end

    @testset "csv round-trip edge cases (review fix)" begin
        @test Pinax._split_csv_line("a,b,") == ["a", "b", ""]                       # trailing empty field
        @test Pinax._split_csv_line("a,,c") == ["a", "", "c"]                       # empty middle field
        @test Pinax._split_csv_line("\"x,y\",z") == ["x,y", "z"]                    # quoted comma
        @test Pinax._split_csv_line("\"say \"\"hi\"\"\",z") == ["say \"hi\"", "z"]  # escaped quote

        csv = joinpath(tmp, "edge.csv")
        write(csv, "series,x,y\n8,0.0,\n8,1.0,2.5\n")   # numeric-looking label + a blank (NaN) y cell
        t = Pinax._read_csv_table(csv)
        @test t.rows[1][1] === "8"        # the series LABEL stays a String (not 8.0)
        @test t.rows[1][3] === missing    # a blank y (a dropped NaN) -> missing, not ""
        @test t.rows[2][3] === 2.5        # a real number is still re-typed
        @test !occursin('\n', Pinax._csv_field("a\nb"))   # writer flattens newlines (no line-spanning field)
    end
end

# `@figure … data=` carries the plotted data eagerly, so the agent backend emits the figure-as-table
# from it WITHOUT calling gen() — i.e. agent.json is producible with no plotting backend. We prove
# gen is never called by making it throw; render(:agent) must still succeed.
@testset "figure data=: agent table without building the plot (Plots-free LLM face)" begin
    tmp = mktempdir()
    Pinax.reset!(; title="d")
    @page :p "P" begin
        @figure error("gen must not run for a data= figure") data = (
            x=[1.0, 2.0, 3.0], y=[10.0, 20.0, 30.0]
        ) caption = "f"
    end
    ap = Pinax.render(; out=joinpath(tmp, "agent"), theme=:agent)   # must NOT throw (gen skipped)
    j = read(ap, String)
    @test occursin("\"table\":{\"header\":[\"series\",\"x\",\"y\"]", j)  # table from data=
    @test occursin("[\"y\",1.0,10.0]", j)                                # native rows, no CSV round-trip
    @test occursin("\"total\":3", j)
    @test occursin("\"assets\":[]", j)                                   # never materialized → no asset
    md = read(joinpath(tmp, "agent", "agent.md"), String)
    @test occursin("| series | x | y |", md)                            # inline md table from data=
    @test occursin("| y | 1.0 | 10.0 |", md)

    # multi-series + the convenience reduces to the same long format
    Pinax.reset!(; title="d2")
    @page :q "Q" begin
        @figure error("no gen") data = (
            series=[(; label="a", x=[0, 1], y=[2, 3]), (; label="b", x=[0, 1], y=[4, 5])],
        )
    end
    j2 = read(Pinax.render(; out=joinpath(tmp, "a2"), theme=:agent), String)
    @test occursin("[\"a\",0,2]", j2) && occursin("[\"b\",1,5]", j2)
end
