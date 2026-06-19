# theme.jl — the theme framework (notes 06/08).
#
# A theme is a renderer over the presentation-neutral doc tree. This file is the SHELL: the abstract
# `Theme` type, the renderer contract (the generic functions a theme specializes), a theme registry,
# and resolution from a spec (a `Theme` instance, a registered `Symbol`, or a path to a user theme
# file). Concrete themes live in `themes/` — the default `GalleryTheme` is `themes/gallery.jl`.
#
# Add a theme by subtyping `Theme` and implementing `emit_document` (plus any trait overrides):
#
#     struct MyTheme <: Pinax.Theme end
#     Pinax.emit_document(::MyTheme, doc, out, cache; comments_file="") = ...   # write files, return path
#     Pinax.register_theme!(:mine, MyTheme())          # optional: resolve by @pinaxsetup theme=:mine
#
# then `render(; out, theme=MyTheme())` (or `theme=:mine`, or `theme="path/to/mytheme.jl"`).

abstract type Theme end

# ---- renderer contract (themes override these; only emit_document is required) ----

output_format(::Theme) = :html            # :html | :latex
figure_formats(::Theme) = Symbol[:svg]    # formats requested from figure objects (paths copied as-is)
index_level(::Theme) = :cards             # default table-of-contents verbosity (:toc | :cards | :rich)
number(::Theme, node) = nothing           # optional numbering override (the gallery numbers server-side)

"""
    emit_document(theme, doc, outdir, cache; comments_file) -> path

Render `doc` into `outdir` and return the entry-file path. This is the one method every theme must
implement; `render` dispatches here on the resolved theme.
"""
function emit_document(theme::Theme, doc, outdir, cache; kwargs...)
    return error(
        "Pinax: theme $(typeof(theme)) does not implement `emit_document`. " *
        "Define `Pinax.emit_document(::$(typeof(theme)), doc, outdir, cache; comments_file)`.",
    )
end

# ---- theme registry + resolution ----

const _THEMES = Dict{Symbol,Theme}()

"Register `theme` under `name` so it can be selected with `@pinaxsetup theme=name` / `render(theme=name)`."
register_theme!(name::Symbol, theme::Theme) = (_THEMES[name] = theme)

"""
    _resolve_theme(spec) -> Theme

Resolve a theme spec to a `Theme`: a `Theme` instance is returned as-is; a `Symbol` is looked up in
the registry; an `AbstractString` is treated as a path to a `.jl` file that must evaluate to a `Theme`.
"""
_resolve_theme(t::Theme) = t
function _resolve_theme(name::Symbol)
    haskey(_THEMES, name) || error(
        "Pinax: unknown theme :$(name). Registered themes: $(sort(collect(keys(_THEMES)))).",
    )
    return _THEMES[name]
end
function _resolve_theme(path::AbstractString)
    isfile(path) || error("Pinax: theme file not found: $(path)")
    # Evaluated as a script in Main, so a user theme file reads naturally:
    # `using Pinax; struct MyTheme <: Pinax.Theme end; Pinax.emit_document(...) = …; MyTheme()`.
    t = Base.include(Main, abspath(path))
    t isa Theme || error(
        "Pinax: theme file $(path) must evaluate to a Theme (its last expression); got $(typeof(t)).",
    )
    return t
end
function _resolve_theme(x)
    return error(
        "Pinax: cannot resolve theme from $(repr(x)); pass a Theme, Symbol, or path."
    )
end

include("themes/gallery.jl")   # default theme (registers :gallery)
