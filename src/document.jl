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
    data::Any             # eager plotted-data (`@figure … data=(; x, y[, series])`) | nothing.
    # When set, the agent backend emits the figure's data table from THIS — no `gen()`, hence no
    # plotting backend — so the LLM artifact (agent.json) is producible Plots/Makie-free.
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

"""
A single PASS/FAIL check (a `@expect`) — one assertion of a computed value against a reference, the
atom of a `@benchmark` test set. `delta` is the resolved deviation (relative or absolute per `kind`),
`pass` is `delta <= tol`. Renders to a row of the gallery's fixed test-report, a LaTeX tabular row,
and a native-typed JSON object in `agent.json` (the machine-readable verdict).
"""
mutable struct Check
    id::Symbol
    label::String
    got::Float64
    want::Float64
    delta::Float64     # resolved (rel or abs) deviation
    tol::Float64
    kind::Symbol       # :rel or :abs (resolved; never :auto in the struct)
    pass::Bool
end

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
    checks::Vector{Check}            # @expect PASS/FAIL checks (a @benchmark test set)
    content::Vector{Pair{Symbol,Int}}  # declaration order: (:figure|:table|:panel|:check) => index into the list above
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
    checks::Vector{Check}            # page-level @expect checks (a @benchmark test set)
    content::Vector{Pair{Symbol,Int}}  # declaration order of figures/tables/panels/checks
    status::Symbol                   # maturity tag a backend/registry interprets: :final (default, the
    # shaped/curated page) vs :trial (a raw experiment attempt) vs :benchmark (a `@benchmark` test set,
    # which each backend dispatches on to render a verdict / fixed test-report). Pinax only carries it.
end

# All checks on a benchmark page in declaration order: page-level @expect PLUS any inside a @section.
_benchmark_checks(pg::Page) = vcat(pg.checks, (s.checks for s in pg.sections)...)

# Single source of the verdict invariant — used by every backend so PASS/FAIL can never diverge.
function _benchmark_verdict(checks)
    passed = count(c -> c.pass, checks)
    total = length(checks)
    return (
        passed=passed,
        total=total,
        verdict=(passed == total ? "PASS" : "FAIL"),
        failed=[string(c.id) for c in checks if !c.pass],
    )
end

"Implicit top level (the catalogue). Order = tree position; numbers are not stored (numbering is the theme's job)."
mutable struct Document
    meta::DocMeta
    pages::Vector{Page}
    parts::Vector{Pair{Symbol,String}}   # ordered @part registry: id => title (navigation groups)
    part_descs::Dict{Symbol,Desc}        # @part id => overview description (markdown), shown on the index
    part_status::Dict{Symbol,Symbol}     # @part id => default status its pages inherit (e.g. :trial)
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
        Dict{Symbol,Symbol}(),
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

# The test bridge (`PinaxTestExt`) registers a probe here when `Test` is loaded; it stays `nothing`
# for the manuscript path, which then pays only a `Ref` read. The probe returns the innermost open
# Pinax *test* container (a `PinaxTestSet`), or `:inert` (inside a test that is NOT capturing — the
# report is off), or `:none` (not inside a testset at all). Kept `Test`-free by indirection: core
# reads a `Ref`, the extension supplies the closure at load — no method the extension must overwrite.
const _TEST_CONTAINER_PROBE = Base.RefValue{Any}(nothing)
_probe_test_container() = (p=_TEST_CONTAINER_PROBE[]; p === nothing ? :none : p())

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

"""
A page. `@page :id "Title" [summary=…] [layout=…] [status=…] begin … end`

`status` tags the page's maturity so a backend or registry can treat trial and result differently:
`:final` (default — the shaped/curated page) vs `:trial` (a raw experiment attempt). Pinax only carries
the tag (any `Symbol` is accepted, e.g. `:experimental`/`:draft`); the agent backend exposes it as
`"status"` for RAG/Archeion filtering and the gallery badges non-`:final` pages. A page inherits its
enclosing `@part`'s status default unless it sets its own.
"""
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

function _enter_page!(id::Symbol, title; summary=nothing, layout=nothing, status=nothing)
    layout === nothing ||
        layout in (:grid, :single, :wide) ||
        error(
            "Pinax: @page layout= must be :grid, :single, or :wide (got $(repr(layout)))."
        )
    doc = _ensure_document!()
    # status resolution: explicit @page status= wins; else inherit the open @part's
    # default status; else :final (the ordinary shaped/curated page).
    st = status === nothing ? get(doc.part_status, CTX.part, :final) : Symbol(status)
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
        Check[],
        Pair{Symbol,Int}[],
        st,
    )
    push!(doc.pages, pg)
    CTX.page = pg
    CTX.section = nothing
    return pg
end
_exit_page!() = (CTX.page=nothing; CTX.section=nothing)

"""
A benchmark / test-set page. `@benchmark :id "Title" [summary=…] [layout=…] begin … end` — a `@page`
whose `status` is fixed to `:benchmark`, holding `@expect` checks (plus any `@page` content:
`@desc`/`@figure`/`@table`/`@section` — a `@section`'s `@expect`s count toward the verdict too).
Each backend dispatches on the `:benchmark` status to render a verdict: a machine-readable `benchmark`
block in `agent.json`, a fixed-layout test-report in the gallery, and a tabular + verdict line in
LaTeX. Mirrors `@page` (it IS a page); `@expect` populates the page's `checks`.
"""
macro benchmark(args...)
    length(args) >= 3 || error("@benchmark needs :id, \"title\", and a begin…end body")
    id, title, body = args[1], args[2], args[end]
    # a @benchmark is a @page pinned to status=:benchmark — append it to whatever kwargs were given
    enter = _call(
        :_enter_page!,
        (esc(id), esc(title)),
        vcat(_kwspecs(args[3:(end - 1)]), Expr(:kw, :status, QuoteNode(:benchmark))),
    )
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

"""
A navigation group of pages (LaTeX `\\part`). `@part :id \"Title\" [desc=md\"…\"] begin … end` — the
pages declared inside belong to this part and are grouped (collapsibly) under it in the index and nav.
`desc=` is an overview shown beneath the part heading on the index (what this whole group covers).
A part is NOT a file; each `@page` (or top-level `@section`) inside it is still its own HTML page.
`status=` sets a default maturity (e.g. `:trial`) that the part's pages inherit — so a whole
"Trials / experiment log" group is declared once, the shaped result living in a separate part.
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

function _enter_part!(id::Symbol, title; desc=nothing, status=nothing)
    doc = _ensure_document!()
    # register (id => title) once, in declaration order, for the grouped navigation
    any(p -> first(p) === id, doc.parts) || push!(doc.parts, id => string(title))
    desc === nothing || (doc.part_descs[id] = Desc(string(desc)))
    status === nothing || (doc.part_status[id] = Symbol(status))   # default status its pages inherit
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
        Check[],
        Pair{Symbol,Int}[],
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
            a.args[1] in (:params, :caption, :id, :thumbnail, :data)
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

# The manuscript container from the module-global build state only (no probe). The test-report fold
# builds a `Document` in `CTX` post-hoc and must resolve against `CTX` directly — never the probe,
# which could still see the finishing root testset. This is also the one integration seam: every
# content macro resolves its target through `_current_container` below and nowhere else.
_ctx_container() = CTX.section !== nothing ? CTX.section : CTX.page

# Precedence: an open Pinax *test* container (report on) captures the test content; else an open
# manuscript `CTX` container wins — a manuscript built even *inside* a stock `@testset` (as Pinax's
# own tests do) must still go to `CTX`; else, if we are inside a stock testset with no manuscript
# open, the content is test content with the report OFF → `:inert` (the caller no-ops, invariant V);
# else nothing is open at all → `nothing` (the caller errors on manuscript misuse).
function _current_container()
    ctx = _ctx_container()
    ctx === nothing || return ctx                   # an EXPLICITLY-open manuscript container wins — a
    # manuscript built inside a test (even a captured one, via `document()`/`@page`) writes to `CTX`,
    # not the testset; only when nothing is open does the enclosing testset capture the content.
    tc = _probe_test_container()
    (tc === :none || tc === :inert) || return tc    # an open PinaxTestSet — capture the test content
    return tc === :inert ? :inert : nothing
end

function _push_figure!(;
    gen, code, params=nothing, caption="", id=nothing, thumbnail=false, data=nothing
)
    c = _current_container()
    c === :inert && return nothing   # inside a test with the report off — no-op (invariant V)
    c === nothing && error("@figure outside of a @section or @page")
    fid = _fig_id(c, id, params)
    fig = Figure(
        fid, _anchor(fid), string(caption), params, gen, code, thumbnail, String[], data
    )
    push!(c.figures, fig)
    push!(c.content, :figure => length(c.figures))
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
    c === :inert && return nothing   # inside a test with the report off — no-op (invariant V)
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
    push!(c.content, :table => length(c.tables))
    return tbl
end

"""
Register one PASS/FAIL check — a `@expect` (the atom of a `@benchmark` test set). The first two macro
arguments (id, label) are the check id (a `Symbol`, or a `String` coerced to one) and a human label;
then `got=` (required) is the computed value, `want=` (default `0.0`) the reference, `tol=` (required)
the tolerance, and `kind=` (default `:auto`) selects the deviation: `:rel` (relative) when there is a
nonzero reference, `:abs` (a residual against `want=0`). `@expect "E1" "energy density e" got=e want=e_ref tol=1e-2`.

The tolerance is relative by default with a nonzero `want`, absolute for a residual (`want=0`);
`kind=:rel` with `want=0` is an error, and a non-finite `got`/`want` or a non-positive `tol` is an
error — a check is a trust gate, so an ill-posed assertion fails loudly rather than mis-reporting.

`@expect` is **manuscript** vocabulary (a `@page`/`@benchmark`/`@section`). Inside a **test suite** the
assertion is `@test` — Pinax recovers its `got`/`want`/`tol` and shows the same margin — so `@expect`
used directly in a `@testset` is an error, not a silently-unenforced check (issue #69 F).
"""
macro expect(args...)
    length(args) >= 2 || error("@expect needs an id and a \"label\" (plus kwargs)")
    id, label = args[1], args[2]
    return _call(
        :_push_check!,
        (),
        vcat(Expr(:kw, :id, esc(id)), Expr(:kw, :label, esc(label)), _kwspecs(args[3:end])),
    )
end

function _push_check!(; id, label, got, want=0.0, tol, kind=:auto)
    # `@expect` is MANUSCRIPT vocabulary. Inside a test suite the assertion is `@test` — whose margin
    # the report already recovers and shows — so `@expect` used directly in a `@testset` is a mistake:
    # it records a check the test runner does not enforce, i.e. a GREEN run for a failing check when the
    # report is off (issue #69 F). Forbid it loudly (and keep the report's on/off state from ever
    # deciding the verdict, invariant IV). A manuscript built *inside* a test — an open `CTX` page /
    # section, as Pinax's own tests do — is real manuscript content, so `_ctx_container()` is non-nothing
    # there and this passes straight through.
    c = _ctx_container()
    if c === nothing
        _probe_test_container() === :none &&
            error("@expect $(id): outside of a @benchmark/@section/@page")
        error(
            "@expect $(id): `@expect` is a manuscript check, not a suite assertion — inside a " *
            "`@testset` write `@test` (Pinax already recovers and shows its margin in the report).",
        )
    end
    g = Float64(got)
    w = Float64(want)
    t = Float64(tol)
    # a check is a TRUST gate — refuse an ill-posed assertion rather than benchmark a bad value.
    isfinite(g) || error(
        "@expect $(id): got= is not finite ($(g)) — fix the upstream computation; do not benchmark a non-finite value",
    )
    isfinite(w) || error("@expect $(id): want= is not finite ($(w))")
    t > 0 || error("@expect $(id): tol= must be positive (got $(t))")
    # rel DEFAULT when there's a nonzero reference; a residual (want=0) is abs.
    k = kind === :auto ? (abs(w) > 0 ? :rel : :abs) : kind
    k in (:rel, :abs) || error("@expect kind= must be :rel or :abs")
    k === :rel &&
        abs(w) == 0 &&
        error(
            "@expect $(id): kind=:rel needs a nonzero want= (got 0) — use kind=:abs for a residual against zero",
        )
    d = k === :rel ? abs(g - w) / abs(w) : abs(g - w)
    chk = Check(Symbol(id), string(label), g, w, d, t, k, d <= t)
    push!(c.checks, chk)
    push!(c.content, :check => length(c.checks))
    return chk
end

# The container's content (figures / tables / @raw panels / @expect checks) in declaration order, as (kind, item) pairs.
function _content_items(c)
    return [(
        k,
        if k === :figure
            c.figures[i]
        elseif k === :table
            c.tables[i]
        elseif k === :check
            c.checks[i]
        else
            c.panels[i]
        end,
    ) for (k, i) in c.content]
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
    c === :inert && return nothing   # inside a test with the report off — no-op (invariant V)
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
    c === :inert && return nothing   # inside a test with the report off — no-op (invariant V)
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
    c === :inert && return nothing   # inside a test with the report off — no-op (invariant V)
    c === nothing && error("@raw outside of a @section or @page")
    push!(c.panels, string(s))
    push!(c.content, :panel => length(c.panels))
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
    if pg === nothing
        _probe_test_container() === :none || return nothing   # inside a test, no @page → no-op
        error("@thumbnail outside of a @page")
    end
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
        $(_set_no_thumbnail!)()
    end
end
function _set_no_thumbnail!()
    pg = CTX.page
    if pg === nothing
        _probe_test_container() === :none || return nothing   # inside a test, no @page → no-op
        error("@no_thumbnail outside of a @page")
    end
    pg.no_thumbnail = true
    return nothing
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
