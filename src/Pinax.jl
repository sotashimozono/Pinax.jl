module Pinax

using TOML
using Markdown: Markdown
using Bibliography: Bibliography
using Sockets: Sockets

# Design spec lives in notes/ (00–10).
# Implemented incrementally: document model + structure macros -> resolve -> render -> cache -> theme …

include("document.jl")   # document model + structure macros (pass 1)
include("backends.jl")   # figure backend abstraction (pinax_save / is_figure)
include("cache.jl")      # incremental render: cache key + manifest + orphan cleanup (notes 10)
include("cite.jl")       # BibTeX parsing for @cite / @bibliography (notes 03)
include("comments.jl")   # id-keyed annotation store (gallery comment layer, notes 01 §4)
include("theme.jl")      # theme = renderer (GalleryTheme)
include("render.jl")     # render driver (pass 2 resolve + pass 3 materialize/emit)
include("contents.jl")   # cross-gallery meta-index (a "map of contents" one level up)
include("testset.jl")   # render a Julia `Test` suite as a Pinax document (Test -> @page/@section/Check)
include("serve.jl")      # static HTTP preview server (Sockets) for the rendered gallery
include("documenter.jl") # Documenter bridge stub (PinaxDocumenterExt embeds a gallery via @raw html)

# structure macros (the manuscript DSL)
export @pinaxsetup,
    @debug_mode,
    @bibliography,
    @newcommand,
    @part,
    @page,
    @section,
    @figure,
    @table,
    @expect,
    @benchmark,
    @caption,
    @desc,
    @raw,
    @thumbnail,
    @no_thumbnail,
    @md_str

# render / theme / backend contract
export render,
    report,
    rendered_assets,
    sweep_mean,
    contents,
    Theme,
    GalleryBase,
    GalleryTheme,
    LaTeXBase,
    LaTeXTheme,
    AgentBase,
    AgentTheme,
    register_theme!,
    pinax_save,
    is_figure,
    serve,
    documenter_embed,
    documenter_gallery,
    documenter_stage,
    documenter_downloads

# comment store (CLI / LLM-loop substrate)
export read_comments, add_comment, set_bookmark!
export @pinaxignore
export render_test_report, dump_test_report, load_test_dump

end # module Pinax
