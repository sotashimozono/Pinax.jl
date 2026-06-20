using Pinax
using Test

# `Pinax.contents` builds a cross-gallery meta-index: a standalone page linking to several
# independently rendered galleries' index.html files. It reuses the gallery card/toc markup.
@testset "contents: cross-gallery meta-index" begin
    tmp = mktempdir()
    sitedir(name) = joinpath(tmp, name)

    entries = [
        (;
            title="Thermal",
            href="thermal/index.html",
            summary="Equilibrium TPQ",
            thumbnail="thermal/cv.svg",
            meta="3 pages · 40 figures",
            items=["Heat capacity", "Entropy"],
        ),
        (; title="Quench", href="quench/index.html"),   # only the required fields
    ]

    @testset "returns the written index.html path" begin
        path = Pinax.contents(entries; out=sitedir("c1"), title="Atlas")
        @test path == joinpath(sitedir("c1"), "index.html")
        @test isfile(path)
    end

    @testset "default :cards renders a card per entry" begin
        html = read(Pinax.contents(entries; out=sitedir("c2"), title="Atlas"), String)
        @test occursin("<title>Atlas</title>", html)
        @test occursin("2 galleries", html)
        @test occursin("<div class=\"pinax-cards\">", html)
        @test occursin("<a class=\"pinax-card\" href=\"thermal/index.html\">", html)
        @test occursin("<a class=\"pinax-card\" href=\"quench/index.html\">", html)
        @test occursin("<div class=\"card-title\">Thermal</div>", html)
        @test occursin("<div class=\"card-summary\">Equilibrium TPQ</div>", html)
        @test occursin("<img src=\"thermal/cv.svg\"", html)            # thumbnail referenced as-is
        @test occursin("<div class=\"card-meta\">3 pages · 40 figures</div>", html)
        # the bare entry: empty thumb, no summary, no meta
        @test occursin("card-thumb card-thumb-empty", html)
        @test count("<div class=\"card-summary\">", html) == 1         # only Thermal has one
        @test !occursin("<div class=\"card-sections\">", html)         # items shown only at :rich
    end

    @testset "level=:rich lists each entry's items" begin
        html = read(
            Pinax.contents(entries; out=sitedir("c3"), title="Atlas", level=:rich), String
        )
        @test occursin("<div class=\"card-sections\">", html)
        @test occursin("<div class=\"sec-item\">Heat capacity</div>", html)
        @test occursin("<div class=\"sec-item\">Entropy</div>", html)
        @test occursin("<div class=\"card-summary\">Equilibrium TPQ</div>", html)  # still shown
    end

    @testset "level=:toc is a compact link list, not cards" begin
        html = read(
            Pinax.contents(entries; out=sitedir("c4"), title="Atlas", level=:toc), String
        )
        @test occursin("<ul class=\"pinax-toc\">", html)
        @test !occursin("<div class=\"pinax-cards\">", html)
        @test occursin("<a href=\"thermal/index.html\">Thermal</a>", html)
        @test occursin("<span class=\"toc-summary\">— Equilibrium TPQ</span>", html)
        @test occursin("<span class=\"toc-meta\">(3 pages · 40 figures)</span>", html)
    end

    @testset "HTML in fields is escaped" begin
        html = read(
            Pinax.contents(
                [(; title="A & B", href="a.html", summary="x<y")]; out=sitedir("c5")
            ),
            String,
        )
        @test occursin("A &amp; B", html)
        @test occursin("x&lt;y", html)
    end

    @testset "errors: missing required field and bad level" begin
        @test_throws ErrorException Pinax.contents([(; title="no href")]; out=sitedir("e1"))
        @test_throws ErrorException Pinax.contents(
            [(; title="A", href="a.html")]; out=sitedir("e2"), level=:bogus
        )
    end
end
