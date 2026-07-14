using Pinax
using Documenter   # triggers PinaxDocumenterExt (the Documenter bridge, roadmap 07)
using Test

# The extension's internal helpers, for the few white-box checks (path resolution edge cases).
const DOCEXT = Base.get_extension(Pinax, :PinaxDocumenterExt)

@testset "documenter bridge: @raw html iframe embed" begin
    @testset "extension is loaded" begin
        @test DOCEXT !== nothing
    end

    @testset "basic embed wraps the url in an auto-resizing @raw html iframe" begin
        s = documenter_embed("../gallery/")
        @test startswith(s, "```@raw html\n")
        @test endswith(s, "```\n")
        @test occursin("<iframe", s)
        @test occursin("src=\"../gallery/\"", s)
        @test occursin("min-height:420px", s)              # default pre-load floor
        @test occursin("ResizeObserver", s)                # auto-height on content change
        @test occursin("addEventListener(\"load\"", s)     # ...and on (re)load / in-gallery nav
        @test occursin("Open the gallery in a new tab", s) # default fallback link
        @test occursin("id=\"pinax-embed-gallery\"", s)    # id slugged from the url
    end

    @testset "options: fixed height, no link, custom id/title, extra style" begin
        s = documenter_embed(
            "g/index.html"; height=600, new_tab=false, id="mine", title="My gallery"
        )
        @test occursin("height:600px", s)
        @test !occursin("min-height", s)
        @test !occursin("Open the gallery", s)              # link suppressed
        @test occursin("id=\"mine\"", s)
        @test occursin("title=\"My gallery\"", s)

        @test occursin("height:80vh", documenter_embed("g/"; height="80vh"))  # CSS-string height
        @test occursin("background:#fff", documenter_embed("g/"; style="background:#fff"))
    end

    @testset "attributes are HTML-escaped (no attribute break-out)" begin
        s = documenter_embed("g/"; title="a\"b<c>")
        @test occursin("title=\"a&quot;b&lt;c&gt;\"", s)
        @test !occursin("title=\"a\"b", s)
    end

    @testset "distinct urls → distinct iframe ids (two embeds on one page)" begin
        a = documenter_embed("one/")
        b = documenter_embed("two/")
        @test occursin("id=\"pinax-embed-one\"", a)
        @test occursin("id=\"pinax-embed-two\"", b)
    end

    # The Documenter.HTML-aware form: a SITE-ROOT url resolved against the page, honoring prettyurls.
    @testset "prettyurls-aware url resolution (Documenter.HTML)" begin
        pretty = Documenter.HTML(; prettyurls=true)
        plain = Documenter.HTML(; prettyurls=false)

        # top-level page: prettyurls → examples/index.html (needs ../), plain → examples.html (root)
        @test occursin(
            "src=\"../gallery/\"", documenter_embed("gallery/", pretty; page="examples.md")
        )
        @test occursin(
            "src=\"gallery/\"", documenter_embed("gallery/", plain; page="examples.md")
        )

        # nested page goes one dir deeper under each setting
        @test occursin(
            "src=\"../../gallery/\"",
            documenter_embed("gallery/", pretty; page="man/examples.md"),
        )
        @test occursin(
            "src=\"../gallery/\"",
            documenter_embed("gallery/", plain; page="man/examples.md"),
        )

        # index.md stays at its directory's level; a root-absolute url is passed through untouched
        @test occursin(
            "src=\"gallery/\"", documenter_embed("gallery/", pretty; page="index.md")
        )
        @test occursin(
            "src=\"/gallery/\"", documenter_embed("/gallery/", pretty; page="man/x.md")
        )

        # kwargs still forward through the 2-arg form
        @test occursin(
            "id=\"z\"", documenter_embed("gallery/", pretty; page="index.md", id="z")
        )
    end

    @testset "_relativize unit table" begin
        rel = DOCEXT._relativize
        @test rel("g/", "examples.md", true) == "../g/"
        @test rel("g/", "examples.md", false) == "g/"
        @test rel("g/", "a/b.md", true) == "../../g/"
        @test rel("g/", "a/b.md", false) == "../g/"
        @test rel("g/", "index.md", true) == "g/"
        @test rel("g/", "a/index.md", true) == "../g/"
        @test rel("/g/", "a/b.md", true) == "/g/"      # already root-absolute
    end
end

# Render a tiny gallery from pre-made file-path figures (a PDF + an SVG) — no plotting backend needed.
# Returns the gallery dir. `dir` is the render out (assets land under dir/assets/figures/…).
function _mk_gallery(dir; title="T")
    figs = mktempdir()
    pdf = joinpath(figs, "r.pdf")
    svg = joinpath(figs, "s.svg")
    write(pdf, "%PDF-1.1\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n")
    write(svg, "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"5\"/></svg>")
    Pinax.reset!(; title=title)
    @page :demo "Demo" begin
        @section :s "S" begin
            @figure pdf caption = "a pdf"
            @figure svg caption = "an svg"
        end
    end
    Pinax.render(; out=dir)
    return dir
end

@testset "rendered_assets: identify a render's output paths (incl. PDFs)" begin
    dir = _mk_gallery(joinpath(mktempdir(), "g"))
    paths = rendered_assets(dir)
    @test any(a -> endswith(a, "s_fig1.pdf"), paths)   # the pdf output
    @test any(a -> endswith(a, "s_fig2.svg"), paths)   # the svg output
    @test rendered_assets(dir; ext="pdf") == filter(a -> endswith(a, ".pdf"), paths)
    @test rendered_assets(dir; ext=".pdf") == rendered_assets(dir; ext="pdf")  # leading dot ok
    abss = rendered_assets(dir; ext="pdf", absolute=true)
    @test all(isabspath, abss) && all(isfile, abss)
    @test rendered_assets(joinpath(mktempdir(), "nope")) == String[]           # no manifest → []
    @test issorted(paths) && allunique(paths)
end

@testset "documenter_gallery: run a manuscript .jl → render → wiring" begin
    root = mktempdir()
    src = joinpath(root, "src")
    mkpath(src)
    man = joinpath(root, "m")
    mkpath(man)
    # a PURE manuscript that references its figures by RELATIVE path (resolved against workdir)
    write(
        joinpath(man, "story.jl"),
        """
        using Pinax
        @page :demo "Demo" begin
            @section :s "S" begin
                @figure "r.pdf" caption="pdf"
                @figure "s.svg" caption="svg"
            end
        end
        """,
    )
    staged = Ref(false)
    prep = function ()
        staged[] = true
        write(joinpath(man, "r.pdf"), "%PDF-1.1\ntrailer<</Root 1 0 R>>\n%%EOF\n")
        return write(joinpath(man, "s.svg"), "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")
    end
    fmt = Documenter.HTML(; prettyurls=false)
    res = documenter_gallery(
        joinpath(man, "story.jl");
        out="gallery",
        src=src,
        workdir=man,
        prepare=prep,
        format=fmt,
        page="index.md",
    )
    @test staged[]                                              # prepare ran before the manuscript
    @test res.dir == abspath(joinpath(src, "gallery"))
    @test res.siteroot == "gallery/"
    @test isfile(joinpath(res.dir, "index.html"))              # gallery rendered
    @test occursin("src=\"gallery/\"", res.embed)              # embed wired, prettyurls=false
    # figures actually materialized (the deferred gen ran inside workdir) — the PDF is identified
    @test !isempty(rendered_assets(res.dir; ext="pdf"))
    @test res.assets == rendered_assets(res.dir)
    @test_throws ErrorException documenter_gallery("no_such.jl"; out="g", src=src)
end

@testset "documenter_stage: carry a gitignore'd local gallery into the source tree (B)" begin
    localgal = _mk_gallery(joinpath(mktempdir(), "local"))     # stands in for a gitignored render
    root = mktempdir()
    src = joinpath(root, "src")
    mkpath(src)
    fmt = Documenter.HTML(; prettyurls=false)
    res = documenter_stage(localgal; src=src, out="g", format=fmt, page="index.md")
    @test res.dir == abspath(joinpath(src, "g"))
    @test isfile(joinpath(res.dir, "index.html"))              # whole tree copied
    @test !isempty(rendered_assets(res.dir; ext="pdf"))        # ...assets/PDF carried along
    @test occursin("src=\"g/\"", res.embed)
    @test res.assets == rendered_assets(res.dir)
    # not a rendered gallery → clear error
    empty = mktempdir()
    @test_throws ErrorException documenter_stage(empty; src=src, out="g2")
    @test_throws ErrorException documenter_stage(joinpath(empty, "nope"); src=src, out="g3")
end

@testset "documenter_downloads: @raw html PDF download links (C)" begin
    localgal = _mk_gallery(joinpath(mktempdir(), "local"))
    root = mktempdir()
    src = joinpath(root, "src")
    mkpath(src)
    pretty = Documenter.HTML(; prettyurls=true)
    plain = Documenter.HTML(; prettyurls=false)
    res = documenter_stage(localgal; src=src, out="gallery")

    d = documenter_downloads(res, plain; page="index.md", heading="Reports")
    @test startswith(d, "```@raw html\n") && endswith(d, "```\n")
    @test occursin("<b>Reports</b>", d)
    @test occursin("download>", d)
    @test occursin("href=\"gallery/assets/", d) && occursin(".pdf\"", d)   # plain: no ../
    @test !occursin(".svg\"", d)                                           # default ext=pdf only

    # prettyurls: top-level page sits one dir deep → ../ prefix
    dp = documenter_downloads(res, pretty; page="index.md")
    @test occursin("href=\"gallery/assets/", dp)   # index.md stays at root even under prettyurls
    de = documenter_downloads(res, pretty; page="man/x.md")
    @test occursin("href=\"../../gallery/assets/", de)

    # ext filter + custom label; empty when nothing matches
    dl = documenter_downloads(res, plain; page="index.md", ext="svg", label=(a -> "IMG"))
    @test occursin(">IMG</a>", dl) && occursin(".svg\"", dl)
    @test documenter_downloads(res, plain; page="index.md", ext="zip") == ""
end
