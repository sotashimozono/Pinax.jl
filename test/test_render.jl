using Pinax
using Test

@testset "render walking skeleton" begin
    tmp = mktempdir()
    svg1 = joinpath(tmp, "a.svg")
    write(
        svg1, "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect/></svg>"
    )
    svg2 = joinpath(tmp, "b.svg")
    write(
        svg2,
        "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><circle/></svg>",
    )

    @testset "manuscript with file-path figures -> HTML" begin
        outdir = joinpath(tmp, "site")
        Pinax.reset!()
        @page :eq "Thermal" begin
            @section :energy "Energy vs T" begin
                @desc md"E/N comparison"
                @figure svg1 caption = "panel A"
                @figure svg2
            end
        end
        path = Pinax.render(; out=outdir)

        @test path == joinpath(outdir, "index.html")
        @test isfile(path)
        html = read(path, String)
        @test occursin("Thermal", html)                 # page title
        @test occursin("Energy vs T", html)              # section title
        @test occursin("panel A", html)                  # caption
        @test occursin("id=\"energy\"", html)            # section anchor
        @test occursin("E/N comparison", html)           # desc rendered
        @test occursin("href=\"#energy\"", html)         # index/TOC link

        # assets materialized + referenced (auto ids: <sec>_fig1/2)
        a1 = joinpath(outdir, "assets", "figures", "eq", "energy", "energy_fig1.svg")
        a2 = joinpath(outdir, "assets", "figures", "eq", "energy", "energy_fig2.svg")
        @test isfile(a1)
        @test isfile(a2)
        @test occursin("assets/figures/eq/energy/energy_fig1.svg", html)
        # copied content matches source
        @test read(a1, String) == read(svg1, String)

        # idempotent re-render
        @test Pinax.render(; out=outdir) == path
    end

    @testset "missing figure file -> diagnostics + placeholder (non-fatal)" begin
        out2 = joinpath(tmp, "site2")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure joinpath(tmp, "does_not_exist.svg")
            end
        end
        path = Pinax.render(; out=out2)          # must not throw
        html = read(path, String)
        @test occursin("Diagnostics", html)
        @test occursin("figure failed", html)
        @test occursin("materialize failed", html)        # render-phase diagnostic shown in the page
        @test occursin("does_not_exist", html)
        # render-phase failures are NOT pushed onto doc.diag (so re-render stays idempotent)
        @test isempty(Pinax.current_document().diag.entries)
    end

    @testset "render with no document errors" begin
        @test_throws ErrorException Pinax.render(nothing; out=joinpath(tmp, "x"))
    end

    @testset "resolve! builds label->node refs" begin
        Pinax.reset!()
        @page :pg "P" begin
            @section :sec "S" begin
                @figure svg1 id = :fig
            end
        end
        doc = Pinax.current_document()
        Pinax.resolve!(doc)
        @test doc.refs[:pg] isa Pinax.Page
        @test doc.refs[:sec] isa Pinax.Section
        @test doc.refs[:fig] isa Pinax.Figure
    end

    @testset "HTML-escapes user-supplied strings" begin
        outdir = joinpath(tmp, "esc")
        Pinax.reset!()
        @page :p "A & B <x>" begin
            @section :s "S" begin
                @desc md"<script>alert(1)</script>"
                @figure svg1 caption = "cap & <i>"
            end
        end
        html = read(Pinax.render(; out=outdir), String)
        @test occursin("A &amp; B &lt;x&gt;", html)
        @test occursin("cap &amp; &lt;i&gt;", html)
        @test occursin("&lt;script&gt;", html)
        @test !occursin("<script>alert", html)             # raw script must not survive
    end

    @testset "pdf asset -> <iframe> embed + open link, not <img>" begin
        pdf = joinpath(tmp, "doc.pdf")
        write(pdf, "%PDF-1.4 stub")
        outdir = joinpath(tmp, "pdf")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure pdf
            end
        end
        html = read(Pinax.render(; out=outdir), String)
        @test isfile(joinpath(outdir, "assets", "figures", "p", "s", "s_fig1.pdf"))
        # embedded with the browser's native viewer (notes 04 §3), plus an open/download fallback
        @test occursin(
            "<iframe class=\"pinax-pdf\" src=\"assets/figures/p/s/s_fig1.pdf\"", html
        )
        @test occursin(
            "<a class=\"pinax-open\" href=\"assets/figures/p/s/s_fig1.pdf\"", html
        )
        @test !occursin("s_fig1.pdf\" alt", html)          # not emitted as <img>
    end

    @testset "other (non-embeddable) asset -> <a> link" begin
        csv = joinpath(tmp, "data.csv")
        write(csv, "x,y\n1,2\n")
        outdir = joinpath(tmp, "csv")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure csv
            end
        end
        html = read(Pinax.render(; out=outdir), String)
        @test isfile(joinpath(outdir, "assets", "figures", "p", "s", "s_fig1.csv"))
        @test occursin("<a href=\"assets/figures/p/s/s_fig1.csv\"", html)
        @test !occursin("s_fig1.csv\" alt", html)          # not an <img>
        @test !occursin("<iframe", html)                   # not embedded (the CSS class is always present)
    end

    @testset "non-file, non-figure value -> diagnostic (non-fatal)" begin
        outdir = joinpath(tmp, "badval")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure 42
            end
        end
        html = read(Pinax.render(; out=outdir), String)    # must not throw
        @test occursin("figure failed", html)
        @test occursin("Int", html)                        # error mentions the produced type
    end

    @testset "re-render does not duplicate assets" begin
        outdir = joinpath(tmp, "rerender")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg1
                @figure svg2
            end
        end
        Pinax.render(; out=outdir)
        Pinax.render(; out=outdir)
        @test length(readdir(joinpath(outdir, "assets", "figures", "p", "s"))) == 2
    end

    @testset "unsafe ids are sanitized in paths and anchors" begin
        outdir = joinpath(tmp, "unsafe")
        Pinax.reset!()
        @page Symbol("a/b") "P" begin
            @section :s "S" begin
                @figure svg1
            end
        end
        html = read(Pinax.render(; out=outdir), String)
        # no path traversal: page dir is the sanitized anchor, assets stay under outdir
        @test isdir(joinpath(outdir, "assets", "figures", "a_b", "s"))
        @test occursin("id=\"a_b\"", html)
        @test !occursin("a/b\"", html)                     # raw slash never in an id attribute
    end

    @testset "figure counts: section badge, nav count, header total" begin
        outdir = joinpath(tmp, "counts")
        Pinax.reset!()
        @page :p "P" begin
            @section :a "Alpha" begin
                @figure svg1
                @figure svg2
            end
            @section :b "Beta" begin
                @figure svg1
            end
        end
        html = read(Pinax.render(; out=outdir), String)
        # per-section count badge in the heading (next to the title)
        @test occursin("Alpha <span class=\"nfig\">(2)</span>", html)
        @test occursin("Beta <span class=\"nfig\">(1)</span>", html)
        # nav links carry the same count
        @test occursin(
            "href=\"#a\" style=\"margin-left:1.2rem\">Alpha <span class=\"nfig\">(2)</span>",
            html,
        )
        # document-wide total in the header
        @test occursin("<div class=\"pinax-meta\">3 figures</div>", html)
    end

    @testset "header total figure count is singular for one figure" begin
        outdir = joinpath(tmp, "counts1")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg1
            end
        end
        html = read(Pinax.render(; out=outdir), String)
        @test occursin("<div class=\"pinax-meta\">1 figure</div>", html)
    end

    @testset "@raw injects verbatim HTML between desc and figures" begin
        outdir = joinpath(tmp, "rawpanel")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"intro prose"
                @raw raw"<table class='cov'><tr><td>24</td></tr></table>"
                @figure svg1
            end
        end
        html = read(Pinax.render(; out=outdir), String)
        @test occursin("<table class='cov'><tr><td>24</td></tr></table>", html)  # verbatim
        @test !occursin("&lt;table class='cov'", html)                          # NOT escaped
        di = findfirst("intro prose", html).start
        ti = findfirst("class='cov'", html).start
        fi = findfirst("s_fig1.svg", html).start
        @test di < ti < fi          # desc, then @raw panel, then figures
    end
end
