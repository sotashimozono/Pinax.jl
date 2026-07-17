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
    Pinax.test([runtests]; out="test-report", title="Test report", dump="") -> nothing

Run a test suite and render it as a Pinax document — the interface that outputs a testset directly.
There is **no Pinax-specific macro** in the suite: it stays plain `@testset` / `@test`. The only Pinax
touch is the call. Two forms:

  - `Pinax.test()` — test the *active package*. Delegates to an unmodified `Pkg.test`, passing a `-L`
    preamble that installs a capturing root before the suite runs (so its `@testset` tree is captured)
    and renders at exit. `Pkg.test` still does all the sandbox / dependency work; a bare `Pkg.test()`
    without this installs no root and produces no report.
  - `Pinax.test(runtests::AbstractString)` — render a specific test file in the current process (no
    sandbox): open a capturing root testset, `include` the file, render.

Each test *file* (a `.jl`-named `@testset`) becomes a `status = :benchmark` page, each nested
`@testset` a section, each `@test` a `Check` carrying its real `got`/`want`/`tol`. Writes
`<out>_html` + `<out>_agent`; with `dump` set, dumps the tree there instead (a sharded CI shard) for
[`render_test_report`](@ref) to merge later. A red suite still fails the process — the report never
changes the verdict. A suite may also draw (`@desc`/`@figure`/`@table`/…); that content is captured,
and is a no-op under a bare `Pkg.test()`.

The `test()` delegation is `Test`-free (only `Pkg`, a stdlib); the in-process `test(runtests)` form
lives in `PinaxTestExt` and needs `Test` loaded.
"""
function test(; out=report_out(), dump=report_dump(), title::AbstractString=report_title())
    # Delegate to an UNMODIFIED `Pkg.test`, injecting a `-L` preamble that installs a capturing root
    # before the suite's include (invariant V′). `Pkg.test` does all the sandbox/dependency work; we
    # add one flag and make `out` ABSOLUTE (the caller's dir) so the report survives sandbox teardown.
    Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
    preamble = joinpath(pkgdir(@__MODULE__), "src", "test_preamble.jl")
    withenv(
        "PINAX_TEST_OUT" => abspath(out),
        "PINAX_TEST_DUMP" => (isempty(dump) ? "" : abspath(dump)),
        "PINAX_TEST_TITLE" => String(title),
    ) do
        return Pkg.test(; julia_args=`-L $(preamble)`)
    end
    return nothing
end

"""
    _install_test_capture!()

Push a capturing root `PinaxTestSet` onto the (task-local) testset stack and register an `atexit` hook
that renders/dumps it and sets the exit code — the `Pkg.test`-delegation half of [`test`](@ref). The
`-L` preamble the delegating `Pinax.test()` hands to `Pkg.test` calls this; the method lives in
`PinaxTestExt` (needs `Test`).
"""
function _install_test_capture! end

"Where the test report is written (`PINAX_TEST_OUT`, default `test-report`) → `<out>_html` + `<out>_agent`."
report_out() = get(ENV, "PINAX_TEST_OUT", "test-report")

"Report title (`PINAX_TEST_TITLE`, default `Test report`) — the document title + overview heading."
report_title() = get(ENV, "PINAX_TEST_TITLE", "Test report")

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

# ── sweeps: an unnamed `@testset for` is a SAMPLE, not a section (issue #69 point C) ──
#
# Test's `testset_forloop` emits, for `@testset for χ in (8, 16)` written with NO description, one child
# testset per iteration whose description is the machine-generated canonical string `"χ = 8"` (and
# `"χ = 8, β = 0.1"` for a multi-variable `for χ in …, β in …`). We read the axis ONLY from that
# canonical string (invariant III) — never from a human-written description. When EVERY child of a
# level parses to a binding over the SAME variables, that level is a SWEEP, not a stack of sections: its
# checks are collected, keyed by test expression (the quantity), each tagged with its binding, and drawn
# as a convergence figure (got vs axis, want reference, tolerance band) and a margin figure (delta/tol
# vs axis) — one pair per quantity — instead of N near-identical repeated sections. The INNERMOST loop
# is the x-axis; the outer loops collapse into the series legend (C3: no facet grid, one composite key).
#
# Decisions for the open points in #69 C:
#   • C1 non-numeric axis (`for model in (:TFIM, :Heisenberg)`) → a CATEGORICAL x-axis (evenly-spaced
#     ticks labelled by the value string). Same figure, categorical ticks — not small multiples.
#   • C2 a binding that does not round-trip → a non-issue here: the axis key is ALWAYS the canonical
#     STRING Test already produced, never the live object, so nothing needs to serialize. No index
#     fallback is needed; the string label IS the stable key (and it dumps as-is for a sharded run).
#   • C3 three or more nested loops → innermost = x, ALL outer bindings join into ONE legend key.
#   • C4 a render-side `x_axis=` override is deferred: the code is the figure spec (innermost = x).
#
# The whole thing is Test-free and duck-typed over the same shape `_emit_node!` already walks, so a
# sharded run gets its sweeps too: a dump carries child descriptions + checks, and the fold rebuilds the
# convergence figure from the merged tree with no extra machinery.

const _SERIES_COLORS = [
    "#4c78a8", "#f58518", "#54a24b", "#e45756", "#72b7b2", "#b279a2", "#ff9da6", "#9d755d"
]

# Split on top-level commas only — a bound value may itself be a tuple `(1, 2)`, so track bracket depth.
function _split_top_commas(s::AbstractString)
    segs = String[]
    depth = 0
    start = firstindex(s)
    for (i, ch) in pairs(s)
        if ch in ('(', '[', '{')
            depth += 1
        elseif ch in (')', ']', '}')
            depth = max(depth - 1, 0)
        elseif ch == ',' && depth == 0
            push!(segs, s[start:prevind(s, i)])
            start = nextind(s, i)
        end
    end
    push!(segs, s[start:end])
    return segs
end

# Parse Test's canonical forloop description into `[var => value-string, …]`, or `nothing` if it is not
# canonical. Each top-level segment must be `<identifier> = <value>` (an identifier LHS is exactly what
# a loop variable produces); anything else — a human sentence, a name with no `=` — does not fold.
function _parse_binding(desc::AbstractString)
    out = Pair{Symbol,String}[]
    for seg in _split_top_commas(desc)
        eq = findfirst('=', seg)
        eq === nothing && return nothing
        lhs = strip(seg[1:prevind(seg, eq)])
        rhs = strip(seg[nextind(seg, eq):end])
        # LHS must be a real identifier (a loop variable), and the RHS must not itself start with `=`
        # (guards `==`/`>=`/`<=` — a human comparison, never a Test forloop binding). Unicode-aware, so
        # `χ`/`β`/… parse (a character-class regex would miss them).
        (isempty(lhs) || isempty(rhs) || startswith(rhs, "=")) && return nothing
        Base.isidentifier(lhs) || return nothing
        push!(out, Symbol(lhs) => String(rhs))
    end
    return isempty(out) ? nothing : out
end

_binding_vars(b) = Symbol[k for (k, _) in b]
_binding_str(b) = join(("$(k) = $(v)" for (k, v) in b), ", ")

# A level is a sweep iff it has children, every non-ignored one parses to a binding, and they all agree
# on the variable sequence. A test FILE is never a sample (it is a page), and a mix of canonical and
# non-canonical siblings does not fold (we keep them as sections and warn — never silently).
function _is_swept(n, page_when::Function)
    vars = nothing
    any = false
    for ch in n.children
        ch.ignore && continue
        page_when(ch.description) && return false
        b = _parse_binding(ch.description)
        b === nothing && return false
        v = _binding_vars(b)
        vars === nothing ? (vars = v) : (v == vars || return false)
        any = true
    end
    return any
end

# Every leaf Check under a swept node, each tagged with its full binding stack (recursing through nested
# sweeps, flattening any non-sweep structure inside a sample). Returns `[(bindings, check), …]`.
function _sweep_samples!(out, n, prefix, page_when::Function)
    for ch in n.children
        ch.ignore && continue
        b = _parse_binding(ch.description)
        stack = b === nothing ? prefix : vcat(prefix, b)
        if _is_swept(ch, page_when)
            _sweep_samples!(out, ch, stack, page_when)
        else
            for c in _collect_checks!(Check[], ch)
                push!(out, (stack, c))
            end
        end
    end
    return out
end

function _collect_checks!(acc, n)
    append!(acc, n.checks)
    for ch in n.children
        ch.ignore || _collect_checks!(acc, ch)
    end
    return acc
end

function _sweep_has_user_content(n)
    return !isempty(n.figures) ||
           !isempty(n.tables) ||
           !isempty(n.panels) ||
           any(_sweep_has_user_content, n.children)
end

# Group samples by quantity = the check label (the test expression `orig_expr`, which is loop-invariant,
# so it is a stable identity across iterations — issue #69 B). Preserves first-seen order.
function _group_quantities(samples)
    order = String[]
    groups = Dict{String,typeof(samples)}()
    for s in samples
        key = s[2].label
        haskey(groups, key) || (push!(order, key); groups[key]=typeof(samples)())
        push!(groups[key], s)
    end
    return [(k, groups[k]) for k in order]
end

# Render a swept level: a convergence + margin figure per quantity, then every sample check placed flat
# (binding-tagged) so the page's pass/fail counts and `agent.json` verdict stay exactly what they were —
# the sweep changes only how the checks are DRAWN, never the verdict.
function _emit_sweep!(n, counter::Ref{Int}, page_when::Function, acc::Vector{Check})
    c = _ctx_container()
    samples = _sweep_samples!(
        Tuple{Vector{Pair{Symbol,String}},Check}[], n, Pair{Symbol,String}[], page_when
    )
    isempty(samples) && return acc
    _sweep_has_user_content(n) && _diag!(
        WARNING,
        string(c.id, "_sweep"),
        "@figure/@table inside a swept `@testset for` is not folded yet — omitted from the sweep view (issue #69 E follow-up)",
    )
    qi = Ref(0)
    for (label, pts) in _group_quantities(samples)
        _push_sweep_figures!(c.id, qi, label, pts)
    end
    for (bind, chk) in samples
        tagged = Check(
            chk.id,
            string(chk.label, "  [", _binding_str(bind), "]"),
            chk.got,
            chk.want,
            chk.delta,
            chk.tol,
            chk.kind,
            chk.pass,
            chk.source,
        )
        _place_check!(c, tagged, counter, acc)
    end
    return acc
end

# Build the two figures for one quantity. Innermost binding = x (numeric → a real axis, else categorical
# ticks); outer bindings = the legend. `want`/`tol` recover the reference line and tolerance band.
function _push_sweep_figures!(cid::Symbol, qi::Ref{Int}, label::AbstractString, pts)
    xvar = last(_binding_vars(pts[1][1]))
    xval(p) = last(p[1])[2]
    numeric = all(p -> tryparse(Float64, xval(p)) !== nothing, pts)
    ticks =
        numeric ? sort(unique(xval.(pts)); by=s -> parse(Float64, s)) : unique(xval.(pts))
    xticklabels = numeric ? [_fmt_num(parse(Float64, t)) for t in ticks] : ticks
    tickindex = Dict(t => i for (i, t) in enumerate(ticks))
    K = length(ticks)
    legkey(p) = _binding_str(p[1][1:(end - 1)])
    legs = unique(legkey.(pts))
    wantv = fill(NaN, K)
    bandlo = fill(NaN, K)
    bandhi = fill(NaN, K)
    conv_series = NamedTuple[]
    marg_series = NamedTuple[]
    for lg in legs
        xs, gy, my, ok = Int[], Float64[], Float64[], Bool[]
        for p in pts
            legkey(p) == lg || continue
            i = tickindex[xval(p)]
            c = p[2]
            push!(xs, i)
            push!(gy, c.got)
            push!(my, _margin(c))
            push!(ok, c.pass)
            wantv[i] = c.want
            tolabs = c.kind === :rel ? c.tol * abs(c.want) : c.tol
            bandlo[i] = c.want - tolabs
            bandhi[i] = c.want + tolabs
        end
        perm = sortperm(xs)
        push!(conv_series, (; label=lg, xs=xs[perm], ys=gy[perm], ok=ok[perm]))
        push!(marg_series, (; label=lg, xs=xs[perm], ys=my[perm], ok=ok[perm]))
    end
    band = [(bandlo[i], bandhi[i]) for i in 1:K]
    qi[] += 1
    q = _trunc(label, 44)
    _push_figure!(;
        gen=() -> _sweep_plot_svg(
            tempname() * ".svg";
            title="convergence — $(q)",
            xlabel=string(xvar),
            ylabel="got",
            xticklabels=xticklabels,
            series=conv_series,
            band=band,
            refline=wantv,
        ),
        code="",
        caption="Convergence of `$(q)` over the swept axis `$(xvar)`. Dashed line = `want`; the shaded " *
                "band is the tolerance; a red marker is a failed check.",
        id=Symbol(cid, :_conv_, qi[]),
        data=(;
            xlabel=string(xvar),
            ylabel="got",
            series=[
                (; label=isempty(s.label) ? "got" : s.label, x=s.xs, y=s.ys) for
                s in conv_series
            ],
        ),
    )
    _push_figure!(;
        gen=() -> _sweep_plot_svg(
            tempname() * ".svg";
            title="margin — $(q)",
            xlabel=string(xvar),
            ylabel="delta / tol",
            xticklabels=xticklabels,
            series=marg_series,
            hline=1.0,
        ),
        code="",
        caption="Tolerance budget `delta/tol` of `$(q)` over `$(xvar)`; the dashed line at 1.0 is the " *
                "pass/fail boundary.",
        id=Symbol(cid, :_swpmargin_, qi[]),
        data=(;
            xlabel=string(xvar),
            ylabel="delta / tol",
            series=[
                (; label=isempty(s.label) ? "margin" : s.label, x=s.xs, y=s.ys) for
                s in marg_series
            ],
        ),
    )
    return nothing
end

_trunc(s, n) = length(s) > n ? first(s, n - 1) * "…" : String(s)
function _fmt_num(v)
    isfinite(v) || return ""
    return (isinteger(v) && abs(v) < 1e15) ? string(Int(v)) : string(round(v; sigdigits=4))
end

# A small multi-series line plot as hand-written SVG (same reason as `_margin_svg`: `@figure`'s gen may
# return a file path, so a test report draws itself without dragging a plotting backend into every test
# env). `series` is `[(; label, xs::Vector{Int}, ys::Vector{Float64}, ok::Vector{Bool}), …]` where `xs`
# index into `xticklabels`; `band` shades a per-tick `(lo, hi)`, `refline` dashes a per-tick reference,
# `hline` draws one horizontal boundary. y is auto-scaled over everything drawn.
function _sweep_plot_svg(
    path;
    title,
    xlabel,
    ylabel,
    xticklabels::Vector{String},
    series,
    band=nothing,
    refline=nothing,
    hline=nothing,
)
    K = length(xticklabels)
    W, H, L, R, T, Bm = 640, 300, 66, 150, 30, 46
    plotw, ploth = W - L - R, H - T - Bm
    xat(i) = K <= 1 ? L + plotw / 2 : L + plotw * (i - 1) / (K - 1)
    ys = Float64[]
    for s in series, y in s.ys
        isfinite(y) && push!(ys, y)
    end
    band === nothing || for (lo, hi) in band
        isfinite(lo) && push!(ys, lo)
        isfinite(hi) && push!(ys, hi)
    end
    refline === nothing || append!(ys, filter(isfinite, refline))
    hline === nothing || push!(ys, hline)
    isempty(ys) && (ys = [0.0, 1.0])
    ylo, yhi = extrema(ys)
    ylo == yhi && (ylo -= 0.5; yhi += 0.5)
    pad = 0.08 * (yhi - ylo)
    ylo -= pad
    yhi += pad
    yat(v) = T + ploth * (1 - (v - ylo) / (yhi - ylo))
    io = IOBuffer()
    print(
        io,
        """<svg xmlns="http://www.w3.org/2000/svg" width="$(W)" height="$(H)" font-family="ui-monospace,Menlo,monospace" font-size="11">
        <text x="$(L)" y="16" font-size="12" fill="#444">$(_xml(title))</text>
        <line x1="$(L)" y1="$(T)" x2="$(L)" y2="$(T + ploth)" stroke="#bbb"/>
        <line x1="$(L)" y1="$(T + ploth)" x2="$(L + plotw)" y2="$(T + ploth)" stroke="#bbb"/>
        <text x="$(L + plotw / 2)" y="$(H - 8)" text-anchor="middle" fill="#444">$(_xml(xlabel))</text>
        <text x="14" y="$(T + ploth / 2)" transform="rotate(-90 14 $(T + ploth / 2))" text-anchor="middle" fill="#444">$(_xml(ylabel))</text>
        """,
    )
    for v in (ylo + pad, (ylo + yhi) / 2, yhi - pad)
        y = yat(v)
        print(
            io,
            """<line x1="$(L - 4)" y1="$(y)" x2="$(L)" y2="$(y)" stroke="#bbb"/><text x="$(L - 7)" y="$(y + 3)" text-anchor="end" fill="#888">$(_fmt_num(v))</text>\n""",
        )
    end
    for i in 1:K
        x = xat(i)
        print(
            io,
            """<line x1="$(x)" y1="$(T + ploth)" x2="$(x)" y2="$(T + ploth + 4)" stroke="#bbb"/><text x="$(x)" y="$(T + ploth + 16)" text-anchor="middle" fill="#888">$(_xml(xticklabels[i]))</text>\n""",
        )
    end
    if band !== nothing
        hi_pts, lo_pts = String[], String[]
        for i in 1:K
            lo, hi = band[i]
            (isfinite(lo) && isfinite(hi)) || continue
            push!(hi_pts, "$(xat(i)),$(yat(hi))")
            pushfirst!(lo_pts, "$(xat(i)),$(yat(lo))")
        end
        isempty(hi_pts) || print(
            io,
            """<polygon points="$(join(vcat(hi_pts, lo_pts), " "))" fill="#4c9f70" fill-opacity="0.12"/>\n""",
        )
    end
    if refline !== nothing
        d = ["$(xat(i)),$(yat(refline[i]))" for i in 1:K if isfinite(refline[i])]
        length(d) >= 2 && print(
            io,
            """<polyline points="$(join(d, " "))" fill="none" stroke="#4c9f70" stroke-width="1.3" stroke-dasharray="4,3"/>\n""",
        )
    end
    if hline !== nothing
        y = yat(hline)
        print(
            io,
            """<line x1="$(L)" y1="$(y)" x2="$(L + plotw)" y2="$(y)" stroke="#d9534f" stroke-width="1" stroke-dasharray="3,2"/><text x="$(L + plotw)" y="$(y - 3)" text-anchor="end" fill="#d9534f">tol</text>\n""",
        )
    end
    ly = T + 4
    for (si, s) in enumerate(series)
        col = _SERIES_COLORS[(si - 1) % length(_SERIES_COLORS) + 1]
        d = [
            "$(xat(s.xs[j])),$(yat(s.ys[j]))" for j in eachindex(s.xs) if isfinite(s.ys[j])
        ]
        length(d) >= 2 && print(
            io,
            """<polyline points="$(join(d, " "))" fill="none" stroke="$(col)" stroke-width="1.6"/>\n""",
        )
        for j in eachindex(s.xs)
            isfinite(s.ys[j]) || continue
            print(
                io,
                """<circle cx="$(xat(s.xs[j]))" cy="$(yat(s.ys[j]))" r="3" fill="$(s.ok[j] ? col : "#d9534f")" stroke="#fff" stroke-width="0.6"/>\n""",
            )
        end
        if !isempty(s.label)
            print(
                io,
                """<line x1="$(L + plotw + 10)" y1="$(ly)" x2="$(L + plotw + 26)" y2="$(ly)" stroke="$(col)" stroke-width="2"/><text x="$(L + plotw + 30)" y="$(ly + 3)" fill="#555">$(_xml(_trunc(s.label, 18)))</text>\n""",
            )
            ly += 15
        end
    end
    print(io, "</svg>\n")
    write(path, take!(io))
    return path
end

# ── the document ─────────────────────────────────────────────────────

# Assign a COLLISION-FREE id: `base` if unseen, else `base-2`, `base-3`, … plus a loud diagnostic —
# two distinct nodes must never fold onto one anchor / `agent.json` id silently (a `_slug(desc)` is
# flat, so two same-named test files or sections would otherwise clash). `seen` accumulates every
# page/section id assigned in the document; page ids are global, section ids are page-qualified.
function _unique_id!(seen::Set{Symbol}, base::Symbol, desc)
    if !(base in seen)
        push!(seen, base)
        return base
    end
    k = 2
    while Symbol(base, "-", k) in seen
        k += 1
    end
    id = Symbol(base, "-", k)
    push!(seen, id)
    _diag!(
        WARNING,
        string(id),
        "duplicate id \"$(base)\" (from \"$(desc)\") → disambiguated to $(id); rename the testset to fix",
    )
    return id
end

# `acc` collects every Check pushed anywhere in this subtree, in emission order. A page's checks are
# spread across its @sections (that is the whole nesting), so the page-level margin figure cannot be
# rebuilt from the page container alone — it has to be accumulated on the way down.
#
# `n` is duck-typed: a live `PinaxTestSet` (direct render — carries user `@figure`/`@desc`/… too) or
# a merged `TestNode` (a sharded run — checks + structure only). Same fold either way.
function _emit_node!(
    n, counter::Ref{Int}, page_when::Function, seen::Set{Symbol}, acc::Vector{Check}=Check[]
)
    _emit_own_content!(n, counter, acc)
    # A level whose children are all canonical `@testset for` samples is a SWEEP, not a stack of
    # sections: fold it into convergence + margin figures (issue #69 C). Only inside an open container
    # (a page/section) — never at the root, where children are files and the grouping-flatten runs.
    if _ctx_container() !== nothing && _is_swept(n, page_when)
        _emit_sweep!(n, counter, page_when, acc)
        return acc
    end
    # Nested testsets become pages (a file) or sections (a group). @pinaxignore'd ones are skipped
    # HERE only — never in the counts, so an ignored subtree still fails the suite if it is red.
    for ch in n.children
        ch.ignore && continue
        if page_when(ch.description)
            pid = _unique_id!(seen, _slug(ch.description), ch.description)   # page ids are GLOBAL
            _enter_page!(pid, ch.description; status=:benchmark, summary=_summary_line(ch))
            try
                page_checks = Check[]
                _emit_node!(ch, counter, page_when, seen, page_checks)
                append!(acc, page_checks)
                # Back at page level (every section closed), so the figure lands on the page.
                _push_margin_figure!(pid, page_checks)
            finally
                _exit_page!()
            end
        elseif _ctx_container() === nothing
            # At the root with no page open, a non-file testset is a GROUPING (e.g. the top-level
            # `@testset "MyPkg"` that most runtests wrap everything in) → flatten it: its children
            # become top-level pages, exactly as `_collect_rows!` already treats it. A section needs a
            # page, which a grouping at this level does not provide.
            _emit_node!(ch, counter, page_when, seen, acc)
        else
            # A child that parses as a canonical binding but is being rendered as a SECTION means its
            # siblings are not a consistent sweep (mixed/partial) — so we did not fold. Say so once
            # (invariant III: never fall back to silence), then render it as an ordinary section.
            if _parse_binding(ch.description) !== nothing && !(:_sweep_warned in seen)
                push!(seen, :_sweep_warned)
                _diag!(
                    WARNING,
                    "sweep",
                    "a `@testset for` sample could not be folded (its siblings are not a consistent " *
                    "canonical sweep) — rendered as a section instead",
                )
            end
            # Section ids are PAGE-QUALIFIED (`<pageid>_<slug>`) so a "conv" section in two files does
            # not clash; a true sibling collision within one page then gets the `-2` suffix.
            sid = _unique_id!(
                seen, Symbol(current_page().id, :_, _slug(ch.description)), ch.description
            )
            _enter_section!(sid, ch.description; summary=_summary_line(ch))
            try
                _emit_node!(ch, counter, page_when, seen, acc)
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

# ── provenance (issue #69 H) ─────────────────────────────────────────
#
# The facts a test artifact must record to not lie: WHEN it ran, against WHAT code, on WHICH Julia/OS.
# A green report with no commit/date is indistinguishable from a stale one, and a stochastic suite with
# no recorded seed/commit is an artifact you cannot trust. Captured NON-FATALLY at render — any field
# that cannot be read is simply omitted (never an error, invariant IV) — with CI variables preferred
# over a local `git` probe (they are reliable inside the `Pkg.test` sandbox, where `git` may be absent).
function _provenance_rows()
    rows = NamedTuple[]
    add(f, v) =
        (v === nothing || isempty(string(v))) || push!(rows, (field=f, value=string(v)))
    add("generated", Base.Libc.strftime("%Y-%m-%d %H:%M:%S", time()))
    add("julia", VERSION)
    add("os", string(Sys.KERNEL, " / ", Sys.ARCH))
    add("threads", Threads.nthreads())
    sha = get(ENV, "GITHUB_SHA", "")
    isempty(sha) && (sha = try
        readchomp(pipeline(`git rev-parse HEAD`; stderr=devnull))
    catch
        ""
    end)
    isempty(sha) || add("commit", first(sha, 12))
    add("repo", get(ENV, "GITHUB_REPOSITORY", ""))
    add("ref", get(ENV, "GITHUB_REF_NAME", ""))
    add("package", _active_package_line())
    return rows
end

_active_package_line() = _package_line(Base.active_project())

# `name v<version>` from a Project.toml, or "" if it has no name / cannot be read (non-fatal). Split
# from the `Base.active_project()` lookup so the parse is unit-testable without activating an env.
function _package_line(p)
    try
        (p === nothing || !isfile(p)) && return ""
        d = TOML.parsefile(p)
        name = get(d, "name", "")
        isempty(name) && return ""
        ver = get(d, "version", "")
        return isempty(ver) ? String(name) : "$(name) v$(ver)"
    catch
        return ""
    end
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
    seen = Set{Symbol}((:overview, :per_file, :provenance))   # ids the overview page already owns
    # An overview page first: one row per file, so the whole suite is one glance — and the SAME rows
    # land in agent.json as data, so an LLM reads the suite without scraping a log.
    _enter_page!(:overview, title; layout=:wide, summary=_summary_line(root))
    try
        prov = _provenance_rows()
        isempty(prov) || _push_table!(;
            data=prov,
            code="",
            caption="Provenance — when this report ran, against what code, on which Julia / OS. " *
                    "A report that omits these cannot be told apart from a stale one.",
            id=:provenance,
        )
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
    _emit_node!(root, counter, page_when, seen)
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
    d = Dict{String,Any}(
        "label" => c.label,
        "got" => c.got,
        "want" => c.want,
        "delta" => c.delta,
        "tol" => c.tol,
        "kind" => String(c.kind),
        "pass" => c.pass,
    )
    isempty(c.source) || (d["source"] = c.source)   # carry WHERE it failed across a shard dump
    return d
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
        get(d, "source", ""),
    )
end

"Where a shard writes its tree instead of rendering (`PINAX_TEST_DUMP`); empty = render directly."
report_dump() = get(ENV, "PINAX_TEST_DUMP", "")
