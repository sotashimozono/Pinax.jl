# theme.jl — a theme is a renderer over the structure IR (doc tree) (notes 06). Default = GalleryTheme.
#
# v1 gallery: a single `index.html` with figures materialized into
# `assets/figures/<page>/<section>/<id>.<fmt>`. Sec./Fig. numbers are assigned by the theme
# (notes 03: numbering is the theme's job) and `@ref(:id)` cross-references resolve to numbered
# links. Equations + KaTeX, @cite, CSS-counter display, and interactive JS come in later slices.

abstract type Theme end

output_format(::Theme) = :html
figure_formats(::Theme) = Symbol[:svg]   # formats requested from figure objects (file paths are copied as-is)
index_level(::Theme) = :cards

"Default theme: a self-contained HTML gallery (v1 minimal)."
struct GalleryTheme <: Theme end

# ---------- HTML helpers ----------

_esc(s) = replace(string(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")

const _GALLERY_CSS = """
<style>
  body{font-family:system-ui,sans-serif;max-width:980px;margin:2rem auto;padding:0 1rem;line-height:1.5}
  h1,h2{border-bottom:1px solid #eee;padding-bottom:.2rem}
  nav{background:#fafafa;border:1px solid #eee;border-radius:8px;padding:.6rem .9rem;margin:1rem 0}
  nav a{display:block;text-decoration:none;color:#0366d6}
  .desc{white-space:pre-wrap;background:#f6f8fa;padding:.6rem .8rem;border-radius:6px;margin:.6rem 0}
  .figgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:1rem}
  figure{margin:0;border:1px solid #ddd;border-radius:8px;padding:.5rem;background:#fff}
  figure img{width:100%;height:auto}
  figcaption{font-size:.9rem;color:#444;margin-top:.4rem}
  .diag{border-left:4px solid #d33;padding-left:.8rem}
</style>
"""

# ---------- per-render emit state ----------

"State threaded through the gallery emit functions for one render."
struct EmitCtx
    outdir::String
    io::IOBuffer
    rdiag::Vector{DiagEntry}
    cache::RenderCache
    nums::Dict{String,String}   # node anchor -> display number ("Fig. 3", "Sec. 2")
    ids::Dict{Symbol,String}    # label id -> node anchor (for @ref resolution)
end

# Theme-side numbering (notes 03/06: numbering is the theme's job). Sequential Sec./Fig. numbers,
# continuous across the document by default, or reset per page when `numbering=:page`.
function _gallery_numbers(doc::Document)
    nums = Dict{String,String}()
    perpage = doc.meta.numbering === :page
    numberer = doc.meta.numberer
    secn = 0
    fign = 0
    for pg in doc.pages
        if perpage
            secn = 0
            fign = 0
        end
        for sec in pg.sections
            secn += 1
            subfig = 0
            nums[sec.anchor] = string(
                numberer(:section, (; section=secn, figure=fign, subfigure=subfig))
            )
            for fig in sec.figures
                fign += 1
                subfig += 1
                nums[fig.anchor] = string(
                    numberer(:figure, (; section=secn, figure=fign, subfigure=subfig))
                )
            end
        end
    end
    return nums
end

# Label id -> node anchor, from the resolve table (single-page hrefs are "#anchor").
_id2anchor(doc::Document) = Dict{Symbol,String}(id => n.anchor for (id, n) in doc.refs)

# Resolve @ref tokens in a desc/caption source to numbered links and escape everything else.
# Supported forms: `@ref(:id)` and `[text](@ref :id)`.
const _REF_RE = r"\[([^\]]*)\]\(@ref\s+:(\w+)\)|@ref\(:(\w+)\)"

function _resolve_refs(source::AbstractString, ctx::EmitCtx, item)
    return replace(_esc(source), _REF_RE => s -> _ref_sub(s, ctx, item))
end

function _ref_sub(matched, ctx::EmitCtx, item)
    m = match(_REF_RE, matched)
    text = m.captures[1]                       # [text](@ref :id) form; already escaped by _esc
    id = m.captures[2] !== nothing ? m.captures[2] : m.captures[3]
    anchor = get(ctx.ids, Symbol(id), nothing)
    if anchor === nothing
        push!(ctx.rdiag, DiagEntry(WARNING, item, "@ref to unknown id :$(id)"))
        return "[?]"
    end
    label = (text !== nothing && !isempty(text)) ? text : get(ctx.nums, anchor, "[ref]")
    return string("<a href=\"#", anchor, "\">", label, "</a>")
end

# ---------- emit (the theme-dispatched entry point) ----------

"Emit the doc tree to a single HTML file. Doubles as pass 3 (materialize + draw) (notes 02/06)."
function emit_document(
    theme::GalleryTheme, doc::Document, outdir::AbstractString, cache::RenderCache
)
    io = IOBuffer()
    ctx = EmitCtx(
        String(outdir), io, DiagEntry[], cache, _gallery_numbers(doc), _id2anchor(doc)
    )
    title = isempty(doc.meta.title) ? "Pinax gallery" : doc.meta.title
    print(io, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">")
    print(io, "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    print(io, "<title>", _esc(title), "</title>", _GALLERY_CSS, "</head><body>\n")
    println(io, "<h1>", _esc(title), "</h1>")

    _emit_index(theme, doc, io)
    for pg in doc.pages
        println(
            io,
            "<section class=\"page\" id=\"",
            pg.anchor,
            "\"><h1>",
            _esc(pg.title),
            "</h1>",
        )
        for sec in pg.sections
            _emit_section(theme, sec, pg, ctx)
        end
        println(io, "</section>")
    end
    _emit_diagnostics(doc, ctx.rdiag, io)

    println(io, "</body></html>")
    path = joinpath(outdir, "index.html")
    write(path, String(take!(io)))
    return path
end

# index (table of contents): v1 shows names + links (:toc level). :cards/:rich come later.
function _emit_index(::GalleryTheme, doc::Document, io)
    println(io, "<nav><strong>Contents</strong>")
    for pg in doc.pages
        println(io, "<a href=\"#", pg.anchor, "\">", _esc(pg.title), "</a>")
        for sec in pg.sections
            println(
                io,
                "<a href=\"#",
                sec.anchor,
                "\" style=\"margin-left:1.2rem\">",
                _esc(sec.title),
                "</a>",
            )
        end
    end
    return println(io, "</nav>")
end

function _emit_section(theme, sec::Section, pg::Page, ctx::EmitCtx)
    io = ctx.io
    num = get(ctx.nums, sec.anchor, "")
    heading = isempty(num) ? _esc(sec.title) : string(_esc(num), ". ", _esc(sec.title))
    println(io, "<section class=\"section\" id=\"", sec.anchor, "\"><h2>", heading, "</h2>")
    if sec.desc !== nothing
        println(
            io,
            "<div class=\"desc\">",
            _resolve_refs(sec.desc.source, ctx, sec.anchor),
            "</div>",
        )
    end
    println(io, "<div class=\"figgrid\">")
    fmts = figure_formats(theme)
    for fig in sec.figures
        base = joinpath(ctx.outdir, "assets", "figures", pg.anchor, sec.anchor, fig.anchor)
        try
            materialize!(fig, base, fmts, ctx.cache)   # cache hit skips gen (notes 10)
        catch e
            e isa InterruptException && rethrow()
            push!(ctx.rdiag, DiagEntry(ERROR, fig.anchor, "materialize failed: $(e)"))
            _emit_placeholder(fig, "figure failed", io)
            continue
        end
        if isempty(fig.assets)
            push!(ctx.rdiag, DiagEntry(WARNING, fig.anchor, "figure produced no assets"))
            _emit_placeholder(fig, "no assets", io)
            continue
        end
        _emit_figure(fig, ctx)
    end
    return println(io, "</div></section>")
end

# A broken/empty figure: a visible card plus a link back to the diagnostics section.
function _emit_placeholder(fig::Figure, why, io)
    return println(
        io,
        "<figure id=\"",
        fig.anchor,
        "\"><div class=\"diag\">⚠ ",
        _esc(why),
        " (",
        _esc(string(fig.id)),
        ") — see <a href=\"#diagnostics\">diagnostics</a></div></figure>",
    )
end

function _emit_figure(fig::Figure, ctx::EmitCtx)
    io = ctx.io
    println(io, "<figure id=\"", fig.anchor, "\">")
    for a in fig.assets
        rel = replace(relpath(a, ctx.outdir), '\\' => '/')   # forward slashes for URLs (Windows-safe)
        if _ext(a) in ("svg", "png")
            println(io, "<img src=\"", _esc(rel), "\" alt=\"", _esc(string(fig.id)), "\">")
        else
            println(io, "<a href=\"", _esc(rel), "\">", _esc(basename(a)), "</a>")
        end
    end
    num = get(ctx.nums, fig.anchor, "")
    cap = isempty(fig.caption) ? "" : _resolve_refs(fig.caption, ctx, fig.anchor)
    caphtml = if isempty(num)
        cap
    elseif isempty(cap)
        string("<b>", _esc(num), "</b>")
    else
        string("<b>", _esc(num), ".</b> ", cap)
    end
    isempty(caphtml) || println(io, "<figcaption>", caphtml, "</figcaption>")
    return println(io, "</figure>")
end

# Diagnostics page (notes 09, minimal): build-phase (doc.diag) + this render's failures (rdiag),
# foldable, shown when debug is on or anything was collected. Kept out of doc.diag so re-render is idempotent.
function _emit_diagnostics(doc::Document, rdiag::Vector{DiagEntry}, io)
    es = vcat(doc.diag.entries, rdiag)
    (doc.meta.debug || !isempty(es)) || return nothing
    println(io, "<section class=\"diag\" id=\"diagnostics\"><h2>Diagnostics</h2>")
    isempty(es) && println(io, "<p>No issues.</p>")
    for e in es
        println(
            io,
            "<details open><summary>",
            _esc(string(e.severity)),
            " — ",
            _esc(e.item),
            "</summary><p>",
            _esc(e.message),
            "</p></details>",
        )
    end
    println(io, "</section>")
    return nothing
end
