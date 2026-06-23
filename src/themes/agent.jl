# themes/agent.jl — the agent / MCP backend (notes 11). Emits the document as STRUCTURED DATA for
# LLM consumption + data verification, not human HTML. The SAME document renders to :gallery (human)
# or :agent (machine) by switching the theme — the backend abstraction's real stress test, since the
# output here is JSON/text, not a "document".
#
# Per figure it carries the verification substrate so an agent can reconcile a claim against evidence
# ("data reconciliation"): the deferred CODE that produced it, the PARAMS / DataKey it is bound to,
# the rendered ASSET path (for vision models), the human CAPTION/claim, and the id-keyed COMMENT
# thread. Output: `agent.json` (machine / MCP-resource-shaped, every unit id-addressable) and
# `agent.md` (token-lean read view to paste to an LLM).

"""
Abstract base for the agent / MCP backend: its `emit_*` methods are defined on `AgentBase`, so a
custom theme `struct MyAgent <: AgentBase end` inherits the serializer and overrides only the dispatch
points it wants (e.g. `emit_figure(::MyAgent, …)` to add a field to the JSON).
"""
abstract type AgentBase <: Theme end

"Agent / MCP backend — emit the document as structured data (agent.json + agent.md)."
struct AgentTheme <: AgentBase end

output_format(::AgentBase) = :agent
figure_formats(::AgentBase) = Symbol[:svg, :table]   # svg (vision) + a CSV of the plotted data (text
# view for LLM reconciliation); pre-made file paths copy as-is and produce no table.
figure_as_table(::AgentBase) = true   # an LLM reads a figure's data as a table, not its pixels (Phase B)

# ---------- JSON emit (the machine / MCP substrate) ----------

# Per-render agent state, threaded through the per-node contract methods on `AgentBase`
# (emit_document/page/section/figure), serializing to JSON instead of HTML. `ctx` is left UNTYPED on
# those methods on purpose — annotating it `::AgentCtx` can re-introduce dispatch ambiguity with
# variants. Same override *mechanism* as the gallery, not the same node set: the agent has no
# emit_text/emit_comments — a figure's comments are embedded inline in its JSON object.
struct AgentCtx
    io::IOBuffer
    outdir::String
    comments::Dict{Symbol,Vector{Comment}}
    cache::RenderCache
    rdiag::Vector{DiagEntry}
end

# A JSON scalar for a param/cell value: numbers/bools stay native (a tool reads 16, not "16");
# missing/nothing map to JSON null; NaN/Inf are not valid JSON numbers so they're quoted; anything
# else is stringified.
_agent_jsonval(::Missing) = "null"
_agent_jsonval(::Nothing) = "null"
_agent_jsonval(v::Bool) = v ? "true" : "false"
_agent_jsonval(v::Integer) = string(v)
_agent_jsonval(v::Real) = isfinite(v) ? string(v) : _jsonstr(string(v))
_agent_jsonval(v::AbstractString) = _jsonstr(v)
_agent_jsonval(v) = _jsonstr(string(v))

# A figure's `params` binding as JSON: null, a structured {axis: value} object when the params object
# is introspectable (a NamedTuple/Dict, or a ParamIO.DataKey via the extension's `_params_describe`),
# else a string fallback (an opaque params value is still recorded for provenance).
function _agent_params_json(io, params)
    params === nothing && return print(io, "null")
    desc = _params_describe(params)
    desc === nothing && return print(io, _jsonstr(string(params)))
    print(io, "{")
    for (i, (k, v)) in enumerate(desc)
        i == 1 || print(io, ",")
        print(io, _jsonstr(k), ":", _agent_jsonval(v))
    end
    return print(io, "}")
end

# A figure's plotted data as an inline table preview (header + native-typed rows + total row count),
# parsed from its CSV — the "figure presented as a table" for an LLM (figure_as_table).
function _emit_figure_table(io, csvpath)
    t = _read_csv_table(csvpath)
    t === nothing && return print(io, "null")
    print(io, "{\"header\":[")
    for (i, h) in enumerate(t.header)
        i == 1 || print(io, ",")
        print(io, _jsonstr(h))
    end
    print(io, "],\"rows\":[")
    for (i, row) in enumerate(t.rows)
        i == 1 || print(io, ",")
        print(io, "[")
        for (j, cell) in enumerate(row)
            j == 1 || print(io, ",")
            print(io, _agent_jsonval(cell))
        end
        print(io, "]")
    end
    print(io, "],\"total\":", t.total, "}")
    return nothing
end

# One figure → its JSON object (verification substrate: caption/code/params/assets/data/table/comments).
function emit_figure(theme::AgentBase, fig, ctx)
    io = ctx.io
    print(
        io,
        "{\"id\":",
        _jsonstr(string(fig.id)),
        ",\"caption\":",
        _jsonstr(fig.caption),
        ",\"code\":",
        _jsonstr(fig.code),
        ",\"params\":",
    )
    _agent_params_json(io, fig.params)
    # split the rendered images from the plotted-data CSV (the `:table` pseudo-format): images are the
    # vision channel, `data` is the cheap text channel an LLM reads to reconcile a claim against numbers.
    print(io, ",\"assets\":[")
    datacsv = nothing
    imgs = String[]
    for a in fig.assets
        endswith(lowercase(a), ".csv") ? (datacsv = a) : push!(imgs, a)
    end
    for (i, a) in enumerate(imgs)
        i == 1 || print(io, ",")
        print(io, _jsonstr(replace(relpath(a, ctx.outdir), '\\' => '/')))
    end
    print(
        io,
        "],\"data\":",
        if datacsv === nothing
            "null"
        else
            _jsonstr(replace(relpath(datacsv, ctx.outdir), '\\' => '/'))
        end,
        ",\"table\":",
    )
    if figure_as_table(theme) && datacsv !== nothing
        _emit_figure_table(io, datacsv)
    else
        print(io, "null")
    end
    print(io, ",\"comments\":[")
    for (i, c) in enumerate(get(ctx.comments, Symbol(fig.anchor), Comment[]))
        i == 1 || print(io, ",")
        print(io, "{\"author\":", _jsonstr(c.author), ",\"text\":", _jsonstr(c.text), "}")
    end
    print(io, "]}")
    return nothing
end

# One @table -> a JSON object (header + native-typed rows). A table is already the LLM-native form.
function emit_table(::AgentBase, tbl, ctx)
    io = ctx.io
    print(
        io,
        "{\"id\":",
        _jsonstr(string(tbl.id)),
        ",\"caption\":",
        _jsonstr(tbl.caption),
        ",\"code\":",
        _jsonstr(tbl.code),
        ",\"header\":[",
    )
    for (i, h) in enumerate(tbl.header)
        i == 1 || print(io, ",")
        print(io, _jsonstr(h))
    end
    print(io, "],\"rows\":[")
    for (i, row) in enumerate(tbl.rows)
        i == 1 || print(io, ",")
        print(io, "[")
        for (j, cell) in enumerate(row)
            j == 1 || print(io, ",")
            print(io, _agent_jsonval(cell))
        end
        print(io, "]")
    end
    print(io, "]}")
    return nothing
end

function _agent_tables!(theme::AgentBase, tables, ctx)
    io = ctx.io
    print(io, "[")
    for (i, tbl) in enumerate(tables)
        i == 1 || print(io, ",")
        emit_table(theme, tbl, ctx)
    end
    print(io, "]")
    return nothing
end

# A page/section's content in declaration order as {kind,id} — lets a consumer reconstruct the
# interleave of figures and tables (the typed `figures`/`tables` arrays preserve within-type order).
function _agent_content!(c, ctx)
    io = ctx.io
    print(io, "[")
    started = false
    for (kind, item) in _content_items(c)
        kind === :panel && continue   # @raw HTML has no structured identity
        started && print(io, ",")
        started = true
        print(
            io,
            "{\"kind\":",
            _jsonstr(string(kind)),
            ",\"id\":",
            _jsonstr(string(item.id)),
            "}",
        )
    end
    print(io, "]")
    return nothing
end

# Materialize each figure (the asset is the verifiable artifact), then emit them as a JSON array.
# Inlined rather than a shared helper so formats come straight from `figure_formats(theme)` — keeps
# the materialize-all-then-emit-all two-phase shape and mirrors `_latex_emit_figs!`.
function _agent_figs!(theme::AgentBase, figs, assetdir, ctx)
    fmts = figure_formats(theme)
    for fig in figs
        try
            materialize!(fig, joinpath(assetdir, fig.anchor), fmts, ctx.cache)
        catch e
            e isa InterruptException && rethrow()
            push!(ctx.rdiag, DiagEntry(ERROR, fig.anchor, "materialize failed: $(e)"))
        end
    end
    io = ctx.io
    print(io, "[")
    for (i, fig) in enumerate(figs)
        i == 1 || print(io, ",")
        emit_figure(theme, fig, ctx)
    end
    print(io, "]")
    return nothing
end

function emit_section(theme::AgentBase, sec, pg, ctx)
    io = ctx.io
    print(
        io,
        "{\"id\":",
        _jsonstr(string(sec.id)),
        ",\"title\":",
        _jsonstr(sec.title),
        ",\"desc\":",
        sec.desc === nothing ? "null" : _jsonstr(sec.desc.source),
        ",\"figures\":",
    )
    _agent_figs!(
        theme,
        sec.figures,
        joinpath(ctx.outdir, "assets", "figures", pg.anchor, sec.anchor),
        ctx,
    )
    print(io, ",\"tables\":")
    _agent_tables!(theme, sec.tables, ctx)
    print(io, ",\"content\":")
    _agent_content!(sec, ctx)
    print(io, "}")
    return nothing
end

function emit_page(theme::AgentBase, pg, ctx)
    io = ctx.io
    print(
        io,
        "{\"id\":",
        _jsonstr(string(pg.id)),
        ",\"title\":",
        _jsonstr(pg.title),
        ",\"part\":",
        pg.part === nothing ? "null" : _jsonstr(string(pg.part)),
        ",\"summary\":",
        pg.summary === nothing ? "null" : _jsonstr(pg.summary),
        ",\"desc\":",
        pg.desc === nothing ? "null" : _jsonstr(pg.desc.source),
        ",\"figures\":",
    )
    _agent_figs!(
        theme, pg.figures, joinpath(ctx.outdir, "assets", "figures", pg.anchor), ctx
    )
    print(io, ",\"tables\":")
    _agent_tables!(theme, pg.tables, ctx)
    print(io, ",\"content\":")
    _agent_content!(pg, ctx)
    print(io, ",\"sections\":[")
    for (j, sec) in enumerate(pg.sections)
        j == 1 || print(io, ",")
        emit_section(theme, sec, pg, ctx)
    end
    print(io, "]}")
    return nothing
end

# Build the whole agent.json (title + parts + pages, the latter via the per-node contract).
function _agent_json(theme::AgentBase, doc::Document, ctx)
    io = ctx.io
    print(io, "{\"title\":", _jsonstr(doc.meta.title), ",\"parts\":[")
    for (i, (pid, ptitle)) in enumerate(doc.parts)
        i == 1 || print(io, ",")
        d = get(doc.part_descs, pid, nothing)
        print(
            io,
            "{\"id\":",
            _jsonstr(string(pid)),
            ",\"title\":",
            _jsonstr(ptitle),
            ",\"desc\":",
            d === nothing ? "null" : _jsonstr(d.source),
            "}",
        )
    end
    print(io, "],\"pages\":[")
    for (i, pg) in enumerate(doc.pages)
        i == 1 || print(io, ",")
        emit_page(theme, pg, ctx)
    end
    print(io, "]}")
    return String(take!(io))
end

# ---------- token-lean Markdown companion (the "paste to an LLM" view) ----------

# Compact one-line param view for agent.md: "system.N=16, system.g=0.5" (structured) or a repr.
function _params_inline(params)
    desc = _params_describe(params)
    desc === nothing && return string(params)
    return join(("$k=$v" for (k, v) in desc), ", ")
end

# Inline a figure's data as a markdown-table preview (figure_as_table), parsed from its CSV asset.
function _agent_md_data_table(io, csvpath)
    t = _read_csv_table(csvpath)
    t === nothing && return nothing
    println(io)
    println(io, "| ", join(t.header, " | "), " |")
    println(io, "|", repeat(" --- |", length(t.header)))
    for row in t.rows
        println(io, "| ", join((_cellstr(c) for c in row), " | "), " |")
    end
    length(t.rows) < t.total && println(
        io, "_(", length(t.rows), " of ", t.total, " rows; full data in the CSV asset)_"
    )
    return nothing
end

function _agent_md_fig(io, fig, outdir, comments, as_table)
    println(io, "- [fig: ", fig.id, "] ", fig.caption)
    isempty(fig.code) || println(io, "  - code: `", fig.code, "`")
    fig.params === nothing || println(io, "  - data: ", _params_inline(fig.params))
    imgs = filter(a -> !endswith(lowercase(a), ".csv"), fig.assets)
    isempty(imgs) ||
        println(io, "  - asset: ", replace(relpath(imgs[1], outdir), '\\' => '/'))
    csv = nothing
    for a in fig.assets
        endswith(lowercase(a), ".csv") && (csv = a)
    end
    if csv !== nothing
        if as_table
            _agent_md_data_table(io, csv)   # present the figure AS its data table
        else
            println(io, "  - data table: ", replace(relpath(csv, outdir), '\\' => '/'))
        end
    end
    for c in get(comments, Symbol(fig.anchor), Comment[])
        println(io, "  - note (", c.author, "): ", c.text)
    end
    return nothing
end

# A @table as a markdown table (the LLM read view).
function _agent_md_table(io, tbl)
    println(io)
    isempty(tbl.caption) || println(io, "_", tbl.caption, "_  [table: ", tbl.id, "]")
    if !isempty(tbl.header)
        println(io, "| ", join(tbl.header, " | "), " |")
        println(io, "|", repeat(" --- |", length(tbl.header)))
    end
    for row in tbl.rows
        println(io, "| ", join((_cellstr(c) for c in row), " | "), " |")
    end
    return nothing
end

# A container's figures + tables in declaration order (@raw panels are HTML, skipped in the md view).
function _agent_md_content(io, c, outdir, comments, as_table)
    for (kind, item) in _content_items(c)
        if kind === :figure
            _agent_md_fig(io, item, outdir, comments, as_table)
        elseif kind === :table
            _agent_md_table(io, item)
        end
    end
    return nothing
end

function _agent_markdown(doc::Document, outdir, comments, as_table)
    io = IOBuffer()
    isempty(doc.meta.title) || println(io, "# ", doc.meta.title)
    curpart = :__start__
    for pg in doc.pages
        if pg.part !== curpart
            curpart = pg.part
            if pg.part !== nothing
                k = findfirst(p -> first(p) === pg.part, doc.parts)
                println(io, "\n## ", k === nothing ? string(pg.part) : last(doc.parts[k]))
                d = get(doc.part_descs, pg.part, nothing)
                d === nothing || println(io, d.source)
            end
        end
        println(io, "\n### ", pg.title, "  [id: ", pg.id, "]")
        pg.summary === nothing || println(io, "_", pg.summary, "_")
        pg.desc === nothing || println(io, pg.desc.source)
        _agent_md_content(io, pg, outdir, comments, as_table)
        for sec in pg.sections
            println(io, "\n#### ", sec.title, "  [id: ", sec.id, "]")
            sec.desc === nothing || println(io, sec.desc.source)
            _agent_md_content(io, sec, outdir, comments, as_table)
        end
    end
    return String(take!(io))
end

# ---------- emit ----------

function emit_document(
    theme::AgentBase,
    doc::Document,
    outdir::AbstractString,
    cache::RenderCache;
    comments_file::AbstractString=joinpath(outdir, "comments.toml"),
)
    comments, _bm = read_comments(comments_file)
    rdiag = DiagEntry[]
    mkpath(outdir)
    ctx = AgentCtx(IOBuffer(), String(outdir), comments, cache, rdiag)
    write(joinpath(outdir, "agent.json"), _agent_json(theme, doc, ctx))
    write(
        joinpath(outdir, "agent.md"),
        _agent_markdown(doc, outdir, comments, figure_as_table(theme)),
    )
    # materialize failures leave a figure's `assets` empty in the JSON (the agent sees the gap);
    # no separate diagnostics file is emitted for the machine view.
    return joinpath(outdir, "agent.json")
end

register_theme!(:agent, AgentTheme())
