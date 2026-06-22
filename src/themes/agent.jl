# themes/agent.jl — the agent / MCP backend (notes 11). Emits the document as STRUCTURED DATA for
# LLM consumption + data verification, not human HTML. The SAME document renders to :gallery (human)
# or :agent (machine) by switching the theme — the backend abstraction's real stress test, since the
# output here is JSON/text, not a "document".
#
# Per figure it carries the verification substrate so an agent can reconcile a claim against evidence
# ("data 照合"): the deferred CODE that produced it, the PARAMS / DataKey it is bound to (provenance),
# the rendered ASSET path (for vision models), the human CAPTION/claim, and the id-keyed COMMENT
# thread. Output: `agent.json` (machine / MCP-resource-shaped, every unit id-addressable) and
# `agent.md` (token-lean read view to paste to an LLM).

struct AgentTheme <: Theme end

output_format(::AgentTheme) = :agent
figure_formats(::AgentTheme) = Symbol[:svg]   # generated figures → svg; pre-made file paths copy as-is

# ---------- shared: materialize a unit's figures (assets are the verifiable artifact) ----------

function _agent_materialize!(figs, dir, fmts, cache, rdiag)
    for fig in figs
        try
            materialize!(fig, joinpath(dir, fig.anchor), fmts, cache)
        catch e
            e isa InterruptException && rethrow()
            push!(rdiag, DiagEntry(ERROR, fig.anchor, "materialize failed: $(e)"))
        end
    end
    return nothing
end

# ---------- JSON emit (the machine / MCP substrate) ----------

# Per-render agent state — the `ctx` for the contract methods (the agent theme emits JSON, not HTML).
# It implements the same per-node contract as the gallery (emit_page/section/figure), just serializing.
struct AgentCtx
    io::IOBuffer
    outdir::String
    comments::Dict{Symbol,Vector{Comment}}
    fmts::Vector{Symbol}
    cache::RenderCache
    rdiag::Vector{DiagEntry}
end

# One figure → its JSON object (the verification substrate: caption/code/params/assets/comments).
function emit_figure(::AgentTheme, fig, ctx::AgentCtx)
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
        fig.params === nothing ? "null" : _jsonstr(string(fig.params)),
        ",\"assets\":[",
    )
    for (i, a) in enumerate(fig.assets)
        i == 1 || print(io, ",")
        print(io, _jsonstr(replace(relpath(a, ctx.outdir), '\\' => '/')))
    end
    print(io, "],\"comments\":[")
    for (i, c) in enumerate(get(ctx.comments, Symbol(fig.anchor), Comment[]))
        i == 1 || print(io, ",")
        print(io, "{\"author\":", _jsonstr(c.author), ",\"text\":", _jsonstr(c.text), "}")
    end
    print(io, "]}")
    return nothing
end

# Materialize then emit a JSON array of figures.
function _agent_figs!(theme::AgentTheme, figs, assetdir, ctx::AgentCtx)
    _agent_materialize!(figs, assetdir, ctx.fmts, ctx.cache, ctx.rdiag)
    io = ctx.io
    print(io, "[")
    for (i, fig) in enumerate(figs)
        i == 1 || print(io, ",")
        emit_figure(theme, fig, ctx)
    end
    print(io, "]")
    return nothing
end

function emit_section(theme::AgentTheme, sec, pg, ctx::AgentCtx)
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
    print(io, "}")
    return nothing
end

function emit_page(theme::AgentTheme, pg, ctx::AgentCtx)
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
    print(io, ",\"sections\":[")
    for (j, sec) in enumerate(pg.sections)
        j == 1 || print(io, ",")
        emit_section(theme, sec, pg, ctx)
    end
    print(io, "]}")
    return nothing
end

# Build the whole agent.json (title + parts + pages, the latter via the per-node contract).
function _agent_json(theme::AgentTheme, doc::Document, ctx::AgentCtx)
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

function _agent_md_figs(io, figs, outdir, comments)
    for fig in figs
        println(io, "- [fig: ", fig.id, "] ", fig.caption)
        isempty(fig.code) || println(io, "  - code: `", fig.code, "`")
        fig.params === nothing || println(io, "  - data: ", string(fig.params))
        isempty(fig.assets) ||
            println(io, "  - asset: ", replace(relpath(fig.assets[1], outdir), '\\' => '/'))
        for c in get(comments, Symbol(fig.anchor), Comment[])
            println(io, "  - note (", c.author, "): ", c.text)
        end
    end
    return nothing
end

function _agent_markdown(doc::Document, outdir, comments)
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
        _agent_md_figs(io, pg.figures, outdir, comments)
        for sec in pg.sections
            println(io, "\n#### ", sec.title, "  [id: ", sec.id, "]")
            sec.desc === nothing || println(io, sec.desc.source)
            _agent_md_figs(io, sec.figures, outdir, comments)
        end
    end
    return String(take!(io))
end

# ---------- emit ----------

function emit_document(
    theme::AgentTheme,
    doc::Document,
    outdir::AbstractString,
    cache::RenderCache;
    comments_file::AbstractString=joinpath(outdir, "comments.toml"),
)
    comments, _bm = read_comments(comments_file)
    rdiag = DiagEntry[]
    mkpath(outdir)
    ctx = AgentCtx(
        IOBuffer(), String(outdir), comments, figure_formats(theme), cache, rdiag
    )
    write(joinpath(outdir, "agent.json"), _agent_json(theme, doc, ctx))
    write(joinpath(outdir, "agent.md"), _agent_markdown(doc, outdir, comments))
    # materialize failures leave a figure's `assets` empty in the JSON (the agent sees the gap);
    # no separate diagnostics file is emitted for the machine view.
    return joinpath(outdir, "agent.json")
end

register_theme!(:agent, AgentTheme())
