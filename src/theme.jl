# theme.jl — a theme is a renderer over the structure IR (doc tree) (notes 06). Default = GalleryTheme.
#
# v1 gallery: a single `index.html` with figures materialized into
# `assets/figures/<page>/<section>/<id>.<fmt>`. Sec./Fig./Eq. numbers are assigned by the theme
# server-side (notes 03: numbering is the theme's job); `@desc`/`@caption` prose is rendered to HTML
# server-side via the Markdown stdlib, with math left to KaTeX (client-side). `@ref(:id)` resolves to
# a numbered link; `@label(:id)` defines a label (for equations). @cite, CSS-counter display, and
# interactive JS come in later slices.

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
  .desc{background:#f6f8fa;padding:.6rem .8rem;border-radius:6px;margin:.6rem 0}
  .desc p:first-child{margin-top:0}.desc p:last-child{margin-bottom:0}
  .desc table{border-collapse:collapse;margin:.5rem 0}
  .desc th,.desc td{border:1px solid #ccd;padding:.15rem .5rem;font-size:.9rem}
  .figgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:1rem}
  figure{margin:0;border:1px solid #ddd;border-radius:8px;padding:.5rem;background:#fff}
  figure img{width:100%;height:auto}
  figure iframe.pinax-pdf{width:100%;height:460px;border:1px solid #eee;border-radius:4px;background:#fff}
  a.pinax-open{display:inline-block;font-size:.85rem;margin-top:.3rem;color:#0366d6;text-decoration:none}
  figcaption{font-size:.9rem;color:#444;margin-top:.4rem}
  .diag{border-left:4px solid #d33;padding-left:.8rem}
  .pinax-eq{display:block}
  h3.facet{color:#555;margin:1rem 0 .3rem;font-size:1.05rem;font-weight:600}
  .pinax-meta{color:#666;margin:-.4rem 0 1rem;font-size:.95rem}
  .nfig{color:#888;font-weight:normal;font-size:.85em}
  nav .nfig{color:#888}
</style>
"""

# KaTeX (loaded from a CDN; offline vendoring is a later slice). Inline `\$…\$` is rendered
# client-side; display `\$\$…\$\$` is pre-processed server-side (numbered, anchored, @label
# consumed) then rendered by KaTeX.
const _KATEX_CDN = "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist"
const _KATEX_HEAD = string(
    "<link rel=\"stylesheet\" href=\"", _KATEX_CDN, "/katex.min.css\">"
)
const _KATEX_FOOT = string(
    "<script defer src=\"",
    _KATEX_CDN,
    "/katex.min.js\"></script>",
    "<script defer src=\"",
    _KATEX_CDN,
    "/contrib/auto-render.min.js\"></script>",
    "<script>window.addEventListener(\"load\",function(){renderMathInElement(document.body,",
    "{delimiters:[{left:\"\$\$\",right:\"\$\$\",display:true},",
    "{left:\"\$\",right:\"\$\",display:false}],throwOnError:false});});</script>",
)

# ---------- per-render emit state ----------

"State threaded through the gallery emit functions for one render."
struct EmitCtx
    outdir::String
    io::IOBuffer
    rdiag::Vector{DiagEntry}
    cache::RenderCache
    nums::Dict{String,String}                  # node/eq anchor -> display number ("Fig. 3", "(2)")
    ids::Dict{Symbol,String}                   # label id -> anchor (sections, figures, equations)
    eqseq::Dict{String,Vector{Tuple{String,Int}}}  # node anchor -> ordered [(eq anchor, eq number)]
end

# Display-equation block: an optional preceding @label(:id), then $$ ... $$ (newlines allowed).
const _EQ_RE = r"(?:@label\(:(\w+)\)\s*)?\$\$\s*(.+?)\s*\$\$"s

# Resolve @ref forms: `@ref(:id)` and `[text](@ref :id)`.
const _REF_RE = r"\[([^\]]*)\]\(@ref\s+:(\w+)\)|@ref\(:(\w+)\)"

# Build the counters NamedTuple handed to the numberer.
function _counters(secn, fign, subfig, eqn)
    return (; section=secn, figure=fign, subfigure=subfig, equation=eqn)
end

# Theme-side numbering (notes 03/06). Assigns Sec./Fig./Eq. numbers in document order (continuous,
# or reset per page when numbering=:page), scanning desc/caption sources for display equations.
# Returns (nums, ids_eq, eqseq).
function _gallery_numbers(doc::Document)
    nums = Dict{String,String}()
    ids_eq = Dict{Symbol,String}()
    eqseq = Dict{String,Vector{Tuple{String,Int}}}()
    perpage = doc.meta.numbering === :page
    numberer = doc.meta.numberer
    secn = fign = eqn = 0
    for pg in doc.pages
        if perpage
            secn = fign = eqn = 0
        end
        for sec in pg.sections
            secn += 1
            subfig = 0
            nums[sec.anchor] = string(
                numberer(:section, _counters(secn, fign, subfig, eqn))
            )
            eqn = _scan_eqs!(
                _descsrc(sec.desc),
                sec.anchor,
                secn,
                fign,
                subfig,
                nums,
                ids_eq,
                eqseq,
                numberer,
                eqn,
            )
            for fig in sec.figures
                fign += 1
                subfig += 1
                nums[fig.anchor] = string(
                    numberer(:figure, _counters(secn, fign, subfig, eqn))
                )
                eqn = _scan_eqs!(
                    fig.caption,
                    fig.anchor,
                    secn,
                    fign,
                    subfig,
                    nums,
                    ids_eq,
                    eqseq,
                    numberer,
                    eqn,
                )
            end
        end
    end
    return nums, ids_eq, eqseq
end

_descsrc(d) = d === nothing ? "" : d.source

# Scan one source for `$$…$$` blocks: number each equation (numberer gets the live section/figure
# counters), register `@label(:id)` ids, record the per-node ordered (anchor, number) list.
function _scan_eqs!(
    source, node_anchor, secn, fign, subfig, nums, ids_eq, eqseq, numberer, eqn
)
    isempty(source) && return eqn
    lst = Tuple{String,Int}[]
    k = 0
    for m in eachmatch(_EQ_RE, source)
        eqn += 1
        k += 1
        label = m.captures[1]
        anchor = label !== nothing ? _anchor(Symbol(label)) : string(node_anchor, "_eq", k)
        nums[anchor] = string(numberer(:equation, _counters(secn, fign, subfig, eqn)))
        label !== nothing && (ids_eq[Symbol(label)] = anchor)
        push!(lst, (anchor, eqn))
    end
    isempty(lst) || (eqseq[node_anchor] = lst)
    return eqn
end

# Label id -> node anchor, from the resolve table (single-page hrefs are "#anchor").
_id2anchor(doc::Document) = Dict{Symbol,String}(id => n.anchor for (id, n) in doc.refs)

# Inline `$…$` math (single delimiters, one line, no inner `$`); HTML-escaped then re-injected for
# client-side KaTeX.
const _INLINE_EQ_RE = r"\$[^\$\n]+?\$"

# Placeholder token wrapping a protected fragment (math / cross-reference) across the markdown pass.
_tok(k) = string("PINAXxTOKx", k, "xENDx")

# Render a desc/caption source to HTML. Prose is authored in markdown and rendered server-side via
# the Markdown stdlib; math and `@ref` cross-references are first replaced with placeholder tokens so
# the markdown pass cannot mangle them, then re-injected. Display `$$…$$` become numbered, anchored
# spans (KaTeX renders them client-side); inline `$…$` is HTML-escaped and re-injected for KaTeX;
# `@ref` resolves to a numbered link; a bare `@label` (not bound to a `$$…$$` block) is dropped.
# `item` is the owning node's anchor. `block=false` unwraps the single paragraph markdown adds, for
# inline use in figure captions.
function _render_text(source::AbstractString, item::String, ctx::EmitCtx; block::Bool=true)
    eqs = get(ctx.eqseq, item, Tuple{String,Int}[])
    subs = String[]
    tok!(html) = (push!(subs, html); _tok(length(subs)))
    # 1. Protect math + refs (display `$$` before inline `$`, since `$$` contains `$`).
    i = Ref(0)
    s = replace(source, _EQ_RE => m -> tok!(_eq_html(m, eqs, i)))
    s = replace(s, _INLINE_EQ_RE => m -> tok!(_esc(m)))
    s = replace(s, _REF_RE => m -> tok!(_ref_html(m, ctx, item)))
    s = replace(s, r"@label\(:\w+\)\s*" => "")
    # 2. Render the surviving prose as markdown (raw HTML is escaped -> safe). A parse failure is
    #    non-fatal: fall back to escaped text and record a diagnostic (notes 09).
    html = try
        _markdown(s)
    catch e
        e isa InterruptException && rethrow()
        push!(ctx.rdiag, DiagEntry(WARNING, item, "markdown render failed: $(e)"))
        _esc(s)
    end
    # 3. Re-inject the protected fragments.
    for (k, frag) in enumerate(subs)
        html = replace(html, _tok(k) => frag)
    end
    return block ? html : _unwrap_p(html)
end

# Markdown -> HTML. Lets the (rare) parse error propagate; `_render_text` turns it into a diagnostic.
function _markdown(s::AbstractString)
    return rstrip(Markdown.html(Markdown.parse(s)))
end

# Drop the single `<p>…</p>` wrapper markdown adds, for inline contexts (captions).
function _unwrap_p(html::AbstractString)
    if startswith(html, "<p>") && endswith(html, "</p>") && count("<p>", html) == 1
        return chopsuffix(chopprefix(html, "<p>"), "</p>")
    end
    return html
end

function _eq_html(matched, eqs, i)
    m = match(_EQ_RE, matched)
    math = m.captures[2]
    i[] += 1
    anchor, num = i[] <= length(eqs) ? eqs[i[]] : ("", 0)
    return string(
        "<span class=\"pinax-eq\" id=\"",
        anchor,
        "\">\$\$ ",
        _esc(math),
        " \\tag{",
        num,
        "} \$\$</span>",
    )
end

function _ref_html(matched, ctx::EmitCtx, item::String)
    m = match(_REF_RE, matched)
    text = m.captures[1]
    id = m.captures[2] !== nothing ? m.captures[2] : m.captures[3]
    anchor = get(ctx.ids, Symbol(id), nothing)
    if anchor === nothing
        push!(ctx.rdiag, DiagEntry(WARNING, item, "@ref to unknown id :$(id)"))
        return "[?]"
    end
    label =
        (text !== nothing && !isempty(text)) ? _esc(text) : get(ctx.nums, anchor, "[ref]")
    return string("<a href=\"#", anchor, "\">", label, "</a>")
end

# ---------- emit (the theme-dispatched entry point) ----------

"Emit the doc tree to a single HTML file. Doubles as pass 3 (materialize + draw) (notes 02/06)."
function emit_document(
    theme::GalleryTheme, doc::Document, outdir::AbstractString, cache::RenderCache
)
    io = IOBuffer()
    nums, ids_eq, eqseq = _gallery_numbers(doc)
    rdiag = DiagEntry[]
    base_ids = _id2anchor(doc)
    for k in keys(ids_eq)
        haskey(base_ids, k) && push!(
            rdiag,
            DiagEntry(
                WARNING,
                string(k),
                "equation @label(:$(k)) collides with a section/figure id",
            ),
        )
    end
    ctx = EmitCtx(String(outdir), io, rdiag, cache, nums, merge(base_ids, ids_eq), eqseq)
    title = isempty(doc.meta.title) ? "Pinax gallery" : doc.meta.title
    print(io, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">")
    print(io, "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    print(
        io, "<title>", _esc(title), "</title>", _GALLERY_CSS, _KATEX_HEAD, "</head><body>\n"
    )
    println(io, "<h1>", _esc(title), "</h1>")
    ntotal = _total_figures(doc)
    println(
        io,
        "<div class=\"pinax-meta\">",
        ntotal,
        ntotal == 1 ? " figure" : " figures",
        "</div>",
    )

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

    print(io, _KATEX_FOOT)
    println(io, "</body></html>")
    path = joinpath(outdir, "index.html")
    write(path, String(take!(io)))
    return path
end

# Total figure count across the document (shown in the header, e.g. "547 figures").
function _total_figures(doc::Document)
    return sum(length(sec.figures) for pg in doc.pages for sec in pg.sections; init=0)
end

# index (table of contents): v1 shows names + links (:toc level), each with its figure count.
# :cards/:rich come later.
function _emit_index(::GalleryTheme, doc::Document, io)
    println(io, "<nav><strong>Contents</strong>")
    for pg in doc.pages
        println(io, "<a href=\"#", pg.anchor, "\">", _esc(pg.title), "</a>")
        for sec in pg.sections
            n = length(sec.figures)
            count = n > 0 ? string(" <span class=\"nfig\">(", n, ")</span>") : ""
            println(
                io,
                "<a href=\"#",
                sec.anchor,
                "\" style=\"margin-left:1.2rem\">",
                _esc(sec.title),
                count,
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
    n = length(sec.figures)
    n > 0 && (heading *= string(" <span class=\"nfig\">(", n, ")</span>"))
    println(io, "<section class=\"section\" id=\"", sec.anchor, "\"><h2>", heading, "</h2>")
    if sec.desc !== nothing
        println(
            io,
            "<div class=\"desc\">",
            _render_text(sec.desc.source, sec.anchor, ctx),
            "</div>",
        )
    end
    if sec.facet isa AbstractString
        for (val, figs) in _facet_groups(sec.figures, sec.facet)
            label = if val === missing
                string(sec.facet, ": (unset)")
            else
                string(sec.facet, " = ", val)
            end
            println(io, "<h3 class=\"facet\">", _esc(label), "</h3>")
            _emit_figures(figs, sec, pg, theme, ctx)
        end
    else
        _emit_figures(sec.figures, sec, pg, theme, ctx)
    end
    return println(io, "</section>")
end

# Emit one grid of figures (materialize each: streaming + cache).
function _emit_figures(figs, sec::Section, pg::Page, theme, ctx::EmitCtx)
    io = ctx.io
    println(io, "<div class=\"figgrid\">")
    fmts = figure_formats(theme)
    for fig in figs
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
    return println(io, "</div>")
end

# Extract param axis `facet` from a figure's params (a ParamIO.DataKey), or `missing` if absent.
# Used by `_facet_groups` for `by=` faceting (notes 05).
function _facet_value(p, facet)
    return (p isa ParamIO.DataKey && haskey(p.params, facet)) ? p.params[facet] : missing
end

# Sort key for facet values: numbers first (by value, NaN last), then strings, then missing.
function _facetsort(x)
    x === missing && return (2, 0.0, "")
    if x isa Number
        fx = float(x)
        return (0, isnan(fx) ? Inf : fx, "")
    end
    return (1, 0.0, string(x))
end

function _facet_groups(figures, facet::AbstractString)
    groups = Dict{Any,Vector{Figure}}()
    order = Any[]
    for fig in figures
        v = _facet_value(fig.params, facet)
        if !haskey(groups, v)
            groups[v] = Figure[]
            push!(order, v)
        end
        push!(groups[v], fig)
    end
    sort!(order; by=_facetsort)
    return [(v, groups[v]) for v in order]
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
        ext = _ext(a)
        if ext in ("svg", "png")
            println(io, "<img src=\"", _esc(rel), "\" alt=\"", _esc(string(fig.id)), "\">")
        elseif ext == "pdf"
            # Embed PDFs via the browser's native viewer (notes 04 §3: "pdf -> iframe"), with an
            # open/download fallback for browsers that block inline PDFs (e.g. some file:// setups).
            println(
                io,
                "<iframe class=\"pinax-pdf\" src=\"",
                _esc(rel),
                "\" title=\"",
                _esc(string(fig.id)),
                "\"></iframe>",
            )
            println(
                io,
                "<a class=\"pinax-open\" href=\"",
                _esc(rel),
                "\" target=\"_blank\" rel=\"noopener\">open ",
                _esc(basename(a)),
                " ↗</a>",
            )
        else
            println(io, "<a href=\"", _esc(rel), "\">", _esc(basename(a)), "</a>")
        end
    end
    num = get(ctx.nums, fig.anchor, "")
    cap =
        isempty(fig.caption) ? "" : _render_text(fig.caption, fig.anchor, ctx; block=false)
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
