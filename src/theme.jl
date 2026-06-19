# theme.jl — a theme is a renderer over the structure IR (doc tree) (notes 06). Default = GalleryTheme.
#
# v1 (walking skeleton) is minimal: a single `index.html` with figures materialized into
# `assets/figures/<page>/<section>/<id>.<fmt>`. CSS-counter numbering, KaTeX, interactive JS,
# and multi-page nav come in later slices.

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

# ---------- emit (the theme-dispatched entry point) ----------

"Emit the doc tree to a single HTML file. Doubles as pass 3 (materialize + draw) (notes 02/06)."
function emit_document(theme::GalleryTheme, doc::Document, outdir::AbstractString)
    io = IOBuffer()
    rdiag = DiagEntry[]   # render-phase diagnostics; kept local so re-render stays idempotent
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
            _emit_section(theme, sec, pg, outdir, io, rdiag)
        end
        println(io, "</section>")
    end
    _emit_diagnostics(doc, rdiag, io)

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

function _emit_section(theme, sec::Section, pg::Page, outdir, io, rdiag)
    println(
        io,
        "<section class=\"section\" id=\"",
        sec.anchor,
        "\"><h2>",
        _esc(sec.title),
        "</h2>",
    )
    sec.desc === nothing ||
        println(io, "<div class=\"desc\">", _esc(sec.desc.source), "</div>")
    println(io, "<div class=\"figgrid\">")
    fmts = figure_formats(theme)
    for fig in sec.figures
        base = joinpath(outdir, "assets", "figures", pg.anchor, sec.anchor, fig.anchor)
        try
            fig.assets = _materialize(fig, base, fmts)
        catch e
            e isa InterruptException && rethrow()
            push!(rdiag, DiagEntry(ERROR, fig.anchor, "materialize failed: $(e)"))
            _emit_placeholder(fig, "figure failed", io)
            continue
        end
        if isempty(fig.assets)
            push!(rdiag, DiagEntry(WARNING, fig.anchor, "figure produced no assets"))
            _emit_placeholder(fig, "no assets", io)
            continue
        end
        _emit_figure(fig, outdir, io)
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

function _emit_figure(fig::Figure, outdir, io)
    println(io, "<figure id=\"", fig.anchor, "\">")
    for a in fig.assets
        rel = replace(relpath(a, outdir), '\\' => '/')   # forward slashes for URLs (Windows-safe)
        if _ext(a) in ("svg", "png")
            println(io, "<img src=\"", _esc(rel), "\" alt=\"", _esc(string(fig.id)), "\">")
        else
            println(io, "<a href=\"", _esc(rel), "\">", _esc(basename(a)), "</a>")
        end
    end
    isempty(fig.caption) || println(io, "<figcaption>", _esc(fig.caption), "</figcaption>")
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
