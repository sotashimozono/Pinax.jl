using Pinax
using Test

# A theme variant overriding emit_table — proves the new contract point dispatches like emit_figure.
struct TableOverrideAgent <: Pinax.AgentBase end
function Pinax.emit_table(::TableOverrideAgent, tbl, ctx)
    return print(ctx.io, "{\"custom_tbl\":\"", tbl.id, "\"}")
end

# `@table` — a first-class tabular artifact (sibling to @figure). One node renders to an HTML table
# (gallery), a LaTeX tabular (latex), and structured native-typed rows (agent) — a table is already
# the LLM-native form of data.
@testset "@table primitive" begin
    @testset "input normalization: columns / matrix / row-records" begin
        Pinax.reset!(; title="t")
        @page :p "P" begin
            @table (T=[1.0, 2.0], M=[0.5, 0.6]) caption = "m(t)"
            @section :s "S" begin
                @table [1 2; 3 4] header = ["a", "b"]
                @table [(name="x", v=1), (name="y", v=2)]
            end
        end
        pg = Pinax.current_document().pages[1]
        @test pg.tables[1].header == ["T", "M"]
        @test pg.tables[1].rows == [[1.0, 0.5], [2.0, 0.6]]   # columnar -> row-major
        @test pg.tables[1].caption == "m(t)"
        @test pg.tables[1].id == :p_tbl1
        s = pg.sections[1]
        @test s.tables[1].header == ["a", "b"]                # matrix + explicit header
        @test s.tables[1].rows == [[1, 2], [3, 4]]
        @test s.tables[2].header == ["name", "v"]             # row records -> header from fields
        @test s.tables[2].rows == [["x", 1], ["y", 2]]
    end

    @testset "renders to all three backends" begin
        tmp = mktempdir()
        Pinax.reset!(; title="T")
        @page :p "P" begin
            @table (T=[1.0, 2.0], M=[0.5, 0.6]) caption = "cap"
            @section :s "S" begin
                @table [1 2; 3 4] header = ["a", "b"]
            end
        end
        g = read(Pinax.render(; out=joinpath(tmp, "g"), theme=:gallery), String)
        @test occursin("class=\"pinax-table\"", g)
        @test occursin("<th>T</th>", g)
        @test occursin("<td>0.5</td>", g)

        Pinax.render(; out=joinpath(tmp, "a"), theme=:agent)
        aj = read(joinpath(tmp, "a", "agent.json"), String)
        @test occursin("\"header\":[\"T\",\"M\"]", aj)
        @test occursin("\"rows\":[[1.0,0.5],[2.0,0.6]]", aj)   # native numbers, not strings
        @test occursin("\"tables\":[", aj)                     # section/page tables array
        am = read(joinpath(tmp, "a", "agent.md"), String)
        @test occursin("| T | M |", am)                        # markdown table

        lx = read(Pinax.render(; out=joinpath(tmp, "l"), theme=:latex), String)
        @test occursin("\\begin{tabular}", lx)
        @test occursin("T & M", lx)
    end

    @testset "ragged columns -> missing cell (blank text / null json)" begin
        tmp = mktempdir()
        Pinax.reset!(; title="t")
        @page :p "P" begin
            @table (a=[1, 2], b=[10])   # b shorter -> 2nd row's b is missing
        end
        Pinax.render(; out=joinpath(tmp, "a"), theme=:agent)
        aj = read(joinpath(tmp, "a", "agent.json"), String)
        @test occursin("[2,null]", aj)
    end

    @testset "unsupported input errors clearly" begin
        @test_throws ErrorException Pinax._normalize_table(42, nothing)
    end

    @testset "vector-of-rows + auto header (4th input form)" begin
        h, r = Pinax._normalize_table([[10, 20], [30, 40]], ["x", "y"])
        @test h == ["x", "y"]
        @test r == [[10, 20], [30, 40]]
        h2, r2 = Pinax._normalize_table([(1, 2, 3)], nothing)
        @test h2 == ["1", "2", "3"]   # auto-numbered header
        @test r2 == [[1, 2, 3]]
    end

    @testset "header/row width mismatch errors at build time" begin
        Pinax.reset!()
        @test_throws ErrorException (@page :p "P" begin
            @table [1 2 3; 4 5 6] header = ["a", "b"]   # 3 columns, 2 headers
        end)
        Pinax.reset!()
        @test_throws ErrorException (@page :q "Q" begin
            @table [(1, 2), (3, 4, 5)]                  # ragged rows
        end)
    end

    @testset "cell escaping + missing across HTML/LaTeX" begin
        tmp = mktempdir()
        Pinax.reset!(; title="t")
        @page :p "P" begin
            @table (a=["a&b", missing], b=["c_d", "x"])
        end
        g = read(Pinax.render(; out=joinpath(tmp, "g"), theme=:gallery), String)
        @test occursin("a&amp;b", g)    # & HTML-escaped
        @test occursin("<td></td>", g)  # missing -> blank cell
        lx = read(Pinax.render(; out=joinpath(tmp, "l"), theme=:latex), String)
        @test occursin("a\\&b", lx)     # & LaTeX-escaped
        @test occursin("c\\_d", lx)     # _ LaTeX-escaped
    end

    @testset "emit_table is an overridable dispatch point" begin
        tmp = mktempdir()
        Pinax.reset!(; title="x")
        @page :p "P" begin
            @table (a=[1, 2], b=[3, 4])
        end
        Pinax.render(; out=joinpath(tmp, "a"), theme=TableOverrideAgent())
        j = read(joinpath(tmp, "a", "agent.json"), String)
        @test occursin("\"custom_tbl\":\"p_tbl1\"", j)   # override fired via _agent_tables! dispatch
        @test !occursin("\"header\"", j)                  # default emit_table did NOT run
    end
end
