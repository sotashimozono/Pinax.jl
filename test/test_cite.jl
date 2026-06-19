using Pinax
using Test

@testset "@cite / @bibliography (plain bibtex)" begin
    tmp = mktempdir()
    site(n) = joinpath(tmp, n)
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")

    # One real entry (no DOI/URL in the source); the rest are obviously-synthetic placeholders used
    # only to exercise the link-formatting branches — never real-looking citations with fake DOIs.
    bibpath = joinpath(tmp, "refs.bib")
    write(
        bibpath,
        """
@article{shimozono2026environment,
  title={Environment-matrix-product operator for boundary-free large-scale quantum many-body simulations},
  author={Shimozono, Souta and Hotta, Chisa},
  journal={Physical Review B},
  volume={113},
  number={24},
  pages={245116},
  year={2026},
  publisher={APS}
}

@article{example_doi,
  author = {Example, Ada},
  title = {A placeholder entry with a DOI},
  journal = {Journal of Examples},
  year = {2021},
  doi = {10.0000/example.doi},
}

@article{example_url,
  author = {Placeholder, Pat},
  title = {A placeholder entry with a URL},
  journal = {Journal of Placeholders},
  year = {2020},
  url = {https://example.com/pat},
}

@misc{example_arxiv,
  author = {Test, Terry},
  title = {A placeholder preprint},
  eprint = {0000.00001},
  year = {2024},
}
""",
    )

    @testset "parse_bib parses entries and fields" begin
        bib = Pinax.parse_bib(bibpath)
        e = bib[:shimozono2026environment]
        @test e.year == "2026"
        @test occursin("Environment-matrix-product operator", e.title)
        @test occursin("Shimozono", e.authors) && occursin("Hotta", e.authors)
        @test e.venue == "Physical Review B"
        @test Pinax.bib_link(e) === nothing   # no DOI/URL/eprint in the source -> no link
    end

    @testset "@cite renders [n] linked to a References entry" begin
        Pinax.reset!()
        @bibliography bibpath
        @page :p "P" begin
            @section :s "S" begin
                @desc md"Built on @cite(:shimozono2026environment)."
            end
        end
        html = read(Pinax.render(; out=site("c1")), String)
        @test occursin("<a href=\"#ref-shimozono2026environment\">[1]</a>", html)
        @test occursin("id=\"bibliography\"", html)
        @test occursin("id=\"ref-shimozono2026environment\"", html)
        @test occursin("Shimozono", html)
        @test occursin("<a href=\"#bibliography\">References</a>", html)   # nav link
    end

    @testset "citation numbering by first appearance; repeat keeps the number" begin
        Pinax.reset!()
        @bibliography bibpath
        @page :p "P" begin
            @section :s "S" begin
                @desc md"@cite(:example_url), @cite(:shimozono2026environment), @cite(:example_url)"
            end
        end
        html = read(Pinax.render(; out=site("c2")), String)
        @test occursin("<a href=\"#ref-example_url\">[1]</a>", html)                # first -> 1
        @test occursin("<a href=\"#ref-shimozono2026environment\">[2]</a>", html)   # second -> 2
        @test count("id=\"ref-example_url\"", html) == 1                            # deduped
    end

    @testset "[text](@cite key) keeps its link text" begin
        Pinax.reset!()
        @bibliography bibpath
        @page :p "P" begin
            @section :s "S" begin
                @desc md"see [Shimozono and Hotta](@cite shimozono2026environment)"
            end
        end
        html = read(Pinax.render(; out=site("c3")), String)
        @test occursin(
            "<a href=\"#ref-shimozono2026environment\">Shimozono and Hotta</a>", html
        )
    end

    @testset "doi / url / arXiv links in the bibliography" begin
        Pinax.reset!()
        @bibliography bibpath
        @page :p "P" begin
            @section :s "S" begin
                @desc md"@cite(:example_doi) @cite(:example_url) @cite(:example_arxiv)"
            end
        end
        html = read(Pinax.render(; out=site("c4")), String)
        @test occursin("https://doi.org/10.0000/example.doi", html)
        @test occursin("https://example.com/pat", html)
        @test occursin("https://arxiv.org/abs/0000.00001", html)
    end

    @testset "unknown cite key -> [?] + diagnostic" begin
        Pinax.reset!()
        @bibliography bibpath
        @page :p "P" begin
            @section :s "S" begin
                @desc md"see @cite(:ghost)"
            end
        end
        html = read(Pinax.render(; out=site("c5")), String)
        @test occursin("[?]", html)
        @test occursin("unknown key :ghost", html)
    end

    @testset "no citations -> no References section or nav link" begin
        Pinax.reset!()
        @bibliography bibpath
        @page :p "P" begin
            @section :s "S" begin
                @desc md"no citations here"
            end
        end
        html = read(Pinax.render(; out=site("c6")), String)
        @test !occursin("id=\"bibliography\"", html)
        @test !occursin(">References</a>", html)
    end

    @testset "@cite works in a caption" begin
        Pinax.reset!()
        @bibliography bibpath
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
                @caption md"reproduces @cite(:shimozono2026environment)"
            end
        end
        html = read(Pinax.render(; out=site("c7")), String)
        @test occursin("<a href=\"#ref-shimozono2026environment\">[1]</a>", html)
        @test occursin("id=\"ref-shimozono2026environment\"", html)
    end

    @testset "missing .bib file -> diagnostic (non-fatal)" begin
        Pinax.reset!()
        @bibliography joinpath(tmp, "does_not_exist.bib")
        @page :p "P" begin
            @section :s "S" begin
                @desc md"text"
            end
        end
        html = read(Pinax.render(; out=site("c8")), String)   # must not throw
        @test occursin("file not found", html)
    end
end
