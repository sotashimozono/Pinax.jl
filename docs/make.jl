ENV["GKSwstype"] = "100"   # headless GR backend for the Plots-based @example gallery

using Pinax
using Documenter
using Downloads

assets_dir = joinpath(@__DIR__, "src", "assets")
mkpath(assets_dir)
favicon_path = joinpath(assets_dir, "favicon.ico")
logo_path = joinpath(assets_dir, "logo.png")

Downloads.download("https://github.com/sotashimozono.png", favicon_path)
Downloads.download("https://github.com/sotashimozono.png", logo_path)

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
    pages=["Home" => "index.md"],
)

deploydocs(;
    versions=["stable", "dev"],
    repo="github.com/sotashimozono/Pinax.jl.git",
    devbranch="main",
    push_preview=true,
)
