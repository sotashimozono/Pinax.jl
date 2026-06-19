# render.jl — the render driver (3 passes, notes 02).
#
# pass 1 (structure) is already built by the macros. Here: pass 2 (resolve) -> pass 3 (materialize + emit).

"""
    resolve!(doc) -> doc

pass 2 (structure only, no numbers). Builds the label->node table. Numbers are assigned
by the theme (CSS), so none are emitted here. Facet expansion and full diagnostic
collection come in later slices.
"""
function resolve!(doc::Document)
    empty!(doc.refs)
    for pg in doc.pages
        doc.refs[pg.id] = pg
        for sec in pg.sections
            doc.refs[sec.id] = sec
            for f in sec.figures
                doc.refs[f.id] = f
            end
        end
    end
    return doc
end

"""
    render([doc]; out, theme=GalleryTheme(), force=false) -> path

Render the catalogue: structure (pass 1, done by macros) -> resolve (pass 2) ->
materialize + emit (pass 3, theme). Writes into the `out` directory and returns the
path of the generated entry file. `doc` defaults to the implicit global document.
`force=true` re-materializes every figure, ignoring the cache (notes 10).

`comments_file` is the id-keyed annotation store read and shown inline by the gallery
(default `out/comments.toml`). render only READS it — it persists across renders and is
written by the CLI / browser export / LLM loop, never overwritten here.
"""
function render(
    doc::Union{Document,Nothing}=current_document();
    out::AbstractString,
    theme::Theme=GalleryTheme(),
    force::Bool=false,
    comments_file::AbstractString=joinpath(out, "comments.toml"),
)
    doc === nothing &&
        error("Pinax: no document to render. Use `@page …` first, or pass a Document.")
    resolve!(doc)
    mkpath(out)
    cache = RenderCache(out, force)
    path = emit_document(theme, doc, out, cache; comments_file=comments_file)
    _finalize_cache!(cache)
    return path
end
