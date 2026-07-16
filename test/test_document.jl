using Pinax
using Test

const SIDE = Ref(0)   # for checking @figure deferral

@testset "document model (structure pass)" begin
    @testset "tree shape" begin
        Pinax.reset!()
        @page :eq "Thermal Equilibrium" begin
            @section :energy "Energy vs T" begin
                @desc md"intent $E=\langle H\rangle$"
                @figure 1 + 1
                @figure 2 + 2
            end
            @section :conv "Convergence" by = "system.g" begin
                @figure 3 + 3
            end
        end
        doc = Pinax.current_document()
        @test length(doc.pages) == 1
        pg = doc.pages[1]
        @test pg.id === :eq
        @test pg.title == "Thermal Equilibrium"
        @test pg.anchor == "eq"
        @test length(pg.sections) == 2
        @test pg.sections[1].id === :energy
        @test pg.sections[2].id === :conv
        @test length(pg.sections[1].figures) == 2
        @test length(pg.sections[2].figures) == 1
        @test pg.sections[2].facet == "system.g"
        @test pg.sections[1].desc isa Pinax.Desc
        @test occursin("langle", pg.sections[1].desc.source)
    end

    @testset "@figure is deferred" begin
        SIDE[] = 0
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure begin
                    SIDE[] += 1
                    42
                end
            end
        end
        fig = Pinax.current_document().pages[1].sections[1].figures[1]
        @test SIDE[] == 0                 # build did NOT evaluate the plot expr
        @test fig.gen() == 42             # materialize on demand
        @test SIDE[] == 1                 # side effect ran exactly once
        @test occursin("42", fig.code)    # source captured for change detection
    end

    @testset "ids: auto vs explicit" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure 1
                @figure 2 id = :custom
            end
        end
        figs = Pinax.current_document().pages[1].sections[1].figures
        @test figs[1].id === :s_fig1
        @test figs[1].anchor == "s_fig1"
        @test figs[2].id === :custom
    end

    @testset "params lineage" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure 1 params = (N=8, g=0.5)
            end
        end
        fig = Pinax.current_document().pages[1].sections[1].figures[1]
        @test fig.params == (N=8, g=0.5)
    end

    @testset "caption: @caption, precedence, diagnostics" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure 1 caption = "kw"
                @caption md"override"      # wins
                @figure 2 caption = "only" # no @caption -> caption= stays
            end
        end
        figs = Pinax.current_document().pages[1].sections[1].figures
        @test figs[1].caption == "override"
        @test figs[2].caption == "only"

        # @caption in a section with no figure is non-fatal -> WARNING
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @caption md"orphan"
            end
        end
        diag = Pinax.current_document().diag.entries
        @test any(e -> e.severity == Pinax.WARNING && occursin("caption", e.message), diag)
    end

    @testset "thumbnail resolution (explicit > marker > top > none)" begin
        Pinax.reset!()
        @page :a "A" begin
            @thumbnail :picked
            @section :s "S" begin
                @figure 1
            end
        end
        @page :b "B" begin
            @section :s "S" begin
                @figure 1
                @figure 2 thumbnail = true
            end
        end
        @page :c "C" begin
            @section :s "S" begin
                @figure 1
                @figure 2
            end
        end
        @page :d "D" begin
            @no_thumbnail
            @section :s "S" begin
                @figure 1
            end
        end
        pgs = Pinax.current_document().pages
        @test Pinax.resolved_thumbnail(pgs[1]) == Pinax.FigRef(:picked)      # explicit
        @test Pinax.resolved_thumbnail(pgs[2]) ==
            Pinax.FigRef(pgs[2].sections[1].figures[2].id)  # marker
        @test Pinax.resolved_thumbnail(pgs[3]) ==
            Pinax.FigRef(pgs[3].sections[1].figures[1].id)  # top
        @test Pinax.resolved_thumbnail(pgs[4]) === nothing                    # @no_thumbnail
    end

    @testset "section kwargs: summary, layout" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" summary = "blurb" layout = :wide begin
                @figure 1
            end
        end
        sec = Pinax.current_document().pages[1].sections[1]
        @test sec.summary == "blurb"
        @test sec.layout === :wide
    end

    @testset "preamble: @pinaxsetup / @debug_mode / @bibliography / @newcommand" begin
        Pinax.reset!()
        @pinaxsetup theme = :gallery debug = true numbering = :page index = :rich
        m = Pinax.current_document().meta
        @test m.theme === :gallery
        @test m.debug
        @test m.numbering === :page
        @test m.index === :rich

        # theme-specific kw (css/js/features) are ignored in the structure layer (not an error)
        @pinaxsetup theme = :gallery css = ["x.css"] js = ["y.js"] features = (:comments,)
        @test Pinax.current_document().meta.theme === :gallery

        Pinax.reset!()
        @debug_mode true
        @test Pinax.current_document().meta.debug

        Pinax.reset!()
        @bibliography "a.bib" "b.bib"
        @test Pinax.current_document().meta.bib_sources == ["a.bib", "b.bib"]

        Pinax.reset!()
        @newcommand raw"\E" raw"\langle H\rangle"
        @test Pinax.current_document().newcommands[raw"\E"] == raw"\langle H\rangle"
    end

    @testset "md\"…\" preserves \$ and backslash" begin
        s = md"E = $H$ and \alpha"
        @test s == raw"E = $H$ and \alpha"
    end

    @testset "document() do-block isolates global state" begin
        Pinax.reset!()
        outer = Pinax.current_document()
        doc = Pinax.document() do
            @page :scoped "S" begin
                @section :s "S" begin
                    @figure 1
                end
            end
        end
        @test length(doc.pages) == 1
        @test doc.pages[1].id === :scoped
        @test Pinax.current_document() === outer   # global state restored
    end

    @testset "misuse errors" begin
        # Inside a testset, a content macro with no container open is invariant-V test-content: it
        # no-ops (returns nothing, adds nothing) rather than erroring, so a bare `Pkg.test()` with a
        # stray `@figure` in a test can never break. The manuscript-misuse error still fires at depth
        # 0 — a docs build script — where the content seam is not inert.
        Pinax.reset!()
        @test (@figure 1) === nothing                         # @figure outside @section → inert no-op
        @test isempty(Pinax.current_document().pages)         # …and nothing was added
        # A structure macro resolves against CTX directly (not the content seam), so it still errors.
        Pinax.reset!()
        @test_throws ErrorException (@section :s "S" begin
            @figure 1
        end)                                                  # @section outside @page
    end
end
