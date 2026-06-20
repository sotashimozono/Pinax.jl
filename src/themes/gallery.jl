# themes/gallery.jl — the default theme: a self-contained, interactive HTML gallery.
#
# Moved out of theme.jl (which now holds only the Theme contract + resolution). A single
# `index.html` with figures under assets/figures/<page>/<section>/<id>.<fmt>; numbers assigned
# server-side; @desc/@caption are markdown (Markdown stdlib) + KaTeX (client); comments render
# co-located and round-trip to comments.toml via the inlined interactive layer (notes 01/03/06).

"Default theme: a self-contained HTML gallery (v1 minimal)."
struct GalleryTheme <: Theme end

# ---------- HTML helpers ----------

_esc(s) = replace(string(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")

# Read a vendored gallery asset (assets/default/<name>), inlined into the single self-contained HTML.
_asset(name) = read(joinpath(pkgdir(@__MODULE__), "assets", "default", name), String)

# JSON string literal, escaped so it is safe inside an HTML <script> block (`<`/`>`/`&` -> \uXXXX).
function _jsonstr(s)
    out = IOBuffer()
    print(out, '"')
    for c in string(s)
        if c == '"'
            print(out, "\\\"")
        elseif c == '\\'
            print(out, "\\\\")
        elseif c == '\n'
            print(out, "\\n")
        elseif c == '\r'
            print(out, "\\r")
        elseif c == '\t'
            print(out, "\\t")
        elseif c in ('<', '>', '&')
            print(out, "\\u", lpad(string(Int(c); base=16), 4, '0'))
        elseif c < ' '
            print(out, "\\u", lpad(string(Int(c); base=16), 4, '0'))
        else
            print(out, c)
        end
    end
    print(out, '"')
    return String(take!(out))
end

# Embed the committed comments/bookmarks (+ enabled features) as JSON for the browser write layer:
# the JS merges this baseline with its localStorage additions when exporting comments.toml.
function _emit_committed_json(io, comments, bookmarks, features)
    print(io, "<script type=\"application/json\" id=\"pinax-committed\">{\"comments\":{")
    first = true
    for (id, turns) in comments
        first || print(io, ",")
        first = false
        print(io, _jsonstr(string(id)), ":[")
        for (i, c) in enumerate(turns)
            i == 1 || print(io, ",")
            print(
                io, "{\"author\":", _jsonstr(c.author), ",\"text\":", _jsonstr(c.text), "}"
            )
        end
        print(io, "]")
    end
    print(io, "},\"bookmarks\":{")
    first = true
    for id in bookmarks
        first || print(io, ",")
        first = false
        print(io, _jsonstr(string(id)), ":true")
    end
    print(io, "},\"features\":[")
    for (i, f) in enumerate(features)
        i == 1 || print(io, ",")
        print(io, _jsonstr(string(f)))
    end
    print(io, "]}</script>\n")
    return nothing
end

const _GALLERY_CSS = """
<style>
  body{font-family:system-ui,sans-serif;max-width:1180px;margin:2rem auto;padding:0 1rem;line-height:1.5;background:#fafafa;color:#24292f}
  h1,h2{border-bottom:1px solid #eee;padding-bottom:.2rem}
  nav{background:#fafafa;border:1px solid #eee;border-radius:8px;padding:.6rem .9rem;margin:1rem 0}
  nav a{display:block;text-decoration:none;color:#0366d6}
  .desc{background:#f6f8fa;padding:.6rem .8rem;border-radius:6px;margin:.6rem 0}
  .desc p:first-child{margin-top:0}.desc p:last-child{margin-bottom:0}
  .desc table{border-collapse:collapse;margin:.5rem 0}
  .desc th,.desc td{border:1px solid #ccd;padding:.15rem .5rem;font-size:.9rem}
  section.section{background:#fff;border:1px solid #e2e5e9;border-radius:8px;padding:.85rem 1.15rem;margin:0 0 1.4rem;box-shadow:0 1px 2px rgba(27,31,36,.04)}
  section.section>h2{margin-top:0}
  .figgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:1rem}
  figure{margin:0;border:1px solid #e2e5e9;border-radius:8px;padding:.5rem;background:#fdfdfe}
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
  .bibliography li{margin:.3rem 0;font-size:.92rem}
  .pinax-bm-on{color:#e3b341}
  .pinax-comments{margin:.6rem 0;border-left:3px solid #cbd5e1;padding-left:.8rem}
  .pinax-cmt{margin:.4rem 0;font-size:.92rem}
  .pinax-cmt .author{font-weight:600;color:#0366d6}
  .pinax-cmt p:first-child{margin-top:0;display:inline}
  .pinax-cmt p:last-child{margin-bottom:0}
  .pinax-top{margin:0 0 1rem;font-size:.95rem}
  .pinax-top a{color:#0366d6;text-decoration:none}
  .pinax-cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:1.2rem;margin:1.2rem 0}
  .pinax-card{display:flex;flex-direction:column;border:1px solid #e2e5e9;border-radius:10px;overflow:hidden;background:#fff;text-decoration:none;color:inherit;box-shadow:0 1px 2px rgba(27,31,36,.04);transition:box-shadow .15s,transform .15s}
  .pinax-card:hover{box-shadow:0 4px 14px rgba(27,31,36,.12);transform:translateY(-2px)}
  .card-thumb{aspect-ratio:4/3;background:#f6f8fa;display:flex;align-items:center;justify-content:center;overflow:hidden}
  .card-thumb img{width:100%;height:100%;object-fit:contain}
  .card-thumb-empty{min-height:150px}
  .card-body{padding:.7rem .9rem}
  .card-title{font-weight:600;font-size:1.05rem}
  .card-summary{color:#555;font-size:.9rem;margin-top:.2rem}
  .card-sections{margin-top:.5rem;font-size:.85rem;color:#57606a}
  .card-sections .sec-item{padding:.1rem 0}
  .card-sections .sec-name{font-weight:600;color:#444}
  .card-meta{color:#8b949e;font-size:.82rem;margin-top:.45rem}
  .pinax-toc{list-style:none;padding:0;margin:1.2rem 0}
  .pinax-toc>li{padding:.5rem 0;border-bottom:1px solid #eaecef}
  .pinax-toc a{font-weight:600;color:#0366d6;text-decoration:none}
  .pinax-toc .toc-summary{color:#555;font-weight:400}
  .pinax-toc .toc-meta{color:#8b949e;font-size:.85rem}
</style>
"""

# KaTeX. `katex=:cdn` (default) loads from jsDelivr; `katex=:local` references the vendored copy
# (`_copy_katex` mirrors assets/default/katex into out/assets/katex) so the gallery renders math
# fully offline. Inline `\$…\$` and display `\$\$…\$\$` (server-side numbered/anchored) are rendered
# client-side by KaTeX, with `@newcommand` macros wired in.
const _KATEX_CDN = "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist"
_katex_base(mode) = mode === :local ? "assets/katex" : _KATEX_CDN

function _katex_head(mode)
    return string(
        "<link rel=\"stylesheet\" href=\"", _katex_base(mode), "/katex.min.css\">"
    )
end

# `@newcommand "\\E" raw"\\langle H\\rangle"` notation macros -> KaTeX `macros` option (notes 08 §2).
function _macros_json(nc)
    return if isempty(nc)
        "{}"
    else
        string(
            "{", join([string(_jsonstr(k), ":", _jsonstr(v)) for (k, v) in nc], ","), "}"
        )
    end
end

# KaTeX loader + auto-render, with the document's @newcommand macros wired into the renderer.
function _katex_foot(newcommands, mode)
    base = _katex_base(mode)
    return string(
        "<script defer src=\"",
        base,
        "/katex.min.js\"></script>",
        "<script defer src=\"",
        base,
        "/contrib/auto-render.min.js\"></script>",
        "<script>window.addEventListener(\"load\",function(){renderMathInElement(document.body,",
        "{delimiters:[{left:\"\$\$\",right:\"\$\$\",display:true},",
        "{left:\"\$\",right:\"\$\",display:false}],macros:",
        _macros_json(newcommands),
        ",throwOnError:false});});</script>",
    )
end

# Mirror the vendored KaTeX (css/js/contrib/woff2 fonts) into out/assets/katex for offline math.
function _copy_katex(outdir)
    src = joinpath(pkgdir(@__MODULE__), "assets", "default", "katex")
    dst = joinpath(outdir, "assets", "katex")
    mkpath(dirname(dst))
    cp(src, dst; force=true)
    return nothing
end

# Inline a user css/js overlay (notes 06 §5: appended after the theme's own assets, keeping the
# single self-contained HTML). A missing file is non-fatal -> diagnostic.
function _emit_overlay(io, paths, tag, rdiag)
    for p in paths
        if isfile(p)
            print(io, "<", tag, ">", read(p, String), "</", tag, ">")
        else
            push!(
                rdiag, DiagEntry(WARNING, "preamble", "$(tag) overlay file not found: $(p)")
            )
        end
    end
    return nothing
end

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
    bib::Dict{Symbol,BibEntry}                 # @bibliography sources, parsed
    citenums::Dict{Symbol,Int}                 # cite key -> [n] (first-appearance order)
    comments::Dict{Symbol,Vector{Comment}}     # section anchor -> comment turns (notes 01 §4)
    bookmarks::Set{Symbol}                     # bookmarked section anchors
    features::Vector{Symbol}                   # interactive layer toggles (:comments/:bookmarks/:export)
end

# Display-equation block: an optional preceding @label(:id), then $$ ... $$ (newlines allowed).
const _EQ_RE = r"(?:@label\(:(\w+)\)\s*)?\$\$\s*(.+?)\s*\$\$"s

# Resolve @ref forms: `@ref(:id)` and `[text](@ref :id)`.
const _REF_RE = r"\[([^\]]*)\]\(@ref\s+:(\w+)\)|@ref\(:(\w+)\)"

# Resolve @cite forms: `@cite(:key)` and `[text](@cite key)` (colon optional in the link form).
const _CITE_RE = r"\[([^\]]*)\]\(@cite\s+:?(\w+)\)|@cite\(:(\w+)\)"

# Build the counters NamedTuple handed to the numberer. `page` is the 1-based page index and
# `page_id` the page's id (Symbol) — so a numberer can prefix section numbers per "part" (e.g.
# `c.page_id === :eq ? "EQ$(c.section)" : "GQ$(c.section)"`), typically with numbering=:page.
function _counters(pagen, pageid, secn, fign, subfig, eqn)
    return (;
        page=pagen,
        page_id=pageid,
        section=secn,
        figure=fign,
        subfigure=subfig,
        equation=eqn,
    )
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
    pagen = 0
    for pg in doc.pages
        pagen += 1
        pid = pg.id
        if perpage
            secn = fign = eqn = 0
        end
        for sec in pg.sections
            secn += 1
            subfig = 0
            nums[sec.anchor] = string(
                numberer(:section, _counters(pagen, pid, secn, fign, subfig, eqn))
            )
            eqn = _scan_eqs!(
                _descsrc(sec.desc),
                sec.anchor,
                pagen,
                pid,
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
                    numberer(:figure, _counters(pagen, pid, secn, fign, subfig, eqn))
                )
                eqn = _scan_eqs!(
                    fig.caption,
                    fig.anchor,
                    pagen,
                    pid,
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
    source, node_anchor, pagen, pid, secn, fign, subfig, nums, ids_eq, eqseq, numberer, eqn
)
    isempty(source) && return eqn
    lst = Tuple{String,Int}[]
    k = 0
    for m in eachmatch(_EQ_RE, source)
        eqn += 1
        k += 1
        label = m.captures[1]
        anchor = label !== nothing ? _anchor(Symbol(label)) : string(node_anchor, "_eq", k)
        nums[anchor] = string(
            numberer(:equation, _counters(pagen, pid, secn, fign, subfig, eqn))
        )
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
    s = replace(s, _CITE_RE => m -> tok!(_cite_html(m, ctx, item)))
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

# Resolve `@cite(:key)` / `[text](@cite key)` to `[n]` linking to the References entry. An unknown
# key (absent from the bibliography) becomes `[?]` + a diagnostic (non-fatal).
function _cite_html(matched, ctx::EmitCtx, item::String)
    m = match(_CITE_RE, matched)
    text = m.captures[1]
    key = Symbol(m.captures[2] !== nothing ? m.captures[2] : m.captures[3])
    num = get(ctx.citenums, key, nothing)
    if num === nothing
        push!(ctx.rdiag, DiagEntry(WARNING, item, "@cite to unknown key :$(key)"))
        return "[?]"
    end
    label = (text !== nothing && !isempty(text)) ? _esc(text) : string("[", num, "]")
    return string("<a href=\"#ref-", _anchor(key), "\">", label, "</a>")
end

# Parse the @bibliography .bib source(s); a missing or unparseable file becomes a diagnostic.
function _load_bib(paths, rdiag::Vector{DiagEntry})
    bib = Dict{Symbol,BibEntry}()
    for p in paths
        if !isfile(p)
            push!(
                rdiag,
                DiagEntry(WARNING, "bibliography", "@bibliography file not found: $(p)"),
            )
            continue
        end
        try
            merge!(bib, parse_bib(p))
        catch e
            e isa InterruptException && rethrow()
            push!(rdiag, DiagEntry(WARNING, "bibliography", "failed to parse $(p): $(e)"))
        end
    end
    return bib
end

# Assign `[n]` to each cited key present in the bibliography, in document order of first appearance
# (scanning descs then captions). Returns (key -> n, ordered keys for the References list).
function _gallery_citations(doc::Document, bib::Dict{Symbol,BibEntry})
    citenums = Dict{Symbol,Int}()
    order = Symbol[]
    for pg in doc.pages, sec in pg.sections
        srcs = String[_descsrc(sec.desc)]
        for f in sec.figures
            push!(srcs, f.caption)
        end
        for src in srcs, m in eachmatch(_CITE_RE, src)
            key = Symbol(m.captures[2] !== nothing ? m.captures[2] : m.captures[3])
            if haskey(bib, key) && !haskey(citenums, key)
                push!(order, key)
                citenums[key] = length(order)
            end
        end
    end
    return citenums, order
end

# ---------- emit (the theme-dispatched entry point) ----------

# Resolve a page's thumbnail figure for the index cards (the model picks the FigRef:
# explicit @thumbnail > a thumbnail=true @figure > the page's first figure > none).
function _page_thumb(pg::Page)
    ref = resolved_thumbnail(pg)
    ref === nothing && return nothing
    for sec in pg.sections, f in sec.figures
        f.id === ref.id && return f
    end
    return nothing
end

# A thumbnail <img> source: a figure's first raster/vector asset, relative to `outdir`.
function _thumb_src(fig::Figure, outdir)
    for a in fig.assets
        _ext(a) in ("svg", "png", "jpg", "jpeg") &&
            return replace(relpath(a, outdir), '\\' => '/')
    end
    return nothing
end

# Shared <head> … <body> opener for every emitted file.
function _emit_head(io, title, doc, katex_mode, interactive, rdiag)
    print(io, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">")
    print(io, "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    print(io, "<title>", _esc(title), "</title>", _GALLERY_CSS, _katex_head(katex_mode))
    interactive && print(io, "<style>", _asset("pinax.css"), "</style>")
    _emit_overlay(io, doc.meta.css, "style", rdiag)   # user CSS overlay (notes 06 §5)
    return print(io, "</head><body>\n")
end

# Shared scripts + </body></html> closer.
function _emit_foot(io, doc, katex_mode, interactive, rdiag)
    interactive && print(io, "<script>", _asset("pinax.js"), "</script>")
    _emit_overlay(io, doc.meta.js, "script", rdiag)   # user JS overlay (notes 06 §5)
    print(io, _katex_foot(doc.newcommands, katex_mode))   # @newcommand -> KaTeX macros (notes 08 §2)
    return println(io, "</body></html>")
end

# A page's own Contents nav (its sections) followed by the sections themselves.
function _emit_page_body(theme, pg::Page, ctx::EmitCtx)
    io = ctx.io
    if !isempty(pg.sections)
        println(io, "<nav><strong>Contents</strong>")
        for sec in pg.sections
            n = length(sec.figures)
            cnt = n > 0 ? string(" <span class=\"nfig\">(", n, ")</span>") : ""
            println(io, "<a href=\"#", sec.anchor, "\">", _esc(sec.title), cnt, "</a>")
        end
        println(io, "</nav>")
    end
    for sec in pg.sections
        _emit_section(theme, sec, pg, ctx)
    end
    return nothing
end

# Single-page table-of-contents nav: page links + indented section links.
function _emit_toc_nav(doc::Document, io; has_bib::Bool=false)
    println(io, "<nav><strong>Contents</strong>")
    for pg in doc.pages
        println(io, "<a href=\"#", pg.anchor, "\">", _esc(pg.title), "</a>")
        for sec in pg.sections
            n = length(sec.figures)
            cnt = n > 0 ? string(" <span class=\"nfig\">(", n, ")</span>") : ""
            println(
                io,
                "<a href=\"#",
                sec.anchor,
                "\" style=\"margin-left:1.2rem\">",
                _esc(sec.title),
                cnt,
                "</a>",
            )
        end
    end
    has_bib && println(io, "<a href=\"#bibliography\">References</a>")
    return println(io, "</nav>")
end

# The index: one card per page (thumbnail + title + summary + counts) linking to `<page>.html`.
# `rich=true` (index level :rich) additionally lists each page's sections beneath its summary.
function _emit_cards(doc::Document, io, outdir; rich::Bool=false)
    println(io, "<div class=\"pinax-cards\">")
    for pg in doc.pages
        nfig = sum(length(s.figures) for s in pg.sections; init=0)
        nsec = length(pg.sections)
        tf = _page_thumb(pg)
        src = tf === nothing ? nothing : _thumb_src(tf, outdir)
        print(io, "<a class=\"pinax-card\" href=\"", pg.anchor, ".html\">")
        if src === nothing
            print(io, "<div class=\"card-thumb card-thumb-empty\"></div>")
        else
            print(
                io, "<div class=\"card-thumb\"><img src=\"", _esc(src), "\" alt=\"\"></div>"
            )
        end
        print(
            io,
            "<div class=\"card-body\"><div class=\"card-title\">",
            _esc(pg.title),
            "</div>",
        )
        pg.summary === nothing ||
            print(io, "<div class=\"card-summary\">", _esc(pg.summary), "</div>")
        if rich && !isempty(pg.sections)
            print(io, "<div class=\"card-sections\">")
            for sec in pg.sections
                print(
                    io,
                    "<div class=\"sec-item\"><span class=\"sec-name\">",
                    _esc(sec.title),
                    "</span>",
                )
                sec.summary === nothing || print(io, " — ", _esc(sec.summary))
                print(io, "</div>")
            end
            print(io, "</div>")
        end
        print(
            io,
            "<div class=\"card-meta\">",
            nsec,
            nsec == 1 ? " section · " : " sections · ",
            nfig,
            nfig == 1 ? " figure" : " figures",
            "</div></div></a>",
        )
    end
    return println(io, "</div>")
end

# A compact alternative index (level :toc): a link list with one-line summaries, no thumbnails.
function _emit_toc_index(doc::Document, io)
    println(io, "<ul class=\"pinax-toc\">")
    for pg in doc.pages
        nfig = sum(length(s.figures) for s in pg.sections; init=0)
        nsec = length(pg.sections)
        print(io, "<li><a href=\"", pg.anchor, ".html\">", _esc(pg.title), "</a>")
        pg.summary === nothing ||
            print(io, " <span class=\"toc-summary\">— ", _esc(pg.summary), "</span>")
        print(
            io,
            " <span class=\"toc-meta\">(",
            nsec,
            nsec == 1 ? " section, " : " sections, ",
            nfig,
            nfig == 1 ? " figure)" : " figures)",
            "</span></li>",
        )
    end
    return println(io, "</ul>")
end

# Emit the multi-page index at the resolved verbosity. `@pinaxsetup index=…` (meta.index) overrides
# the theme's `index_level`: :toc (link list) | :cards (thumbnail cards, default) | :rich (cards + sections).
function _emit_index(theme::GalleryTheme, doc::Document, io, outdir)
    level = something(doc.meta.index, index_level(theme))
    if level === :toc
        _emit_toc_index(doc, io)
    else
        _emit_cards(doc, io, outdir; rich=(level === :rich))
    end
    return nothing
end

"""
Emit the doc tree (also pass 3: materialize + draw). A single `@page` renders to one self-contained
`index.html`; multiple `@page`s render to one file per page (`<page>.html`) plus an `index.html` of
thumbnail cards linking to them (notes 02/06).
"""
function emit_document(
    theme::GalleryTheme,
    doc::Document,
    outdir::AbstractString,
    cache::RenderCache;
    comments_file::AbstractString=joinpath(outdir, "comments.toml"),
)
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
    bib = _load_bib(doc.meta.bib_sources, rdiag)
    citenums, citeorder = _gallery_citations(doc, bib)
    comments, bookmarks = read_comments(comments_file)
    features = doc.meta.features
    interactive = any(in(features), (:comments, :bookmarks, :export))
    katex_mode = doc.meta.katex
    katex_mode === :local && _copy_katex(outdir)   # vendor math assets for offline viewing
    merged_ids = merge(base_ids, ids_eq)
    mkpath(outdir)
    title = isempty(doc.meta.title) ? "Pinax gallery" : doc.meta.title
    mkctx(io) = EmitCtx(
        String(outdir),
        io,
        rdiag,
        cache,
        nums,
        merged_ids,
        eqseq,
        bib,
        citenums,
        comments,
        bookmarks,
        features,
    )

    if length(doc.pages) <= 1
        # One page (or none): a single self-contained file.
        io = IOBuffer()
        ctx = mkctx(io)
        _emit_head(io, title, doc, katex_mode, interactive, rdiag)
        println(io, "<h1>", _esc(title), "</h1>")
        ntotal = _total_figures(doc)
        println(
            io,
            "<div class=\"pinax-meta\">",
            ntotal,
            ntotal == 1 ? " figure" : " figures",
            "</div>",
        )
        interactive && _emit_committed_json(io, comments, bookmarks, features)
        _emit_toc_nav(doc, io; has_bib=(!isempty(citeorder)))
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
        _emit_bibliography(bib, citeorder, io)
        _emit_diagnostics(doc, rdiag, io)
        _emit_foot(io, doc, katex_mode, interactive, rdiag)
        path = joinpath(outdir, "index.html")
        write(path, String(take!(io)))
        return path
    end

    # Multiple pages: one file per page, then an index of thumbnail cards.
    for pg in doc.pages
        io = IOBuffer()
        ctx = mkctx(io)
        _emit_head(io, string(pg.title, " · ", title), doc, katex_mode, interactive, rdiag)
        println(
            io,
            "<nav class=\"pinax-top\"><a href=\"index.html\">← ",
            _esc(title),
            "</a></nav>",
        )
        println(io, "<h1>", _esc(pg.title), "</h1>")
        n = sum(length(s.figures) for s in pg.sections; init=0)
        println(
            io, "<div class=\"pinax-meta\">", n, n == 1 ? " figure" : " figures", "</div>"
        )
        interactive && _emit_committed_json(io, comments, bookmarks, features)
        println(io, "<section class=\"page\" id=\"", pg.anchor, "\">")
        _emit_page_body(theme, pg, ctx)
        println(io, "</section>")
        _emit_bibliography(bib, citeorder, io)
        _emit_foot(io, doc, katex_mode, interactive, rdiag)
        write(joinpath(outdir, pg.anchor * ".html"), String(take!(io)))
    end

    io = IOBuffer()
    _emit_head(io, title, doc, katex_mode, false, rdiag)
    println(io, "<h1>", _esc(title), "</h1>")
    ntotal = _total_figures(doc)
    npg = length(doc.pages)
    println(
        io,
        "<div class=\"pinax-meta\">",
        npg,
        " pages · ",
        ntotal,
        ntotal == 1 ? " figure" : " figures",
        "</div>",
    )
    _emit_index(theme, doc, io, outdir)
    _emit_diagnostics(doc, rdiag, io)
    _emit_foot(io, doc, katex_mode, false, rdiag)
    path = joinpath(outdir, "index.html")
    write(path, String(take!(io)))
    return path
end

# Total figure count across the document (shown in the header, e.g. "547 figures").
function _total_figures(doc::Document)
    return sum(length(sec.figures) for pg in doc.pages for sec in pg.sections; init=0)
end

function _emit_section(theme, sec::Section, pg::Page, ctx::EmitCtx)
    io = ctx.io
    bookmarked = (:bookmarks in ctx.features) && (Symbol(sec.anchor) in ctx.bookmarks)
    num = get(ctx.nums, sec.anchor, "")
    heading = isempty(num) ? _esc(sec.title) : string(_esc(num), ". ", _esc(sec.title))
    n = length(sec.figures)
    n > 0 && (heading *= string(" <span class=\"nfig\">(", n, ")</span>"))
    bookmarked && (heading *= " <span class=\"pinax-bm-on\" title=\"bookmarked\">★</span>")
    cls = bookmarked ? "section bookmarked" : "section"
    println(
        io, "<section class=\"", cls, "\" id=\"", sec.anchor, "\"><h2>", heading, "</h2>"
    )
    if sec.desc !== nothing
        println(
            io,
            "<div class=\"desc\">",
            _render_text(sec.desc.source, sec.anchor, ctx),
            "</div>",
        )
    end
    for panel in sec.panels        # @raw blocks, emitted verbatim (notes 06 §6)
        println(io, panel)
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
    _emit_comments(sec.anchor, ctx)
    return println(io, "</section>")
end

# Render the id-keyed comment turns for a node (a figure or a section) inline, co-located with their
# target so the binding is visually unambiguous (notes 01 §4): the communication layer over the
# figures (me / advisor / LLM). Author + markdown body, rendered server-side (raw HTML escaped).
function _emit_comments(anchor::String, ctx::EmitCtx)
    (:comments in ctx.features) || return nothing
    turns = get(ctx.comments, Symbol(anchor), Comment[])
    isempty(turns) && return nothing
    io = ctx.io
    println(io, "<div class=\"pinax-comments\">")
    for c in turns
        body = try
            _markdown(c.text)
        catch e
            e isa InterruptException && rethrow()
            _esc(c.text)
        end
        author = if isempty(c.author)
            ""
        else
            string("<span class=\"author\">", _esc(c.author), "</span> ")
        end
        println(io, "<div class=\"pinax-cmt\">", author, body, "</div>")
    end
    return println(io, "</div>")
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

# Extract param axis `facet` from a figure's params, or `missing` if absent. Used by `_facet_groups`
# for `by=` faceting (notes 05). The PinaxParamIOExt extension specializes this on a ParamIO.DataKey;
# the core has no param axes to read and returns `missing` (faceting is then a no-op).
_facet_value(p, facet) = missing

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
    _emit_comments(fig.anchor, ctx)   # co-located: a figure's comments live in its card
    return println(io, "</figure>")
end

# References section (notes 03): cited entries in citation order, each anchored (`ref-<key>`) so a
# `@cite` link resolves to it; the entry hyperlinks to its DOI / URL / arXiv id when present.
function _emit_bibliography(bib::Dict{Symbol,BibEntry}, citeorder::Vector{Symbol}, io)
    isempty(citeorder) && return nothing
    println(
        io, "<section class=\"bibliography\" id=\"bibliography\"><h2>References</h2><ol>"
    )
    for key in citeorder
        e = bib[key]
        link = bib_link(e)
        linkhtml = if link === nothing
            ""
        else
            string(
                " <a href=\"",
                _esc(link),
                "\" target=\"_blank\" rel=\"noopener\">",
                bib_link_label(link),
                "</a>",
            )
        end
        println(
            io,
            "<li id=\"ref-",
            _anchor(key),
            "\">",
            _esc(format_bib_entry(e)),
            linkhtml,
            "</li>",
        )
    end
    return println(io, "</ol></section>")
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

# Register as the default theme, resolved by the `:gallery` symbol.
register_theme!(:gallery, GalleryTheme())
