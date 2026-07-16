# testset.jl — the Test-FREE half of the `Test` bridge (the other half is ext/PinaxTestExt.jl).
#
# A test suite is normally a binary: green or red. But Pinax already has the pieces to say
# something much more useful — `@expect` records a `Check(got, want, delta, tol, pass)`, and a
# `status=:benchmark` page renders those as a colored pass/fail report (and emits
# `{verdict, passed, total, failed, checks:[…]}` into `agent.json`). All that was missing was
# the bridge FROM `Test`:
#
#     test file  (@testset "test_foo.jl")  →  @page (status=:benchmark)
#     @testset   (nested)                  →  @section  (recursively)
#     @test                                →  a Check
#
# THE POINT — a margin, not a verdict. For any `@test isapprox(got, want; rtol=…)` the real
# numbers are recovered, so the report shows `delta/tol`: how much room a test passed BY. A
# check sitting at 99% of its tolerance is one refactor away from red and looks identical to a
# rock-solid one in a green CI badge. Here they look nothing alike.
#
# WHY THE SPLIT. `Test` is a weakdep: Pinax is a rendering package, and `using Pinax` must not drag
# in Test (and with it Random/Logging/Serialization/InteractiveUtils) for the majority of users who
# never render a test suite. Everything here is Test-free — Expr parsing, the Check, the figure —
# so it is also directly testable without the extension loaded. Only the `AbstractTestSet` subtype
# and the `record`/`finish` machinery live in the extension.

"""
    testset_type() -> Type

The testset type [`@pinaxtestset`](@ref) binds: **`Test.DefaultTestSet` unless `PINAX_TEST_REPORT` is
set**, otherwise the `PinaxTestExt` type that renders the suite as a Pinax document.

Reach for this directly only when you need the type itself (a custom testset wrapper, a driver of
your own). The normal entry point is `@pinaxtestset`, which generates the binding for you — `@testset
T` insists that `T` be a bare identifier, which is exactly what a macro can produce and a caller
otherwise cannot get, since Julia forbids an extension from adding a name to its parent's namespace.
"""
function testset_type()
    ext = Base.get_extension(@__MODULE__, :PinaxTestExt)
    ext === nothing && error(
        "Pinax: the test bridge needs the Test stdlib loaded (`using Test`) — the testset type " *
        "lives in the PinaxTestExt extension.",
    )
    return ext._testset_type()
end

"""
    @pinaxtestset "MyPkg" [options…] begin … end

`@testset`, plus a rendered report when CI asks for one. The **only** change a suite ever needs:

    using Pinax, Test

    @pinaxtestset "MyPkg" begin
        for f in files
            @testset "\$f" begin include(f) end   # a test FILE       → @page (status = :benchmark)
        end                                       # a nested @testset → @section
    end                                           # each @test        → a Check

    # CI:
    PINAX_TEST_REPORT=1  PINAX_TEST_OUT=test-report   julia --project -e 'using Pkg; Pkg.test()'

With `PINAX_TEST_REPORT` unset this expands to a plain `@testset` on `Test.DefaultTestSet` — the
stock type, not a Pinax set that skips rendering — so a normal `Pkg.test()` behaves exactly as
before and switching the report on cannot regress a passing suite. Every argument is forwarded to
`@testset`, so existing options keep working.

Nested testsets inherit the parent's type from Julia, so the whole tree is captured with nothing to
annotate. Use [`@pinaxignore`](@ref) to drop a subtree from the document (it still runs, and still
fails the suite if it is red). A red suite always fails the process: a report must never turn a
failing suite green.

Why a macro rather than a name you could pass to `@testset` yourself: `@testset T` takes only a bare
identifier bound to a real `AbstractTestSet` subtype (`Test.parse_testset_args` rejects any other
expression, `Test._check_testset` any other value), and Julia forbids an extension from adding a name
to its parent's namespace — so Pinax cannot simply export the type. The macro generates the binding,
which is the one thing that *is* allowed to be a bare identifier: a gensym.
"""
macro pinaxtestset(args...)
    ts = gensym("PinaxTestSet")
    # `Test` is resolved in the CALLER's module — Pinax does not depend on Test, and anyone writing
    # `@pinaxtestset` necessarily has `using Test` already.
    testset = Expr(
        :macrocall, Expr(:., :Test, QuoteNode(Symbol("@testset"))), __source__, ts, args...
    )
    return esc(Expr(:block, Expr(:(=), ts, :($(testset_type)())), testset))
end

"Is the test report switched on? (`PINAX_TEST_REPORT` = 1 / true / yes / on, case-insensitive.)"
function report_enabled()
    return lowercase(get(ENV, "PINAX_TEST_REPORT", "")) in ("1", "true", "yes", "on")
end

"Where the test report is written (`PINAX_TEST_OUT`, default `test-report`) → `<out>_html` + `<out>_agent`."
report_out() = get(ENV, "PINAX_TEST_OUT", "test-report")

"""
    @pinaxignore

Drop the enclosing `@testset` — and everything under it — from the rendered document. The tests still
RUN and still count toward pass/fail; they simply do not become a page or a section. For the noise
you do not want in a report (a smoke check, an Aqua block, a slow fixture):

    @testset "Aqua tests" begin
        @pinaxignore
        Aqua.test_all(MyPkg)
    end

A no-op when the report is off, so it is safe to leave in the code permanently.
"""
macro pinaxignore()
    return :($(_ignore_current_testset!)())
end

"""
    _ignore_current_testset!()

Mark the innermost enclosing testset as excluded from the document. Declared with no methods on
purpose: the only method lives in `PinaxTestExt`, and it cannot be missing where it matters, since
`@pinaxignore` is only ever reachable from inside a `@testset` — which means `Test` is loaded, which
means the extension is too. (A fallback method HERE would be overwritten by the extension's, and
method overwriting during precompilation is an error.)
"""
function _ignore_current_testset! end

_looks_like_a_file(desc::AbstractString) = endswith(desc, ".jl")

_slug(s) = Symbol(replace(lowercase(strip(s)), r"[^a-z0-9]+" => "_"))

# ── recovering the NUMBERS out of a test's expression ────────────────
#
# `isapprox(got, want; rtol=…, atol=…)` / `got ≈ want` → (got, want, tol, kind), or nothing.
# The Expr arrives with its arguments already EVALUATED (that is what `Test` records), so these are
# the real numbers the assertion actually compared.
function _approx_numbers(e::Expr)
    e.head === :call || return nothing
    f = e.args[1]
    (f === :isapprox || f === :≈) || return nothing
    pos = Float64[]
    rtol = nothing
    atol = nothing
    for a in e.args[2:end]
        if a isa Expr && a.head === :parameters
            for kw in a.args
                kw isa Expr && kw.head === :kw || continue
                kw.args[1] === :rtol && (rtol = _tofloat(kw.args[2]))
                kw.args[1] === :atol && (atol = _tofloat(kw.args[2]))
            end
        elseif a isa Expr && a.head === :kw
            a.args[1] === :rtol && (rtol = _tofloat(a.args[2]))
            a.args[1] === :atol && (atol = _tofloat(a.args[2]))
        else
            v = _tofloat(a)
            v === nothing || push!(pos, v)
        end
    end
    length(pos) >= 2 || return nothing
    got, want = pos[1], pos[2]
    # isapprox is `|x-y| <= max(atol, rtol*max(|x|,|y|))`. A Check carries ONE kind, so report the
    # one that actually governs: relative when there is a nonzero reference, else absolute.
    if rtol !== nothing && rtol > 0 && abs(want) > 0
        return (got, want, rtol, :rel)
    elseif atol !== nothing && atol > 0
        return (got, want, atol, :abs)
    elseif rtol !== nothing && rtol > 0
        return (got, want, rtol, :rel)
    end
    return nothing
end
_approx_numbers(::Any) = nothing

_tofloat(x::Real) = Float64(x)
_tofloat(x::Any) = nothing

_margin(c::Check) = c.tol > 0 ? c.delta / c.tol : 0.0

# ── the checks ───────────────────────────────────────────────────────

# One Check per @test. A numeric `isapprox` keeps its real got/want/tol (that is the whole point);
# anything else is encoded as a 1/0 indicator so that EVERY assertion still shows up in the
# machine-readable verdict rather than silently vanishing.
#
# `passed` is the TEST RUNNER's verdict, never recomputed from delta<=tol: isapprox combines atol and
# rtol in a way a single-kind Check cannot reproduce, and a report that disagrees with the test
# runner is worse than no report.
function _check_from(expr, label::AbstractString, passed::Bool, i::Int)
    id = Symbol("t", i)
    nums = _approx_numbers(expr)
    if nums === nothing
        got = passed ? 1.0 : 0.0
        return Check(id, String(label), got, 1.0, abs(got - 1.0), 0.5, :abs, passed)
    end
    got, want, tol, kind = nums
    delta = kind === :rel ? abs(got - want) / abs(want) : abs(got - want)
    return Check(id, String(label), got, want, delta, tol, kind, passed)
end

# ── the tree DTO (Test-free) ─────────────────────────────────────────
#
# `TestNode` is the **serialisation DTO** for the shard dump — the testset tree with `Test` and its
# closures factored OUT. It is NOT a second document model: the live tree is `PinaxTestSet` objects
# (in the extension) holding Pinax's own structs directly, and the fold below is duck-typed so it
# walks EITHER a live `PinaxTestSet` (direct render) or a merged `TestNode` (a sharded run). A
# `TestNode` carries the same container fields as a `PinaxTestSet` (figures/tables/panels/desc +
# content order) so that one fold serves both; the TOML dump currently persists checks + structure
# only (a `Figure.gen` is a closure and cannot cross the process boundary — carrying user figures
# through a shard is the E/L follow-up), so a loaded `TestNode` has those extra vectors empty.
#
# This is what makes sharded CI work. Eight shards each run a disjoint set of test FILES; instead of
# eight disconnected galleries, each shard dumps its tree (no rendering at all) and one later job
# merges the trees and renders the single coherent gallery: one page per test file.
struct TestNode
    description::String
    elapsed::Float64
    ignore::Bool                # @pinaxignore: ran and counted, but kept out of the document
    checks::Vector{Check}       # one per Pass / Fail / Error recorded directly here
    nbroken::Int                # @test_broken / skipped: counted, never a Check — see below
    nerror::Int                 # how many of the failing checks were ERRORS rather than plain fails
    children::Vector{TestNode}
    # container payload — same shape a `PinaxTestSet` captures live (the closure-free DTO half).
    figures::Vector{Figure}
    tables::Vector{Table}
    panels::Vector{String}
    desc::Union{Desc,Nothing}
    content::Vector{Pair{Symbol,Int}}   # declaration order of figures/tables/panels/checks
end

function TestNode(
    description::AbstractString;
    elapsed::Real=NaN,
    ignore::Bool=false,
    checks::Vector{Check}=Check[],
    nbroken::Integer=0,
    nerror::Integer=0,
    children::Vector{TestNode}=TestNode[],
    figures::Vector{Figure}=Figure[],
    tables::Vector{Table}=Table[],
    panels::Vector{String}=String[],
    desc::Union{Desc,Nothing}=nothing,
    content::Vector{Pair{Symbol,Int}}=Pair{Symbol,Int}[],
)
    return TestNode(
        String(description),
        Float64(elapsed),
        ignore,
        checks,
        nbroken,
        nerror,
        children,
        figures,
        tables,
        panels,
        desc,
        content,
    )
end

# A broken/skipped test is deliberately NOT a Check. It has no verdict to show: it did not pass, but
# it did not fail either, and encoding it as `pass=false` would paint the page red and flip the
# benchmark verdict to FAIL — for a test the runner is perfectly happy about.
_ntests(n) = length(n.checks) + n.nbroken + sum(_ntests, n.children; init=0)
_nerror(n) = n.nerror + sum(_nerror, n.children; init=0)
_nbroken(n) = n.nbroken + sum(_nbroken, n.children; init=0)
function _nfail(n)
    here = count(c -> !c.pass, n.checks) - n.nerror
    return here + sum(_nfail, n.children; init=0)
end

function _summary_line(n)
    total, f, e, b = _ntests(n), _nfail(n), _nerror(n), _nbroken(n)
    t = isnan(n.elapsed) ? "" : " · $(round(n.elapsed; digits=2))s"
    return "$(total - f - e - b)/$(total) passed" *
           (f > 0 ? " · $(f) failed" : "") *
           (e > 0 ? " · $(e) errored" : "") *
           (b > 0 ? " · $(b) broken" : "") *
           t
end

# The largest delta/tol among this subtree's NUMERIC checks — how close the file came to red.
function _worst_margin(n)
    worst = nothing
    for c in n.checks
        c.kind === :abs && c.tol == 0.5 && c.want == 1.0 && continue   # the 1/0 indicator, not a margin
        m = _margin(c)
        worst = worst === nothing ? m : max(worst, m)
    end
    for ch in n.children
        m = _worst_margin(ch)
        m === nothing || (worst = worst === nothing ? m : max(worst, m))
    end
    return worst
end

# ── the margin profile figure ────────────────────────────────────────
#
# A hand-written SVG, on purpose. `@figure`'s `gen` may return a FILE PATH (backends.jl) — a
# first-class case needing no plotting extension — so a test report draws itself without dragging
# Plots/Makie into every package's test env, which is the only reason this bridge is free to adopt.
#
# The bar is `delta/tol` (how much of its tolerance budget the check spent), clipped at 1.2 with the
# real value always printed. The line at 1.0 IS the pass/fail boundary: a bar that nearly touches it
# is a green test that is one refactor from red — the thing a CI badge cannot tell you.
const _MARGIN_W = 620
const _BAR_H = 18

function _margin_svg(checks::Vector{Check}, path::AbstractString)
    n = length(checks)
    left, top = 250, 26
    h = top + n * _BAR_H + 34
    axis_w = _MARGIN_W - left - 60
    x_of(m) = left + axis_w * min(m, 1.2) / 1.2
    io = IOBuffer()
    print(
        io,
        """<svg xmlns="http://www.w3.org/2000/svg" width="$(_MARGIN_W)" height="$(h)" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="11">
        <text x="8" y="14" font-size="12" fill="#444">tolerance budget spent (delta / tol)</text>
        """,
    )
    for (i, c) in enumerate(checks)
        m = _margin(c)
        y = top + (i - 1) * _BAR_H
        fill = if !c.pass
            "#d9534f"
        elseif m > 0.75
            "#e8a33d"
        else
            "#4c9f70"
        end
        lab = length(c.label) > 34 ? c.label[1:31] * "…" : c.label
        w = max(x_of(m) - left, 1.0)
        print(
            io,
            """<text x="$(left - 8)" y="$(y + 13)" text-anchor="end" fill="#333">$(_xml(lab))</text>
            <rect x="$(left)" y="$(y + 3)" width="$(round(w; digits=1))" height="$(_BAR_H - 7)" fill="$(fill)" rx="2"/>
            <text x="$(round(x_of(m) + 6; digits=1))" y="$(y + 13)" fill="#666">$(_fmt_margin(m))</text>
            """,
        )
    end
    # the pass/fail boundary
    xt = x_of(1.0)
    print(
        io,
        """<line x1="$(xt)" y1="$(top - 4)" x2="$(xt)" y2="$(top + n * _BAR_H + 2)" stroke="#d9534f" stroke-width="1" stroke-dasharray="3,2"/>
        <text x="$(xt + 3)" y="$(top + n * _BAR_H + 14)" fill="#d9534f">tol</text>
        <line x1="$(left)" y1="$(top - 4)" x2="$(left)" y2="$(top + n * _BAR_H + 2)" stroke="#bbb" stroke-width="1"/>
        </svg>
        """,
    )
    write(path, take!(io))
    return path
end

_xml(s) = replace(String(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
_fmt_margin(m) = m >= 10 ? "$(round(Int, m))×" : "$(round(m; digits=2))"

# The figure for one page's checks: how far each assertion sat from its own tolerance.
function _push_margin_figure!(page_id::Symbol, checks::Vector{Check})
    isempty(checks) && return nothing
    # `data=` must be plot-data (`series=[(; label, x, y)]`) — it is the figure's TEXT channel for the
    # agent backend. The per-check got/want/tol already ride along in the benchmark `checks` JSON, so
    # the series carries only what the picture itself shows: the margin of check i.
    xs = collect(1:length(checks))
    data = (;
        xlabel="check #",
        ylabel="delta / tol",
        series=[
            (; label="margin", x=xs, y=[_margin(c) for c in checks]),
            (; label="pass/fail boundary", x=xs, y=fill(1.0, length(xs))),
        ],
    )
    _push_figure!(;
        gen=() -> _margin_svg(checks, tempname() * ".svg"),
        code="",
        caption="Tolerance budget spent by each check. The dashed line is the pass/fail " *
                "boundary — a bar close to it passed, but barely.",
        id=Symbol(page_id, :_margins),
        data=data,
    )
    return nothing
end

# ── the document ─────────────────────────────────────────────────────

# `acc` collects every Check pushed anywhere in this subtree, in emission order. A page's checks are
# spread across its @sections (that is the whole nesting), so the page-level margin figure cannot be
# rebuilt from the page container alone — it has to be accumulated on the way down.
#
# `n` is duck-typed: a live `PinaxTestSet` (direct render — carries user `@figure`/`@desc`/… too) or
# a merged `TestNode` (a sharded run — checks + structure only). Same fold either way.
function _emit_node!(n, counter::Ref{Int}, page_when::Function, acc::Vector{Check}=Check[])
    _emit_own_content!(n, counter, acc)
    # Nested testsets become pages (a file) or sections (a group). @pinaxignore'd ones are skipped
    # HERE only — never in the counts, so an ignored subtree still fails the suite if it is red.
    for ch in n.children
        ch.ignore && continue
        if page_when(ch.description)
            pid = _slug(ch.description)
            _enter_page!(pid, ch.description; status=:benchmark, summary=_summary_line(ch))
            try
                page_checks = Check[]
                _emit_node!(ch, counter, page_when, page_checks)
                append!(acc, page_checks)
                # Back at page level (every section closed), so the figure lands on the page.
                _push_margin_figure!(pid, page_checks)
            finally
                _exit_page!()
            end
        else
            _enter_section!(
                _slug(ch.description), ch.description; summary=_summary_line(ch)
            )
            try
                _emit_node!(ch, counter, page_when, acc)
            finally
                _exit_section!()
            end
        end
    end
    return acc
end

# Move THIS node's own captured content (desc + figures/tables/panels + checks) into the CTX
# container just entered, preserving declaration order. A live `PinaxTestSet` carries the full
# interleaved `content`; a merged `TestNode` carries checks with empty `content`, so fall back to the
# checks in that case. Uses `_ctx_container()` (never the probe) — the fold builds the doc in `CTX`.
function _emit_own_content!(n, counter::Ref{Int}, acc::Vector{Check})
    c = _ctx_container()
    c === nothing && return acc
    n.desc === nothing || (c.desc = n.desc)
    if isempty(n.content) && !isempty(n.checks)
        for chk in n.checks
            _place_check!(c, chk, counter, acc)
        end
        return acc
    end
    for (kind, i) in n.content
        if kind === :check
            _place_check!(c, n.checks[i], counter, acc)
        elseif kind === :figure
            push!(c.figures, n.figures[i])
            push!(c.content, :figure => length(c.figures))
        elseif kind === :table
            push!(c.tables, n.tables[i])
            push!(c.content, :table => length(c.tables))
        elseif kind === :panel
            push!(c.panels, n.panels[i])
            push!(c.content, :panel => length(c.panels))
        end
    end
    return acc
end

# Assign the render-time id (t1, t2, … so a merge renumbers cleanly rather than N shards colliding at
# t1) and place the check into the current container + content order + margin accumulator.
function _place_check!(c, chk::Check, counter::Ref{Int}, acc::Vector{Check})
    counter[] += 1
    chk.id = Symbol("t", counter[])
    push!(c.checks, chk)
    push!(c.content, :check => length(c.checks))
    push!(acc, chk)
    return chk
end

function _collect_rows!(rows::Vector{NamedTuple}, n, page_when::Function)
    for ch in n.children
        ch.ignore && continue
        if page_when(ch.description)
            m = _worst_margin(ch)
            push!(
                rows,
                (
                    file=ch.description,
                    tests=_ntests(ch),
                    passed=_ntests(ch) - _nfail(ch) - _nerror(ch) - _nbroken(ch),
                    failed=_nfail(ch),
                    errored=_nerror(ch),
                    seconds=isnan(ch.elapsed) ? missing : round(ch.elapsed; digits=2),
                    worst_margin=m === nothing ? missing : round(m; digits=3),
                ),
            )
        else
            _collect_rows!(rows, ch, page_when)
        end
    end
    return rows
end

"""
    render_test_report(root::TestNode; out, title="Test report", page_when=…) -> (; gallery, agent)
    render_test_report(dumps::AbstractVector{<:AbstractString}; out, …)       -> (; gallery, agent)

Render a testset tree as a Pinax document: an overview page (one row per test file, ranked by
`worst margin`), then one `status=:benchmark` page per file whose sections mirror the nested
testsets, each with its margin figure.

Given a list of TOML dumps (see [`dump_test_report`](@ref)) their trees are **merged** under one root
first — which is how a sharded CI run becomes a single coherent gallery instead of N disconnected
ones.

Writes `<out>_html` (the human gallery) and `<out>_agent` (`agent.json`), following the same
convention as [`report`](@ref).
"""
function render_test_report(
    root;
    out::AbstractString,
    title::AbstractString="Test report",
    page_when::Function=_looks_like_a_file,
)
    reset!(; title=title)
    counter = Ref(0)
    # An overview page first: one row per file, so the whole suite is one glance — and the SAME rows
    # land in agent.json as data, so an LLM reads the suite without scraping a log.
    _enter_page!(:overview, title; layout=:wide, summary=_summary_line(root))
    try
        rows = NamedTuple[]
        _collect_rows!(rows, root, page_when)
        isempty(rows) || _push_table!(;
            data=rows,
            code="",
            caption="Per-file result profile. `worst margin` is the largest `delta/tol` seen in " *
                    "that file: 1.0 means a check landed exactly on its tolerance.",
            id=:per_file,
        )
    finally
        _exit_page!()
    end
    _emit_node!(root, counter, page_when)
    doc = current_document()
    gallery = render(doc; out="$(out)_html", theme=:gallery)
    agent = render(doc; out="$(out)_agent", theme=:agent)
    return (; gallery, agent)
end

function render_test_report(
    dumps::AbstractVector{<:AbstractString}; title::AbstractString="Test report", kwargs...
)
    isempty(dumps) && error("Pinax.render_test_report: no dumps given.")
    roots = [load_test_dump(d) for d in dumps]
    # The shards partition the test FILES, so their children are disjoint and concatenating them is
    # the whole merge. Elapsed time is summed, not maxed: it is CPU time spent, not wall clock.
    merged = TestNode(
        title;
        elapsed=sum(r -> isnan(r.elapsed) ? 0.0 : r.elapsed, roots; init=0.0),
        children=reduce(vcat, (r.children for r in roots)),
        checks=reduce(vcat, (r.checks for r in roots)),
        nbroken=sum(r -> r.nbroken, roots; init=0),
        nerror=sum(r -> r.nerror, roots; init=0),
    )
    return render_test_report(merged; title=title, kwargs...)
end

# ── the dump (how a sharded run gets merged) ─────────────────────────
#
# TOML, because Pinax already depends on it and it round-trips Float64 exactly. A shard writes its
# tree and renders NOTHING; one later job (the docs build) merges every shard's tree and renders once.

"""
    dump_test_report(root::TestNode, path) -> path

Write a testset tree to `path` as TOML, to be merged and rendered later by
[`render_test_report`](@ref). This is what a CI shard emits instead of rendering its own partial
gallery.
"""
function dump_test_report(root, path::AbstractString)
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    _warn_if_undumpable(root)
    open(path, "w") do io
        return TOML.print(io, Dict("root" => _node_to_dict(root)))
    end
    return path
end

# A shard dump carries checks + structure only; a `@figure`/`@table`/`@raw` written inside a test is a
# closure / raw HTML that cannot cross the process boundary yet (the E/L follow-up). Warn loudly
# rather than drop it silently — a sharded report would otherwise be missing content with no trace.
function _warn_if_undumpable(n)
    if !isempty(n.figures) || !isempty(n.tables) || !isempty(n.panels)
        @warn "Pinax: @figure/@table/@raw inside a test is not carried through a shard dump yet — \
               it appears in a direct (non-sharded) render only." testset = n.description maxlog =
            1
    end
    foreach(_warn_if_undumpable, n.children)
    return nothing
end

"""
    load_test_dump(path) -> TestNode

Read back a tree written by [`dump_test_report`](@ref).
"""
load_test_dump(path::AbstractString) = _dict_to_node(TOML.parsefile(path)["root"])

function _node_to_dict(n)
    d = Dict{String,Any}(
        "description" => n.description,
        "ignore" => n.ignore,
        "nbroken" => n.nbroken,
        "nerror" => n.nerror,
    )
    # TOML has no NaN, so an unmeasured elapsed is simply absent.
    isnan(n.elapsed) || (d["elapsed"] = n.elapsed)
    isempty(n.checks) || (d["check"] = [_check_to_dict(c) for c in n.checks])
    isempty(n.children) || (d["child"] = [_node_to_dict(c) for c in n.children])
    return d
end

# `id` is deliberately NOT dumped: it is assigned at render time (t1, t2, …) so that merging several
# shards produces one clean numbering rather than N colliding ones.
function _check_to_dict(c::Check)
    return Dict{String,Any}(
        "label" => c.label,
        "got" => c.got,
        "want" => c.want,
        "delta" => c.delta,
        "tol" => c.tol,
        "kind" => String(c.kind),
        "pass" => c.pass,
    )
end

function _dict_to_node(d::AbstractDict)
    return TestNode(
        d["description"];
        elapsed=get(d, "elapsed", NaN),
        ignore=get(d, "ignore", false),
        nbroken=get(d, "nbroken", 0),
        nerror=get(d, "nerror", 0),
        checks=Check[_dict_to_check(c) for c in get(d, "check", Any[])],
        children=TestNode[_dict_to_node(c) for c in get(d, "child", Any[])],
    )
end

function _dict_to_check(d::AbstractDict)
    return Check(
        :t0,                        # renumbered on render
        d["label"],
        Float64(d["got"]),
        Float64(d["want"]),
        Float64(d["delta"]),
        Float64(d["tol"]),
        Symbol(d["kind"]),
        d["pass"],
    )
end

"Where a shard writes its tree instead of rendering (`PINAX_TEST_DUMP`); empty = render directly."
report_dump() = get(ENV, "PINAX_TEST_DUMP", "")
