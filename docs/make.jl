ENV["GKSwstype"] = "100"   # headless GR backend for compiling the example gallery

using Pinax
using Documenter
using Downloads
using Literate

const GALLERY_JL = joinpath(@__DIR__, "literate", "gallery.jl")

# The "Examples" page shows the gallery script's source verbatim (plain `julia` blocks, NOT executed).
# The gallery itself is compiled separately (below); here we EMBED it live at the top of the page via
# the Documenter bridge (PinaxDocumenterExt) — an auto-resizing `@raw html` <iframe> that shows the
# rendered gallery AS-IS, right above the source that produced it (dogfood, roadmap 07). The format is
# defined once and shared with `makedocs`, so `documenter_embed` resolves the site-root `gallery/`
# against `examples.md` via `html_fmt.prettyurls` — correct on the deployed site AND a local build.
const html_fmt = Documenter.HTML(;
    canonical="https://codes.sota-shimozono.com/Pinax.jl/stable/",
    prettyurls=get(ENV, "CI", "false") == "true",
    mathengine=MathJax3(
        Dict(
            :tex => Dict(
                :inlineMath => [["\$", "\$"], ["\\(", "\\)"]],
                :tags => "ams",
                :packages => ["base", "ams", "autoload", "physics"],
            ),
        ),
    ),
    assets=["assets/favicon.ico", "assets/custom.css"],
)

let
    embed =
        "\n" * Pinax.documenter_embed(
            "gallery/", html_fmt; page="examples.md", title="Pinax example gallery"
        )
    add_embed = function (content)
        i = findfirst('\n', content)
        return if i === nothing
            content * embed
        else
            content[1:i] * embed * content[(i + 1):end]
        end
    end
    Literate.markdown(
        GALLERY_JL,
        joinpath(@__DIR__, "src");
        name="examples",
        documenter=false,   # plain ```julia fences, not @example
        execute=false,      # do not run during page generation
        credit=false,
        postprocess=add_embed,
    )
end

assets_dir = joinpath(@__DIR__, "src", "assets")
mkpath(assets_dir)
Downloads.download(
    "https://github.com/sotashimozono.png", joinpath(assets_dir, "favicon.ico")
)
Downloads.download("https://github.com/sotashimozono.png", joinpath(assets_dir, "logo.png"))

makedocs(;
    sitename="Pinax.jl",
    format=html_fmt,
    modules=[Pinax],
    pages=[
        "Home" => "index.md",
        "Examples" => "examples.md",
        "Test → Pinax" => "test2pinax.md",
        "Comments" => "comments.md",
        "API Reference" => "api.md",
    ],
)

# Compile the gallery by RUNNING the script with the build directory as the working directory, so
# `render(out="gallery")` writes build/gallery/ (a multi-page gallery: index.html of thumbnail cards
# plus one HTML page per @page) for deploy. A fresh module keeps its definitions out of Main.
let build = joinpath(@__DIR__, "build")
    # Pull the precomputed heavy media (the Ising DataVault store + spin gif) off the `media` branch
    # so the gallery compile reuses it instead of re-running the Monte Carlo (the build-media workflow
    # keeps `media` up to date). Absent — e.g. media not built yet — the gallery computes it inline.
    try
        run(`git fetch --depth=1 origin media`)
        run(`git --work-tree=$build checkout FETCH_HEAD -- ising_data gallery_media`)
        run(`git reset -q`)   # keep the restored files in build/, drop them from the index
        @info "restored Ising media from the `media` branch"
    catch
        @info "no `media` branch — the gallery will compute the Ising example inline"
    end
    cd(build) do
        return Base.include(Module(:PinaxGallery), GALLERY_JL)
    end
end

deploydocs(;
    versions=["stable", "dev"],
    repo="github.com/QAtlasHub/Pinax.jl.git",
    devbranch="main",
    push_preview=true,
)
