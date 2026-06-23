using Pinax
using Test

# `@part` groups pages into a navigation group (a collapsible <details>); each `@page` is its own
# HTML file and may carry figures directly (page-as-leaf, no enclosing `@section`). `numbering=:part`
# resets the page counter per part, so a numberer can stamp per-part page badges (e.g. EQ1.. / GQ1..).
@testset "section hierarchy: @part + page-as-leaf" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    sitedir(name) = joinpath(tmp, name)

    @testset "@part stamps pages and registers the group" begin
        Pinax.reset!()
        @part :thermal "Thermal" begin
            @page :energy "Energy" begin
                @figure svg
            end
            @page :cv "Cv" begin
                @figure svg
            end
        end
        @part :quench "Quench" begin
            @page :dqt "DQT" begin
                @figure svg
            end
        end
        doc = Pinax.current_document()
        @test doc.parts == [:thermal => "Thermal", :quench => "Quench"]
        @test [p.part for p in doc.pages] == [:thermal, :thermal, :quench]
        # page-as-leaf: figures attach to the page, not a section
        @test length(doc.pages[1].figures) == 1
        @test isempty(doc.pages[1].sections)
    end

    @testset "multi-page index groups pages under their @part" begin
        Pinax.reset!()
        @part :thermal "Thermal" begin
            @page :energy "Energy" begin
                @figure svg
            end
        end
        @part :quench "Quench" begin
            @page :dqt "DQT" begin
                @figure svg
            end
        end
        idx = read(Pinax.render(; out=sitedir("grp")), String)
        @test occursin("<details class=\"pinax-group\" open><summary>Thermal", idx)
        @test occursin("<details class=\"pinax-group\" open><summary>Quench", idx)
        # each page became its own file
        @test isfile(joinpath(sitedir("grp"), "energy.html"))
        @test isfile(joinpath(sitedir("grp"), "dqt.html"))
    end

    @testset "numbering=:part + a :page numberer stamps per-part page badges" begin
        nb(kind, c) =
            if kind === :page
                (c.part_id === :thermal ? "EQ$(c.page)" : "GQ$(c.page)")
            elseif kind === :figure
                "Fig. $(c.figure)"
            else
                "($(c.equation))"
            end
        Pinax.reset!(; numbering=:part, numberer=nb)
        @part :thermal "Thermal" begin
            @page :energy "Energy" begin
                @figure svg
            end
            @page :cv "Cv" begin
                @figure svg
            end
        end
        @part :quench "Quench" begin
            @page :dqt "DQT" begin
                @figure svg
            end
        end
        Pinax.render(; out=sitedir("num"))
        @test occursin("EQ1", read(joinpath(sitedir("num"), "energy.html"), String))
        @test occursin("EQ2", read(joinpath(sitedir("num"), "cv.html"), String))
        @test occursin("GQ1", read(joinpath(sitedir("num"), "dqt.html"), String))   # reset per part
    end

    @testset "auto card thumbnail: first figure, no-figure → empty, opt-out" begin
        pdf = joinpath(tmp, "p.pdf")
        write(pdf, "%PDF-1.4\n%stub\n")
        Pinax.reset!()
        @page :a "A" begin
            @figure svg                 # raster asset → <img>
        end
        @page :b "B" begin
            @figure pdf                 # PDF only → lazy mini-preview of the first figure
        end
        @page :c "C" begin
            @desc md"text only"         # no figure → plain "no figure" (empty), not a placeholder glyph
        end
        @page :d "D" begin
            @no_thumbnail
            @figure pdf                 # opted out → empty
        end
        idx = read(Pinax.render(; out=sitedir("thumb")), String)
        @test occursin("<div class=\"card-thumb\"><img src=", idx)        # raster figure → img
        @test occursin("class=\"card-thumb-pdf\"", idx)                   # PDF first-figure mini-preview
        @test occursin("loading=\"lazy\"", idx)                          # only visible cards load
        @test !occursin("card-thumb-ph", idx)                            # no glyph placeholder anymore
        @test occursin("card-thumb card-thumb-empty", idx)               # no-figure page + opt-out → empty
    end

    @testset "a bookmarked figure overrides the first-figure default" begin
        pdf = joinpath(tmp, "q.pdf")
        write(pdf, "%PDF-1.4\n%stub\n")
        Pinax.reset!()
        @page :bm "BM" begin
            @figure svg                 # first figure (raster) — the default thumbnail…
            @figure pdf                 # …but this one is bookmarked, so it should win
        end
        @page :other "Other" begin
            @figure svg
        end
        out = sitedir("bm")
        mkpath(out)
        cf = joinpath(out, "comments.toml")
        write(cf, "[bookmark]\nbm_fig2 = true\n")   # bookmark the 2nd (PDF) figure of :bm
        idx = read(Pinax.render(; out=out, comments_file=cf), String)
        # the only PDF in the doc is :bm's fig2; a PDF preview proves the bookmark beat the first (svg) figure
        @test occursin("class=\"card-thumb-pdf\"", idx)
    end

    @testset "@part desc renders as an overview on the index" begin
        Pinax.reset!()
        @part :thermal "Thermal" desc = md"equilibrium results, **reproducing** prior work" begin
            @page :energy "Energy" begin
                @figure svg
            end
        end
        @part :quench "Quench" desc = md"sudden-quench dynamics" begin
            @page :dqt "DQT" begin
                @figure svg
            end
        end
        @test haskey(Pinax.current_document().part_descs, :thermal)
        idx = read(Pinax.render(; out=sitedir("pd")), String)
        @test occursin("<div class=\"part-desc\">", idx)
        @test occursin("<strong>reproducing</strong>", idx)   # markdown rendered
        @test occursin("sudden-quench dynamics", idx)
    end

    @testset "page summary renders as a subtitle on the page, and on the card" begin
        Pinax.reset!()
        @page :a "A" summary = "スイープ: χ" begin
            @figure svg
        end
        @page :b "B" begin
            @figure svg
        end
        Pinax.render(; out=sitedir("sub"))
        a = read(joinpath(sitedir("sub"), "a.html"), String)
        @test occursin("<p class=\"pinax-subtitle\">スイープ: χ</p>", a)   # on the page
        idx = read(joinpath(sitedir("sub"), "index.html"), String)
        @test occursin("<div class=\"card-summary\">スイープ: χ</div>", idx)  # on the card
    end

    @testset "page-as-leaf @desc/@raw attach to the page" begin
        Pinax.reset!()
        @page :p "P" begin
            @desc md"page level desc"
            @raw "<div class=\"banner\">hi</div>"
            @figure svg
        end
        pg = Pinax.current_document().pages[1]
        @test pg.desc !== nothing && occursin("page level desc", pg.desc.source)
        @test pg.panels == ["<div class=\"banner\">hi</div>"]
        html = read(Pinax.render(; out=sitedir("leaf")), String)   # single page → one index.html
        @test occursin("page level desc", html)
        @test occursin("<div class=\"banner\">hi</div>", html)
    end
end

# `status` tags a page's maturity (`:final` shaped result vs `:trial` raw experiment attempt). Pages
# inherit the enclosing `@part`'s status default unless they override it; the agent backend exposes
# it as `"status"` (RAG/registry filtering) and the gallery badges non-`:final` pages.
@testset "page status: trial vs final" begin
    tmp = mktempdir()
    Pinax.reset!(; title="status")
    @part :proc "Trials" status=:trial begin
        @page :log "Log" begin
            @desc md"raw"
        end
        @page :keep "Keep" status=:final begin   # explicit override inside a trial part
            @desc md"override"
        end
    end
    @page :res "Result" begin
        @desc md"curated"
    end
    pages = Dict(p.id => p for p in Pinax.current_document().pages)
    @test pages[:log].status == :trial       # inherited from the part
    @test pages[:keep].status == :final      # explicit override wins
    @test pages[:res].status == :final       # default outside any part

    ap = Pinax.render(; out=joinpath(tmp, "agent"), theme=:agent)
    j = read(ap, String)
    @test occursin("\"status\":\"trial\"", j)
    @test occursin("\"status\":\"final\"", j)
    md = read(joinpath(tmp, "agent", "agent.md"), String)
    @test occursin("[status: trial]", md)         # trial page marked
    @test !occursin("[status: final]", md)        # default not noised up

    idx = read(
        joinpath(Pinax.render(; out=joinpath(tmp, "site")) |> dirname, "index.html"), String
    )
    @test occursin("card-status", idx)            # gallery badges the trial page
end
