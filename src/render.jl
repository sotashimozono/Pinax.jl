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

`theme` selects the renderer: a `Theme` instance, a registered `Symbol`, or a path to a user
theme file (see `theme.jl`). `nothing` (default) uses the document's `@pinaxsetup theme=…`.

`vault` is an optional `DataVault.Vault` (notes 10; needs `using DataVault`, which loads the
PinaxDataVaultExt extension): when given, (1) the cache key tracks each `params::DataKey` figure's
data via its `.done` marker, so recomputing the data re-materializes the figure (not just code/param
changes), and (2) figure provenance is recorded with `DataVault.record_figure` under `study`
(defaults to the vault's run).
"""
function render(
    doc::Union{Document,Nothing}=current_document();
    out::AbstractString,
    theme=nothing,
    force::Bool=false,
    comments_file::AbstractString=joinpath(out, "comments.toml"),
    vault=nothing,
    study=nothing,
)
    doc === nothing &&
        error("Pinax: no document to render. Use `@page …` first, or pass a Document.")
    resolve!(doc)
    mkpath(out)
    cache = RenderCache(out, force, vault)
    rtheme = _resolve_theme(theme === nothing ? doc.meta.theme : theme)
    # invokelatest so a theme just defined/loaded at runtime (e.g. a path-loaded user theme) is seen.
    path = Base.invokelatest(
        emit_document, rtheme, doc, out, cache; comments_file=comments_file
    )
    _finalize_cache!(cache)
    vault === nothing || _record_provenance(vault, study)
    return path
end

# Record figure provenance. The PinaxDataVaultExt extension specializes this on a DataVault.Vault
# (study-level meta.toml, non-fatal); the core is a no-op. The caller only invokes it for a non-nothing
# vault, and a DataVault.Vault means DataVault is loaded (so the extension is too) — hence in practice
# the ext method handles every real vault. The core no-op is the graceful fallback if some non-Vault
# value is passed as `vault` without DataVault loaded: provenance is silently skipped, not an error.
_record_provenance(vault, study) = nothing
