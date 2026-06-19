using Pinax
using Test

@testset "server-side markdown rendering" begin
    tmp = mktempdir()
    site(n) = joinpath(tmp, n)
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")

    @testset "desc: bold / italic / code" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"**bold** and *italic* and `code`"
            end
        end
        html = read(Pinax.render(; out=site("inline")), String)
        @test occursin("<strong>bold</strong>", html)
        @test occursin("<em>italic</em>", html)
        @test occursin("<code>code</code>", html)
        @test !occursin("**bold**", html)   # markdown is rendered, not passed through literally
    end

    @testset "desc: lists and links" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"""
                - one
                - two

                see [the site](https://example.com)
                """
            end
        end
        html = read(Pinax.render(; out=site("list")), String)
        @test occursin("<ul>", html)
        @test occursin("<li>", html)
        @test occursin("<a href=\"https://example.com\">the site</a>", html)
    end

    @testset "desc: pipe table (coverage-table use case)" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"""
                | N | chi |
                |---|-----|
                | 24 | 10 |
                """
            end
        end
        html = read(Pinax.render(; out=site("table")), String)
        @test occursin("<table>", html)
        @test occursin("<td", html)
        @test occursin("24", html)
    end

    @testset "raw HTML in a desc is escaped (safe)" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"<script>alert(1)</script> and <b>x</b>"
            end
        end
        html = read(Pinax.render(; out=site("safe")), String)
        @test occursin("&lt;script&gt;", html)
        @test !occursin("<script>alert", html)
        @test !occursin("<b>x</b>", html)   # author HTML does not pass through
    end

    @testset "markdown coexists with math (display + inline)" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"**Energy** $$ E = \langle H \rangle $$ with inline $x^2$."
            end
        end
        html = read(Pinax.render(; out=site("mathmd")), String)
        @test occursin("<strong>Energy</strong>", html)   # markdown rendered
        @test occursin("\\tag{1}", html)                  # display equation numbered
        @test occursin("class=\"pinax-eq\"", html)
        @test occursin("\$x^2\$", html)                   # inline math left for KaTeX
    end

    @testset "markdown coexists with @ref" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :a "A" begin
                @desc md"**see** @ref(:b) and [there](@ref :b)"
            end
            @section :b "B" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("refmd")), String)
        @test occursin("<strong>see</strong>", html)
        @test occursin("<a href=\"#b\">Sec. 2</a>", html)   # @ref(:b) form
        @test occursin("<a href=\"#b\">there</a>", html)    # [text](@ref :b) form
    end

    @testset "caption markdown is inline (no <p> wrapper)" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
                @caption md"**emph** caption"
            end
        end
        html = read(Pinax.render(; out=site("cap")), String)
        @test occursin("<strong>emph</strong> caption", html)
        @test !occursin("<p><strong>emph</strong>", html)   # caption is not block-wrapped
    end

    @testset "multi-paragraph caption keeps its <p> wrappers (unwrap guard)" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
                @caption "para one.\n\npara two."
            end
        end
        html = read(Pinax.render(; out=site("capmulti")), String)
        @test occursin("<figcaption>", html)
        # two paragraphs -> _unwrap_p must NOT strip; both stay fully wrapped
        @test occursin("<p>para one.</p>", html)
        @test occursin("<p>para two.</p>", html)
    end

    @testset "table + inline math + @ref coexist in one desc" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :a "A" begin
                @desc "| q | f |\n|---|---|\n| 1 | \$x^2\$ |\n\nSee @ref(:b)."
            end
            @section :b "B" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("mixed")), String)
        @test occursin("<table>", html)
        @test occursin("\$x^2\$", html)                     # inline math survived inside a cell
        @test occursin("<a href=\"#b\">Sec. 2</a>", html)   # @ref resolved
        @test !occursin("\\tag", html)                      # inline math not spuriously numbered
    end
end
