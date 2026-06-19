# document.jl — 文書モデル + 構造マクロ(notes 02)。
#
# render 3パスのうち pass 1(structure)を担う。マクロは doc tree(placeholder)を組むだけで、
# `@figure` の式は **eval せず** 遅延生成器 `gen` として保持する(materialize は pass 3)。

# ============================================================ 値型

"markdown + LaTeX の source(未レンダ; theme が描画)。"
struct Desc
    source::String
end

"参照先 figure を指す軽量ハンドル(thumbnail 等)。"
struct FigRef
    id::Symbol
end

"診断の重大度(notes 09)。"
@enum Severity ERROR WARNING INFO

"診断 1 件。item は紐づく page/section/figure の anchor。"
struct DiagEntry
    severity::Severity
    item::String
    message::String
end

"render 中に集めた error/warning(→ 診断ページ, notes 09)。"
struct Diagnostics
    entries::Vector{DiagEntry}
end
Diagnostics() = Diagnostics(DiagEntry[])

"文書設定(TeX の \\documentclass+preamble 相当)。"
mutable struct DocMeta
    title::String
    theme::Symbol
    base_url::String
    format::Vector{Symbol}        # [:svg, :pdf]
    bib_sources::Vector{String}
    debug::Bool
    index::Union{Symbol,Nothing}  # :toc|:cards|:rich 上書き(nothing=theme 既定)
    numbering::Symbol             # CSS counter スコープ :global|:page
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
    )
end

"図 1 枚(placeholder)。`gen` は遅延、`code` は変更検知用の式 source(notes 10)。"
mutable struct Figure
    id::Symbol
    anchor::String
    caption::String
    params::Any           # ParamIO.DataKey | Nothing — 血統 + cache 素
    gen::Function         # () -> plot(...)(structure では呼ばない)
    code::String          # @figure 式の source
    thumbnail::Bool       # thumbnail=true マーカー
    assets::Vector{String}
end

"節(図の束 + 説明)。"
mutable struct Section
    id::Symbol
    title::String
    anchor::String
    facet::Any                       # by= の param 軸(String|Tuple|Nothing)
    desc::Union{Desc,Nothing}
    summary::Union{String,Nothing}   # index :rich 用
    thumbnail::Union{FigRef,Nothing} # section 粒度の main figure
    layout::Union{Symbol,Nothing}    # :wide|:grid|:single(theme ヒント)
    figures::Vector{Figure}
end

"ページ(独立 HTML + 共有 nav)。"
mutable struct Page
    id::Symbol
    title::String
    anchor::String
    thumbnail::Union{FigRef,Nothing} # 明示 @thumbnail
    no_thumbnail::Bool
    sections::Vector{Section}
end

"暗黙の最上位(統括)。順序 = ツリー位置、番号は持たない(採番は theme)。"
mutable struct Document
    meta::DocMeta
    pages::Vector{Page}
    refs::Dict{Symbol,Any}        # label → node(resolve で埋める)
    bib::Dict{Symbol,Any}         # @cite 解決表(後で)
    diag::Diagnostics
    newcommands::Dict{String,String}
end
function Document(meta::DocMeta=DocMeta())
    return Document(
        meta,
        Page[],
        Dict{Symbol,Any}(),
        Dict{Symbol,Any}(),
        Diagnostics(),
        Dict{String,String}(),
    )
end

# ============================================================ 構築コンテキスト

"暗黙グローバル document の構築状態(current page/section)。"
mutable struct BuildContext
    document::Union{Document,Nothing}
    page::Union{Page,Nothing}
    section::Union{Section,Nothing}
end
const CTX = BuildContext(nothing, nothing, nothing)

current_document() = CTX.document
current_page() = CTX.page
current_section() = CTX.section

"暗黙 document をリセット(新規・空)。preamble の `@pinaxsetup` がこれを呼ぶ。"
function reset!(; kwargs...)
    kw = Dict{Symbol,Any}(kwargs)
    meta = DocMeta(;
        title=get(kw, :title, ""),
        theme=get(kw, :theme, :gallery),
        base_url=get(kw, :base_url, ""),
        format=get(kw, :format, Symbol[:svg, :pdf]),
        debug=get(kw, :debug, false),
        index=get(kw, :index, nothing),
        numbering=get(kw, :numbering, :global),
    )  # css/js/features は theme 層が解釈(structure 増分では無視)
    CTX.document = Document(meta)
    CTX.page = nothing
    CTX.section = nothing
    return CTX.document
end

_ensure_document!() = (CTX.document === nothing && reset!(); CTX.document)

"スコープ document を組む: `doc = document() do … end`(テスト隔離用)。"
function document(f)
    saved = (CTX.document, CTX.page, CTX.section)
    CTX.document = Document()
    CTX.page = nothing
    CTX.section = nothing
    local doc
    try
        f()
        doc = CTX.document        # f 内で @pinaxsetup が reset! しても拾えるよう f 後に取得
    finally
        CTX.document, CTX.page, CTX.section = saved
    end
    return doc
end

# ============================================================ ヘルパ

_anchor(id::Symbol) = string(id)   # v1: id をそのまま anchor(安定 id 前提)
_auto_fig_id(sec::Section) = Symbol(string(sec.id), "_fig", length(sec.figures) + 1)

function _diag!(sev::Severity, item, msg)
    doc = CTX.document
    doc === nothing || push!(doc.diag.entries, DiagEntry(sev, string(item), msg))
    return nothing
end

# key=val の Expr 群 → Expr(:kw,…)(値は esc)。マクロ内専用。
function _kwspecs(args)
    return Expr[
        if (a isa Expr && a.head === :(=))
            Expr(:kw, a.args[1], esc(a.args[2]))
        else
            error("expected key=value, got $(a)")
        end for a in args
    ]
end

# 関数呼び出し Expr を組む。kwspecs が空なら `;` を付けない(空 Expr(:parameters) は invalid syntax)。
function _call(f, posargs, kwspecs)
    return if isempty(kwspecs)
        Expr(:call, f, posargs...)
    else
        Expr(:call, f, Expr(:parameters, kwspecs...), posargs...)
    end
end

# ============================================================ preamble マクロ

"文書設定 + 暗黙 document のリセット。`@pinaxsetup theme=… index=… numbering=… debug=…`"
macro pinaxsetup(args...)
    return _call(:reset!, (), _kwspecs(args))
end

"診断モード。`@debug_mode true`"
macro debug_mode(x)
    return quote
        _ensure_document!().meta.debug = $(esc(x))
        nothing
    end
end

"`@cite` 解決元 .bib を宣言。`@bibliography \"refs/a.bib\" …`"
macro bibliography(paths...)
    ps = map(esc, paths)
    return quote
        append!(_ensure_document!().meta.bib_sources, String[$(ps...)])
        nothing
    end
end

"記法マクロ。`@newcommand \"\\E\" raw\"\\langle H\\rangle\"`"
macro newcommand(name, def)
    return quote
        _ensure_document!().newcommands[$(esc(name))] = $(esc(def))
        nothing
    end
end

# ============================================================ 構造マクロ

"ページ。`@page :id \"Title\" begin … end`"
macro page(id, title, body)
    return quote
        _enter_page!($(esc(id)), $(esc(title)))
        try
            $(esc(body))
        finally
            _exit_page!()
        end
        nothing
    end
end

function _enter_page!(id::Symbol, title)
    doc = _ensure_document!()
    pg = Page(id, string(title), _anchor(id), nothing, false, Section[])
    push!(doc.pages, pg)
    CTX.page = pg
    CTX.section = nothing
    return pg
end
_exit_page!() = (CTX.page=nothing; CTX.section=nothing)

"節。`@section :id \"Title\" [by=…] [summary=…] [layout=…] begin … end`"
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
    )
    push!(pg.sections, sec)
    CTX.section = sec
    return sec
end
_exit_section!() = (CTX.section = nothing)

"プロットを登録。式は **遅延**。`@figure expr [params=…] [caption=…] [id=…] [thumbnail=…]` / `@figure [kw] begin … end`"
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
        Expr(:kw, :code, string(expr)),
        _kwspecs(kws),
    )
    return _call(:_push_figure!, (), allk)
end

function _push_figure!(; gen, code, params=nothing, caption="", id=nothing, thumbnail=false)
    sec = CTX.section
    sec === nothing && error("@figure outside of a @section")
    fid = id === nothing ? _auto_fig_id(sec) : id
    fig = Figure(fid, _anchor(fid), string(caption), params, gen, code, thumbnail, String[])
    push!(sec.figures, fig)
    return fig
end

"直前の `@figure` に caption を付与(`\\caption` 相当)。`caption=` 併用時は後勝ち。"
macro caption(x)
    return quote
        _set_caption!($(esc(x)))
    end
end
function _set_caption!(s)
    sec = CTX.section
    if sec === nothing || isempty(sec.figures)
        _diag!(
            WARNING,
            sec === nothing ? "?" : sec.anchor,
            "@caption with no preceding @figure",
        )
    else
        sec.figures[end].caption = string(s)
    end
    return nothing
end

"節の説明(markdown + LaTeX source)。`@desc md\"…\"`"
macro desc(x)
    return quote
        _set_desc!($(esc(x)))
    end
end
function _set_desc!(s)
    sec = CTX.section
    sec === nothing && error("@desc outside of a @section")
    sec.desc = Desc(string(s))
    return nothing
end

"page の main figure を指定。`@thumbnail :figid`(既定は省略 = top 図, notes 02 resolve)。"
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

"この page は index に main figure を出さない。"
macro no_thumbnail()
    return quote
        pg = CTX.page
        pg === nothing && error("@no_thumbnail outside of a @page")
        pg.no_thumbnail = true
        nothing
    end
end

"raw 文字列(\$…\$ を温存)。`@desc md\"…\"` 等で使う。"
macro md_str(s)
    return s
end

# ============================================================ resolve(最小: thumbnail)

"page の main figure を解決: 明示 `@thumbnail` > `thumbnail=true` マーカー > top(先頭)図(notes 02)。"
function resolved_thumbnail(pg::Page)
    pg.no_thumbnail && return nothing
    pg.thumbnail === nothing || return pg.thumbnail
    for sec in pg.sections, f in sec.figures
        f.thumbnail && return FigRef(f.id)
    end
    for sec in pg.sections
        isempty(sec.figures) || return FigRef(sec.figures[1].id)
    end
    return nothing
end

# ============================================================ show(ergonomics)

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
