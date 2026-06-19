module Pinax

using ParamIO
using DataVault

# Design spec lives in notes/ (00–10).
# Implemented incrementally: document model + structure macros -> resolve -> render -> cache -> theme …

include("document.jl")   # document model + structure macros (pass 1)
include("backends.jl")   # figure backend abstraction (pinax_save / is_figure)
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
    @thumbnail,
    @no_thumbnail,
    @md_str

# render / theme / backend contract
export render, Theme, GalleryTheme, pinax_save, is_figure

end # module Pinax
