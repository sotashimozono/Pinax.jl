# document.jl — document model + structure macros (notes 02).
#
# Implements render pass 1 (structure): the macros only assemble the doc tree
# (placeholders). The `@figure` expression is NOT evaluated here — it is captured
# as the deferred generator `gen` (materialize happens in pass 3).

# ============================================================ value types

"Markdown + LaTeX source (unrendered; the theme draws it)."
struct Desc
    source::String
end

"Lightweight handle pointing at a figure (used by thumbnails, etc.)."
struct FigRef
    id::Symbol
end

"Diagnostic severity (notes 09)."
@enum Severity ERROR WARNING INFO

"One diagnostic. `item` is the anchor of the related page/section/figure."
struct DiagEntry
    severity::Severity
    item::String
    message::String
end

"error/warning entries collected during render (-> diagnostics page, notes 09)."
struct Diagnostics
    entries::Vector{DiagEntry}
end
Diagnostics() = Diagnostics(DiagEntry[])

"""
Default numbering function: `Sec. N` / `Fig. N` / `(N)` for equations. Override it in the
preamble with `@pinaxsetup numberer = (kind, c) -> …`, where `kind` is `:section`, `:figure`,
or `:equation` and `c` is `(; page, page_id, section, figure, subfigure, equation)` — `page` is
the 1-based page index and `page_id` its id (Symbol), so a numberer can prefix per "part" (e.g.
`c.page_id === :eq ? "EQ\$(c.section)" : "GQ\$(c.section)"`, usually with `numbering=:page`);
`section` is the current section number, `figure` the document-wide figure count, `subfigure`
the figure's index within its section (for hierarchical schemes like `Fig. 2.3`), and `equation`
the document-wide equation count.
"""
function _default_numberer(kind::Symbol, c)
    kind === :page && return ""   # pages are titled, not numbered, by default (override for EQ/GQ-style badges)
    kind === :section && return "Sec. $(c.section)"
    kind === :figure && return "Fig. $(c.figure)"
    return "($(c.equation))"   # :equation — paper-style "(n)"
end

"Document settings (analogous to TeX \\documentclass + preamble)."
mutable struct DocMeta
    title::String
    theme::Any                    # theme spec: a Theme instance, a registered Symbol, or a path
    base_url::String
    format::Vector{Symbol}        # [:svg, :pdf]
    bib_sources::Vector{String}
    debug::Bool
    index::Union{Symbol,Nothing}  # :toc|:cards|:rich override (nothing = theme default)
    numbering::Symbol             # numbering scope :global|:page (reset counters per page)
    numberer::Function            # (kind, counters) -> label string; preamble-overridable
    features::Vector{Symbol}      # gallery interactive layer toggles: :comments / :bookmarks / :export
    css::Vector{String}           # user CSS overlay files (inlined after the theme's own CSS)
    js::Vector{String}            # user JS overlay files (inlined after the theme's own JS)
    katex::Symbol                 # gallery math assets: :cdn (default) | :local (vendored, offline)
    assets::Symbol                # theme CSS/JS: :default (separate style.css/app.js) | :inline (embedded)
end
function DocMeta(;
    title="",
    theme=:gallery,
    base_url="",
    format=Symbol[:svg, :pdf],
    bib_sources=String[],
    debug=false,
    index=nothing,
    numbering=:global,
    numberer=_default_numberer,
    features=Symbol[:comments, :bookmarks, :export],
    css=String[],
    js=String[],
    katex=:cdn,
    assets=:default,
)
    return DocMeta(
        title,
        theme,
        base_url,
        collect(Symbol, format),
        bib_sources,
        debug,
        index,
        numbering,
        numberer,
        collect(Symbol, features),
        collect(String, css),
        collect(String, js),
        katex,
        assets,
    )
end

"A single figure (placeholder). `gen` is deferred; `code` is the expression source for change detection (notes 10)."
mutable struct Figure
    id::Symbol
    anchor::String
    caption::String
    params::Any           # ParamIO.DataKey | Nothing — lineage + cache key material
    gen::Function         # () -> plot(...) (never called during structure)
    code::String          # @figure expression source
    thumbnail::Bool       # thumbnail=true marker
    assets::Vector{String}
end

"""
A table artifact — structured tabular data, a sibling to `Figure`. Renders as an HTML/LaTeX table for
humans and as structured rows for the agent backend. Inherently LLM-legible (it is already data).
"""
mutable struct Table
    id::Symbol
    anchor::String
    caption::String
    header::Vector{String}
    rows::Vector{Vector{Any}}
    code::String          # @table data-expression source (provenance)
    params::Any
end

# A table cell as display text (HTML/LaTeX backends; the agent backend keeps native JSON types).
_cellstr(x) = x === missing ? "" : string(x)

"A section (a group of figures + a description)."
mutable struct Section
    id::Symbol
    title::String
    anchor::String
    facet::Any                       # by= param axis (String|Tuple|Nothing)
    desc::Union{Desc,Nothing}
    summary::Union{String,Nothing}   # for index :rich
    thumbnail::Union{FigRef,Nothing} # section-level main figure
    layout::Union{Symbol,Nothing}    # :wide|:grid|:single (theme hint)
    figures::Vector{Figure}
    panels::Vector{String}           # @raw HTML blocks (project-specific UI escape hatch, notes 06 §6)
    tables::Vector{Table}            # @table artifacts
end

"""
A page = one standalone HTML file (the unit of pagination). It groups in-page `Section`s and/or
carries its own figures directly (page-as-leaf: a `@page` with figures and no `@section`). Pages are
optionally grouped into a `@part` (a navigation grouping, not a file) named by `part`.
"""
mutable struct Page
    id::Symbol
    title::String
    summary::Union{String,Nothing}   # one-line page description, shown on the multi-page index (card or toc)
    anchor::String
    thumbnail::Union{FigRef,Nothing} # explicit @thumbnail
    no_thumbnail::Bool
    sections::Vector{Section}
    part::Union{Symbol,Nothing}      # the @part this page belongs to (navigation grouping), or nothing
    desc::Union{Desc,Nothing}        # page-level description (page-as-leaf: @desc directly under @page)
    figures::Vector{Figure}          # page-level figures (page-as-leaf: @figure with no enclosing @section)
    panels::Vector{String}           # page-level @raw blocks
    layout::Union{Symbol,Nothing}    # :grid|:single|:wide hint for the page-level figure grid
    tables::Vector{Table}            # page-level @table artifacts (page-as-leaf)
end

"Implicit top level (the catalogue). Order = tree position; numbers are not stored (numbering is the theme's job)."
mutable struct Document
    meta::DocMeta
    pages::Vector{Page}
    parts::Vector{Pair{Symbol,String}}   # ordered @part registry: id => title (navigation groups)
    part_descs::Dict{Symbol,Desc}        # @part id => overview description (markdown), shown on the index
    refs::Dict{Symbol,Any}        # label -> node (filled in by resolve)
    bib::Dict{Symbol,Any}         # @cite resolution table (later)
    diag::Diagnostics
    newcommands::Dict{String,String}
end
function Document(meta::DocMeta=DocMeta())
    return Document(
        meta,
        Page[],
        Pair{Symbol,String}[],
        Dict{Symbol,Desc}(),
        Dict{Symbol,Any}(),
        Dict{Symbol,Any}(),
        Diagnostics(),
        Dict{String,String}(),
    )
end

# ============================================================ build context

"Build state of the implicit global document (current part/page/section)."
mutable struct BuildContext
    document::Union{Document,Nothing}
    part::Union{Symbol,Nothing}      # the @part currently open (pages inherit it), or nothing
    page::Union{Page,Nothing}
    section::Union{Section,Nothing}
end
const CTX = BuildContext(nothing, nothing, nothing, nothing)

current_document() = CTX.document
current_page() = CTX.page
current_section() = CTX.section

"Reset the implicit document (fresh, empty). The preamble `@pinaxsetup` calls this."
function reset!(; kwargs...)
    kw = Dict{Symbol,Any}(kwargs)
    idx = get(kw, :index, nothing)
    idx === nothing ||
        idx in (:toc, :cards, :rich) ||
        error(
            "Pinax: @pinaxsetup index= must be :toc, :cards, or :rich (got $(repr(idx)))."
        )
    ast = get(kw, :assets, :default)
    ast in (:default, :inline) ||
        error("Pinax: @pinaxsetup assets= must be :default or :inline (got $(repr(ast))).")
    meta = DocMeta(;
        title=get(kw, :title, ""),
        theme=get(kw, :theme, :gallery),
        base_url=get(kw, :base_url, ""),
        format=get(kw, :format, Symbol[:svg, :pdf]),
        debug=get(kw, :debug, false),
        index=idx,
        numbering=get(kw, :numbering, :global),
        numberer=get(kw, :numberer, _default_numberer),
        features=get(kw, :features, Symbol[:comments, :bookmarks, :export]),
        css=get(kw, :css, String[]),
        js=get(kw, :js, String[]),
        katex=get(kw, :katex, :cdn),
        assets=ast,
    )
    CTX.document = Document(meta)
    CTX.part = nothing
    CTX.page = nothing
    CTX.section = nothing
    return CTX.document
end

_ensure_document!() = (CTX.document === nothing && reset!(); CTX.document)

"Build a scoped document: `doc = document() do … end` (for test isolation)."
function document(f)
    saved = (CTX.document, CTX.part, CTX.page, CTX.section)
    CTX.document = Document()
    CTX.part = nothing
    CTX.page = nothing
    CTX.section = nothing
    local doc
    try
        f()
        doc = CTX.document        # capture after f, so a @pinaxsetup reset! inside f is still picked up
    finally
        CTX.document, CTX.part, CTX.page, CTX.section = saved
    end
    return doc
end

# ============================================================ helpers

# Anchor used both in HTML attributes and as a filesystem path component, so restrict it to a safe charset.
_anchor(id::Symbol) = replace(string(id), r"[^A-Za-z0-9_-]" => "_")
# Container = a Section or a page-as-leaf Page; both have `.id` and `.figures`.
_auto_fig_id(c) = Symbol(string(c.id), "_fig", length(c.figures) + 1)
_auto_table_id(c) = Symbol(string(c.id), "_tbl", length(c.tables) + 1)

# Stringify the @figure expression for change detection, stripping source line numbers so that
# moving a figure to a different line does not spuriously invalidate its cache entry (notes 10).
_code_str(expr) = string(expr isa Expr ? Base.remove_linenums!(deepcopy(expr)) : expr)

# A filesystem-safe, param-derived tag for a figure id, or `nothing`. The PinaxParamIOExt extension
# specializes this on a ParamIO.DataKey (so a sweep keeps each figure's id across reordering); the
# core has no param scheme and returns `nothing`.
_param_tag(params) = nothing

# Structured description of a figure's `params` binding — an ordered `Vector{Pair{String,Any}}` of
# axis => value — for the agent backend's data-reconciliation view (an LLM sees the bound axes, not a
# repr blob). `nothing` means "no introspectable scheme" (the agent then falls back to a string).
# A NamedTuple keeps its declared order; a Dict is sorted for determinism; the PinaxParamIOExt
# extension specializes this on a ParamIO.DataKey (delegating to its dotted-key param Dict).
_params_describe(params) = nothing
_params_describe(nt::NamedTuple) = Pair{String,Any}[string(k) => v for (k, v) in pairs(nt)]
function _params_describe(d::AbstractDict)
    return Pair{String,Any}[string(k) => d[k] for k in sort!(collect(keys(d)); by=string)]
end

# Figure id: an explicit `id` wins; else a param-derived tag (via the extension); else positional.
# `c` is the enclosing container (a Section, or a page-as-leaf Page).
function _fig_id(c, id, params)
    id === nothing || return id
    tag = _param_tag(params)
    tag === nothing && return _auto_fig_id(c)
    return Symbol(string(c.id), "_", tag)
end

function _diag!(sev::Severity, item, msg)
    doc = CTX.document
    if doc === nothing
        @warn "Pinax diagnostic dropped (no active document)" severity = sev item = string(
            item
        ) message = msg
    else
        push!(doc.diag.entries, DiagEntry(sev, string(item), msg))
    end
    return nothing
end

# key=val Exprs -> Expr(:kw, …) (values escaped). Macro-internal.
function _kwspecs(args)
    return Expr[
        if (a isa Expr && a.head === :(=))
            Expr(:kw, a.args[1], esc(a.args[2]))
        else
            error("expected key=value, got $(a)")
        end for a in args
    ]
end

# Build a call Expr. With no kwspecs, omit the `;` (an empty Expr(:parameters) is invalid syntax).
function _call(f, posargs, kwspecs)
    return if isempty(kwspecs)
        Expr(:call, f, posargs...)
    else
        Expr(:call, f, Expr(:parameters, kwspecs...), posargs...)
    end
end

# ============================================================ preamble macros

"Document settings + reset of the implicit document. `@pinaxsetup theme=… index=… numbering=… debug=…`"
macro pinaxsetup(args...)
    return _call(:reset!, (), _kwspecs(args))
end

"Diagnostics mode. `@debug_mode true`"
macro debug_mode(x)
    return quote
        _ensure_document!().meta.debug = $(esc(x))
        nothing
    end
end

"Declare the .bib source(s) used to resolve `@cite`. `@bibliography \"refs/a.bib\" …`"
macro bibliography(paths...)
    ps = map(esc, paths)
    return quote
        append!(_ensure_document!().meta.bib_sources, String[$(ps...)])
        nothing
    end
end

"Notation macro. `@newcommand \"\\E\" raw\"\\langle H\\rangle\"`"
macro newcommand(name, def)
    return quote
        _ensure_document!().newcommands[$(esc(name))] = $(esc(def))
        nothing
    end
end

# ============================================================ structure macros

"A page. `@page :id \"Title\" [summary=…] begin … end`"
macro page(args...)
    length(args) >= 3 || error("@page needs :id, \"title\", and a begin…end body")
    id, title, body = args[1], args[2], args[end]
    enter = _call(:_enter_page!, (esc(id), esc(title)), _kwspecs(args[3:(end - 1)]))
    return quote
        $enter
        try
            $(esc(body))
        finally
            _exit_page!()
        end
        nothing
    end
end

function _enter_page!(id::Symbol, title; summary=nothing, layout=nothing)
    layout === nothing ||
        layout in (:grid, :single, :wide) ||
        error(
            "Pinax: @page layout= must be :grid, :single, or :wide (got $(repr(layout)))."
        )
    doc = _ensure_document!()
    pg = Page(
        id,
        string(title),
        summary === nothing ? nothing : string(summary),
        _anchor(id),
        nothing,
        false,
        Section[],
        CTX.part,          # inherit the open @part, if any
        nothing,
        Figure[],
        String[],
        layout,
        Table[],
    )
    push!(doc.pages, pg)
    CTX.page = pg
    CTX.section = nothing
    return pg
end
_exit_page!() = (CTX.page=nothing; CTX.section=nothing)

"""
A navigation group of pages (LaTeX `\\part`). `@part :id \"Title\" [desc=md\"…\"] begin … end` — the
pages declared inside belong to this part and are grouped (collapsibly) under it in the index and nav.
`desc=` is an overview shown beneath the part heading on the index (what this whole group covers).
A part is NOT a file; each `@page` (or top-level `@section`) inside it is still its own HTML page.
"""
macro part(args...)
    length(args) >= 3 || error("@part needs :id, \"title\", and a begin…end body")
    id, title, body = args[1], args[2], args[end]
    enter = _call(:_enter_part!, (esc(id), esc(title)), _kwspecs(args[3:(end - 1)]))
    return quote
        $enter
        try
            $(esc(body))
        finally
            _exit_part!()
        end
        nothing
    end
end

function _enter_part!(id::Symbol, title; desc=nothing)
    doc = _ensure_document!()
    # register (id => title) once, in declaration order, for the grouped navigation
    any(p -> first(p) === id, doc.parts) || push!(doc.parts, id => string(title))
    desc === nothing || (doc.part_descs[id] = Desc(string(desc)))
    CTX.part = id
    CTX.page = nothing
    CTX.section = nothing
    return id
end
_exit_part!() = (CTX.part=nothing; CTX.page=nothing; CTX.section=nothing)

"A section. `@section :id \"Title\" [by=…] [summary=…] [layout=…] begin … end`"
macro section(args...)
    length(args) >= 3 || error("@section needs :id, \"title\", and a begin…end body")
    id, title, body = args[1], args[2], args[end]
    enter = _call(:_enter_section!, (esc(id), esc(title)), _kwspecs(args[3:(end - 1)]))
    return quote
        $enter
        try
            $(esc(body))
        finally
            _exit_section!()
        end
        nothing
    end
end

function _enter_section!(id::Symbol, title; by=nothing, summary=nothing, layout=nothing)
    pg = CTX.page
    pg === nothing && error("@section outside of a @page")
    layout === nothing ||
        layout in (:grid, :single, :wide) ||
        error(
            "Pinax: @section layout= must be :grid, :single, or :wide (got $(repr(layout))).",
        )
    sec = Section(
        id,
        string(title),
        _anchor(id),
        by,
        nothing,
        summary === nothing ? nothing : string(summary),
        nothing,
        layout,
        Figure[],
        String[],
        Table[],
    )
    push!(pg.sections, sec)
    CTX.section = sec
    return sec
end
_exit_section!() = (CTX.section = nothing)

"Register a plot; the expression is DEFERRED. `@figure expr [params=…] [caption=…] [id=…] [thumbnail=…]` / `@figure [kw] begin … end`"
macro figure(args...)
    isempty(args) && error("@figure needs a plot expression")
    expr = nothing
    kws = Expr[]
    for a in args
        if a isa Expr &&
            a.head === :(=) &&
            a.args[1] isa Symbol &&
            a.args[1] in (:params, :caption, :id, :thumbnail)
            push!(kws, a)
        elseif expr === nothing
            expr = a
        else
            error("@figure takes a single plot expression (plus kwargs)")
        end
    end
    expr === nothing && error("@figure needs a plot expression")
    allk = vcat(
        Expr(:kw, :gen, Expr(:(->), Expr(:tuple), esc(expr))),
        Expr(:kw, :code, _code_str(expr)),
        _kwspecs(kws),
    )
    return _call(:_push_figure!, (), allk)
end

# The container the content macros write into: the open @section, else the open @page (page-as-leaf).
# Returns `nothing` if neither is open.
_current_container() = CTX.section !== nothing ? CTX.section : CTX.page

function _push_figure!(; gen, code, params=nothing, caption="", id=nothing, thumbnail=false)
    c = _current_container()
    c === nothing && error("@figure outside of a @section or @page")
    fid = _fig_id(c, id, params)
    fig = Figure(fid, _anchor(fid), string(caption), params, gen, code, thumbnail, String[])
    push!(c.figures, fig)
    return fig
end

"""
Register a table artifact — first-class tabular data (sibling to `@figure`). `data` may be a
NamedTuple of columns `(T=…, M=…)`, a `Matrix` (with `header=`), a `Vector` of NamedTuple rows, or a
`Vector` of row-vectors/tuples (with `header=`). `@table data [caption=…] [id=…] [header=…] [params=…]`.
"""
macro table(args...)
    isempty(args) && error("@table needs a data expression")
    data = nothing
    kws = Expr[]
    for a in args
        if a isa Expr &&
            a.head === :(=) &&
            a.args[1] isa Symbol &&
            a.args[1] in (:caption, :id, :header, :params)
            push!(kws, a)
        elseif data === nothing
            data = a
        else
            error("@table takes a single data expression (plus kwargs)")
        end
    end
    data === nothing && error("@table needs a data expression")
    allk = vcat(
        Expr(:kw, :data, esc(data)), Expr(:kw, :code, _code_str(data)), _kwspecs(kws)
    )
    return _call(:_push_table!, (), allk)
end

function _push_table!(; data, code, caption="", id=nothing, header=nothing, params=nothing)
    c = _current_container()
    c === nothing && error("@table outside of a @section or @page")
    hdr, rows = _normalize_table(data, header)
    if !isempty(hdr)   # every row must be header-wide (catches a wrong-length header= or ragged rows)
        bad = findfirst(r -> length(r) != length(hdr), rows)
        bad === nothing || error(
            "Pinax: @table row $(bad) has $(length(rows[bad])) cells but the header has " *
            "$(length(hdr)) columns — check `header=` length or ragged rows",
        )
    end
    tid = id === nothing ? _auto_table_id(c) : id
    tbl = Table(tid, _anchor(tid), string(caption), hdr, rows, code, params)
    push!(c.tables, tbl)
    return tbl
end

# Normalize the accepted @table inputs into (header::Vector{String}, rows::Vector{Vector{Any}}).
function _normalize_table(data, header)
    if data isa NamedTuple                          # columnar: (a=[…], b=[…])
        cols = collect(values(data))
        hdr = header === nothing ? collect(string.(keys(data))) : collect(string.(header))
        n = isempty(cols) ? 0 : maximum(length, cols)
        rows = [Any[i <= length(c) ? c[i] : missing for c in cols] for i in 1:n]
        return hdr, rows
    elseif data isa AbstractMatrix
        nc = size(data, 2)
        hdr = header === nothing ? [string(j) for j in 1:nc] : collect(string.(header))
        rows = [Any[data[i, j] for j in 1:nc] for i in 1:size(data, 1)]
        return hdr, rows
    elseif data isa AbstractVector
        if !isempty(data) && first(data) isa NamedTuple   # row records: [(a=…,b=…), …]
            ks = keys(first(data))
            hdr = header === nothing ? collect(string.(ks)) : collect(string.(header))
            rows = [Any[getfield(r, k) for k in ks] for r in data]
            return hdr, rows
        else                                              # vector of row-vectors/tuples
            rows = [Any[x for x in r] for r in data]
            width = isempty(rows) ? 0 : length(rows[1])
            hdr =
                header === nothing ? [string(j) for j in 1:width] : collect(string.(header))
            return hdr, rows
        end
    end
    return error(
        "Pinax: @table data must be a NamedTuple of columns, a Matrix, or a Vector of " *
        "NamedTuple/Vector rows (got $(typeof(data)))",
    )
end

"Attach a caption to the preceding `@figure` (like `\\caption`); it overwrites any `caption=` set there, since it runs afterward."
macro caption(x)
    return quote
        _set_caption!($(esc(x)))
    end
end
function _set_caption!(s)
    c = _current_container()
    if c === nothing || isempty(c.figures)
        _diag!(
            WARNING, c === nothing ? "?" : c.anchor, "@caption with no preceding @figure"
        )
    else
        c.figures[end].caption = string(s)
    end
    return nothing
end

"Section description (markdown + LaTeX source). `@desc md\"…\"`"
macro desc(x)
    return quote
        _set_desc!($(esc(x)))
    end
end
function _set_desc!(s)
    c = _current_container()
    c === nothing && error("@desc outside of a @section or @page")
    c.desc = Desc(string(s))
    return nothing
end

"""
Inject a raw block into the current section — the escape hatch for project-specific UI that markdown
can't express (coverage tables, broken-data banners; notes 06 §6). `@raw x` evaluates `x` to a
string and the theme emits it verbatim (the gallery as raw HTML; trusted author content):
`@raw raw\"<table class=cov>…</table>\"`. Use `@desc` for prose; `@raw` for hand-built markup.
"""
macro raw(x)
    return quote
        _push_panel!($(esc(x)))
    end
end
function _push_panel!(s)
    c = _current_container()
    c === nothing && error("@raw outside of a @section or @page")
    push!(c.panels, string(s))
    return nothing
end

"Set the page main figure. `@thumbnail :figid` (priority: explicit `@thumbnail` > a `thumbnail=true` `@figure` > the top figure; notes 02 resolve)."
macro thumbnail(x)
    return quote
        _set_thumbnail!($(esc(x)))
    end
end
function _set_thumbnail!(x)
    pg = CTX.page
    pg === nothing && error("@thumbnail outside of a @page")
    if x isa Symbol
        pg.thumbnail = FigRef(x)
    else
        _diag!(
            WARNING,
            pg.anchor,
            "@thumbnail expects a figure id (:sym); inline plots are not supported",
        )
    end
    return nothing
end

"This page contributes no main figure to the index."
macro no_thumbnail()
    return quote
        pg = CTX.page
        pg === nothing && error("@no_thumbnail outside of a @page")
        pg.no_thumbnail = true
        nothing
    end
end

"Raw string (preserves `\$…\$`). Used by `@desc md\"…\"` etc."
macro md_str(s)
    return s
end

# ============================================================ resolve (minimal: thumbnail)

"Resolve a page's main figure: explicit `@thumbnail` > `thumbnail=true` marker > top (first) figure (notes 02)."
function resolved_thumbnail(pg::Page)
    pg.no_thumbnail && return nothing
    pg.thumbnail === nothing || return pg.thumbnail
    # a thumbnail=true marker anywhere (page-level figures first, then sections)
    for f in pg.figures
        f.thumbnail && return FigRef(f.id)
    end
    for sec in pg.sections, f in sec.figures
        f.thumbnail && return FigRef(f.id)
    end
    # else the first figure (page-level, then the first section's)
    isempty(pg.figures) || return FigRef(pg.figures[1].id)
    for sec in pg.sections
        isempty(sec.figures) || return FigRef(sec.figures[1].id)
    end
    return nothing
end

# ============================================================ show (ergonomics)

function Base.show(io::IO, d::Document)
    return print(
        io,
        "Pinax.Document(",
        length(d.pages),
        " pages, theme=",
        repr(d.meta.theme),
        ", ",
        length(d.diag.entries),
        " diag)",
    )
end
function Base.show(io::IO, p::Page)
    return print(io, "Pinax.Page(", repr(p.id), ", ", length(p.sections), " sections)")
end
function Base.show(io::IO, s::Section)
    return print(io, "Pinax.Section(", repr(s.id), ", ", length(s.figures), " figures)")
end
function Base.show(io::IO, f::Figure)
    return print(
        io, "Pinax.Figure(", repr(f.id), f.params === nothing ? "" : ", params=set", ")"
    )
end
