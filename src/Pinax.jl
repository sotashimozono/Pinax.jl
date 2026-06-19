module Pinax

using ParamIO
using DataVault
using TOML
using Markdown: Markdown
using Bibliography: Bibliography

# Design spec lives in notes/ (00–10).
# Implemented incrementally: document model + structure macros -> resolve -> render -> cache -> theme …

include("document.jl")   # document model + structure macros (pass 1)
include("backends.jl")   # figure backend abstraction (pinax_save / is_figure)
include("cache.jl")      # incremental render: cache key + manifest + orphan cleanup (notes 10)
include("cite.jl")       # BibTeX parsing for @cite / @bibliography (notes 03)
include("comments.jl")   # id-keyed annotation store (gallery comment layer, notes 01 §4)
include("theme.jl")      # theme = renderer (GalleryTheme)
include("render.jl")     # render driver (pass 2 resolve + pass 3 materialize/emit)

# structure macros (the manuscript DSL)
export @pinaxsetup,
    @debug_mode,
    @bibliography,
    @newcommand,
    @page,
    @section,
    @figure,
    @caption,
    @desc,
    @raw,
    @thumbnail,
    @no_thumbnail,
    @md_str

# render / theme / backend contract
export render, Theme, GalleryTheme, register_theme!, pinax_save, is_figure

# comment store (CLI / LLM-loop substrate)
export read_comments, add_comment, set_bookmark!

end # module Pinax
