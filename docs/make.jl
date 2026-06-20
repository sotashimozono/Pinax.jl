ENV["GKSwstype"] = "100"   # headless GR backend for compiling the example gallery

using Pinax
using Documenter
using Downloads
using Literate

const GALLERY_JL = joinpath(@__DIR__, "literate", "gallery.jl")

# The "Examples" page shows the gallery script's source verbatim (plain `julia` blocks, NOT
# executed). The gallery itself is compiled separately (below) and linked from the top of the page.
let
    link =
        "\n```@raw html\n<p style=\"margin:.4rem 0 1.2rem\"><a href=\"../gallery/\">" *
        "<b>▶ Open the compiled gallery</b></a> — a thumbnail index with one page per example.</p>\n```\n"
    add_link = function (content)
        i = findfirst('\n', content)
        return if i === nothing
            content * link
        else
            content[1:i] * link * content[(i + 1):end]
        end
    end
    Literate.markdown(
        GALLERY_JL,
        joinpath(@__DIR__, "src");
        name="examples",
        documenter=false,   # plain ```julia fences, not @example
        execute=false,      # do not run during page generation
        credit=false,
        postprocess=add_link,
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
    format=Documenter.HTML(;
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
    ),
    modules=[Pinax],
    pages=["Home" => "index.md", "Examples" => "examples.md", "API Reference" => "api.md"],
)

# Compile the gallery by RUNNING the script with the build directory as the working directory, so
# `render(out="gallery")` writes build/gallery/ (a multi-page gallery: index.html of thumbnail cards
# plus one HTML page per @page) for deploy. A fresh module keeps its definitions out of Main.
let build = joinpath(@__DIR__, "build")
    cd(build) do
        Base.include(Module(:PinaxGallery), GALLERY_JL)
    end
end

deploydocs(;
    versions=["stable", "dev"],
    repo="github.com/sotashimozono/Pinax.jl.git",
    devbranch="main",
    push_preview=true,
)
