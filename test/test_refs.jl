using Pinax
using Test

@testset "references and numbering" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    sitedir(name) = joinpath(tmp, name)

    @testset "sections and figures are numbered (continuous by default)" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :a "Alpha" begin
                @figure svg
                @figure svg
            end
            @section :b "Beta" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=sitedir("num")), String)
        @test occursin("Sec. 1", html)
        @test occursin("Sec. 2", html)
        @test occursin("Fig. 1", html)
        @test occursin("Fig. 2", html)
        @test occursin("Fig. 3", html)   # continuous across sections
    end

    @testset "@ref(:id) resolves to a numbered link" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :intro "Intro" begin
                @desc md"see @ref(:results) and figure @ref(:keyfig)"
            end
            @section :results "Results" begin
                @figure svg id = :keyfig
            end
        end
        html = read(Pinax.render(; out=sitedir("ref")), String)
        @test occursin("<a href=\"#results\">Sec. 2</a>", html)
        @test occursin("<a href=\"#keyfig\">Fig. 1</a>", html)
    end

    @testset "[text](@ref :id) keeps its link text" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :a "A" begin
                @desc md"jump to [the results](@ref :b)"
            end
            @section :b "B" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=sitedir("mdref")), String)
        @test occursin("<a href=\"#b\">the results</a>", html)
    end

    @testset "@ref works inside a caption" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :a "A" begin
                @figure svg id = :first
                @figure svg
                @caption md"compare with @ref(:first)"
            end
        end
        html = read(Pinax.render(; out=sitedir("capref")), String)
        @test occursin("<a href=\"#first\">Fig. 1</a>", html)
    end

    @testset "unknown @ref -> [?] placeholder + diagnostic" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :a "A" begin
                @desc md"see @ref(:ghost)"
            end
        end
        html = read(Pinax.render(; out=sitedir("badref")), String)
        @test occursin("[?]", html)
        @test occursin("unknown id :ghost", html)
    end

    @testset "numbering=:page restarts each page" begin
        @pinaxsetup numbering = :page   # also resets the implicit document
        @page :p1 "P1" begin
            @section :a "A" begin
                @figure svg
            end
        end
        @page :p2 "P2" begin
            @section :b "B" begin
                @figure svg
            end
        end
        dir = dirname(Pinax.render(; out=sitedir("perpage")))   # multi-page -> one file per page
        html = join(
            read(f, String) for
            f in filter(f -> endswith(f, ".html"), readdir(dir; join=true))
        )
        @test count("Fig. 1", html) == 2
        @test count("Sec. 1", html) == 2
    end

    @testset "preamble can override the numberer (prefix change)" begin
        nb(kind, c) = kind === :figure ? "Figure $(c.figure)" : "Section $(c.section)"
        @pinaxsetup numberer = nb
        @page :p "P" begin
            @section :a "A" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=sitedir("numbA")), String)
        @test occursin("Figure 1", html)
        @test occursin("Section 1", html)
        @test !occursin("Fig. 1", html)   # default labels replaced
    end

    @testset "preamble numberer supports hierarchical numbers" begin
        nb(kind, c) =
            kind === :figure ? "Fig. $(c.section).$(c.subfigure)" : "Sec. $(c.section)"
        @pinaxsetup numberer = nb
        @page :p "P" begin
            @section :a "A" begin
                @figure svg
                @figure svg
            end
            @section :b "B" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=sitedir("numbB")), String)
        @test occursin("Fig. 1.1", html)
        @test occursin("Fig. 1.2", html)
        @test occursin("Fig. 2.1", html)   # per-section subfigure counter
    end

    @testset "@ref uses the overridden labels" begin
        nb(kind, c) = kind === :figure ? "Plot $(c.figure)" : "Part $(c.section)"
        @pinaxsetup numberer = nb
        @page :p "P" begin
            @section :a "A" begin
                @desc md"see the plot @ref(:k)"
                @figure svg id = :k
            end
        end
        html = read(Pinax.render(; out=sitedir("numref")), String)
        @test occursin("<a href=\"#k\">Plot 1</a>", html)
    end

    @testset "numberer receives page context (per-part section prefixes)" begin
        nb(kind, c) =
            if kind === :section
                (c.page_id === :eq ? "EQ$(c.section)" : "GQ$(c.section)")
            else
                "Fig. $(c.figure)"
            end
        @pinaxsetup numbering = :page numberer = nb
        @page :eq "Thermal" begin
            @section :a "A" begin
                @figure svg
            end
            @section :b "B" begin
                @figure svg
            end
        end
        @page :gq "Quench" begin
            @section :c "C" begin
                @figure svg
            end
        end
        dir = dirname(Pinax.render(; out=sitedir("partnum")))   # multi-page -> one file per page
        html = join(
            read(f, String) for
            f in filter(f -> endswith(f, ".html"), readdir(dir; join=true))
        )
        @test occursin("EQ1", html)
        @test occursin("EQ2", html)
        @test occursin("GQ1", html)    # section counter reset per page + page-derived prefix
        @test !occursin("EQ3", html)
    end
end
