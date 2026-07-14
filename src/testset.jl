# testset.jl — render a Julia `Test` suite as a Pinax document.
#
# A test suite is normally a binary: green or red. But Pinax already has the pieces to say
# something much more useful — `@expect` records a `Check(got, want, delta, tol, pass)`, and a
# `status=:benchmark` page renders those as a colored pass/fail report (and emits
# `{verdict, passed, total, failed, checks:[…]}` into `agent.json`). All that was missing was
# the bridge FROM `Test`.
#
# `PinaxTestSet` is that bridge:
#
#     test file  (@testset "test_foo.jl")  →  @page (status=:benchmark)
#     @testset   (nested)                  →  @section  (recursively)
#     @test                                →  a Check
#
# Usage — ONE line in runtests.jl; not a single test changes:
#
#     using Pinax
#     @testset PinaxTestSet "MyPkg" out="test-report" begin
#         include("test_a.jl")
#         include("test_b.jl")
#     end
#
# Julia gives a nested `@testset` the *parent's* type, so every nested testset is captured
# automatically — nothing to annotate.
#
# THE POINT — a margin, not a verdict. For any `@test isapprox(got, want; rtol=…)` the real
# numbers are recovered, so the report shows `delta/tol`: how much room a test passed BY. A
# check sitting at 99% of its tolerance is one refactor away from red and looks identical to a
# rock-solid one in a green CI badge. Here they look nothing alike.

using Test: Test, AbstractTestSet

"""
    PinaxTestSet(description; out=nothing, page_when=_looks_like_a_file)

A `Test.AbstractTestSet` that captures the whole testset tree and renders it as a Pinax
document (see `src/testset.jl`). Pass `out=` on the ROOT testset to render there; with
`out=nothing` nothing is written and the set behaves like a plain recorder.

`page_when(description)::Bool` decides which testsets become their own `@page` rather than a
`@section`. The default treats a testset whose description looks like a test file (ends in
`.jl`) as a page — which is exactly the `@testset "\$f" begin include(f) end` idiom the fleet
already uses.
"""
mutable struct PinaxTestSet <: AbstractTestSet
    description::String
    results::Vector{Any}          # nested PinaxTestSet | Test.Result
    t0::Float64
    elapsed::Float64
    out::Union{Nothing,String}    # root only: where to render
    page_when::Function
    title::String
end

_looks_like_a_file(desc::AbstractString) = endswith(desc, ".jl")

function PinaxTestSet(
    description::AbstractString;
    out=nothing,
    page_when::Function=_looks_like_a_file,
    title::AbstractString="Test report",
)
    return PinaxTestSet(
        String(description), Any[], time(), NaN, out, page_when, String(title)
    )
end

Test.record(ts::PinaxTestSet, res) = (push!(ts.results, res); res)

function Test.finish(ts::PinaxTestSet)
    ts.elapsed = time() - ts.t0
    if Test.get_testset_depth() > 0
        Test.record(Test.get_testset(), ts)      # nest into the parent
        return ts
    end
    # ── ROOT ─────────────────────────────────────────────────────────
    ts.out === nothing || _render_test_report(ts)
    _print_summary(ts)
    n_fail, n_err = _count(ts, Test.Fail), _count(ts, Test.Error)
    if n_fail + n_err > 0
        # Stay a well-behaved testset: a failing suite must still fail the process.
        error("PinaxTestSet: $(n_fail) failed, $(n_err) errored (report: $(ts.out))")
    end
    return ts
end

# ── recovering the NUMBERS out of a Test result ──────────────────────
#
# Measured on Julia 1.12 (do not "simplify" this — the asymmetry is real):
#   Test.Pass.data  is an **Expr** with the arguments already EVALUATED:
#                     :(isapprox(-0.10203, -0.10242; rtol = 0.01, atol = 1.0e-10))
#   Test.Fail.data  is a **String** of the same thing — it must be Meta.parse'd.
# Miss that and every *failing* check silently loses its numbers, which are precisely the ones
# you want to look at.
_result_data_expr(r::Test.Pass) = r.data isa Expr ? r.data : nothing
function _result_data_expr(r::Test.Fail)
    r.data === nothing && return nothing
    try
        e = Meta.parse(String(r.data))
        return e isa Expr ? e : nothing
    catch
        return nothing
    end
end
_result_data_expr(::Any) = nothing

# `isapprox(got, want; rtol=…, atol=…)` / `got ≈ want` → (got, want, tol, kind), or nothing.
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
    # isapprox is `|x-y| <= max(atol, rtol*max(|x|,|y|))`. A Check carries ONE kind, so report
    # the one that actually governs: relative when there is a nonzero reference, else absolute.
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

# ── build the document ───────────────────────────────────────────────

_ok(r) = r isa Test.Pass
_countable(r) = r isa Test.Result

function _count(ts::PinaxTestSet, T::Type)
    n = 0
    for r in ts.results
        r isa PinaxTestSet ? (n += _count(r, T)) : (r isa T && (n += 1))
    end
    return n
end
_ntests(ts::PinaxTestSet) = _count(ts, Test.Result)

_slug(s) = Symbol(replace(lowercase(strip(s)), r"[^a-z0-9]+" => "_"))

# One Check per @test. A numeric `isapprox` keeps its real got/want/tol (that is the whole
# point); anything else is encoded as a 1/0 indicator so that EVERY assertion still shows up in
# the machine-readable verdict rather than silently vanishing.
#
# `pass` is taken from Julia's OWN verdict, never recomputed from delta<=tol: isapprox combines
# atol and rtol in a way a single-kind Check cannot reproduce, and a report that disagrees with
# the test runner is worse than no report.
function _check_for(r::Test.Result, i::Int)
    id = Symbol("t", i)
    passed = _ok(r)
    label = _label(r)
    nums = _approx_numbers(_result_data_expr(r))
    if nums === nothing
        got = passed ? 1.0 : 0.0
        return Check(id, label, got, 1.0, abs(got - 1.0), 0.5, :abs, passed)
    end
    got, want, tol, kind = nums
    delta = kind === :rel ? abs(got - want) / abs(want) : abs(got - want)
    return Check(id, label, got, want, delta, tol, kind, passed)
end

function _label(r::Test.Result)
    e = hasproperty(r, :orig_expr) ? getproperty(r, :orig_expr) : nothing
    s = e === nothing ? string(typeof(r)) : string(e)
    length(s) > 110 && (s = s[1:107] * "…")
    return s
end

function _push_check_raw!(chk::Check)
    c = _current_container()
    c === nothing && return chk
    push!(c.checks, chk)
    push!(c.content, :check => length(c.checks))
    return chk
end

# `acc` collects every Check pushed anywhere in this subtree, in emission order. A page's checks are
# spread across its @sections (that is the whole nesting), so the page-level margin figure cannot be
# rebuilt from the page container alone — it has to be accumulated on the way down.
function _emit(ts::PinaxTestSet, counter::Ref{Int}, acc::Vector{Check}=Check[])
    # The direct Test.Results of THIS testset become checks in the current container.
    for r in ts.results
        r isa Test.Result || continue
        counter[] += 1
        chk = _check_for(r, counter[])
        _push_check_raw!(chk)
        push!(acc, chk)
    end
    # Nested testsets become pages (a file) or sections (a group).
    for r in ts.results
        r isa PinaxTestSet || continue
        if ts.page_when(r.description)
            pid = _slug(r.description)
            _enter_page!(
                pid,
                r.description;
                status=:benchmark,           # → the colored pass/fail report
                summary=_summary_line(r),
            )
            try
                page_checks = Check[]
                _emit(r, counter, page_checks)
                append!(acc, page_checks)
                # Back at page level (every section closed), so the figure lands on the page.
                _push_margin_figure!(pid, page_checks)
            finally
                _exit_page!()
            end
        else
            _enter_section!(_slug(r.description), r.description; summary=_summary_line(r))
            try
                _emit(r, counter, acc)
            finally
                _exit_section!()
            end
        end
    end
    return acc
end

# ── the margin profile figure ────────────────────────────────────────
#
# A hand-written SVG, on purpose. `@figure`'s `gen` may return a FILE PATH (backends.jl:269) — a
# first-class case needing no plotting extension — so the report draws itself without dragging
# Plots/Makie into every package's test env, which is the only reason this bridge is free to adopt.
#
# The bar is `delta/tol` (how much of its tolerance budget the check spent), clipped at 1.2 with the
# real value always printed. The line at 1.0 IS the pass/fail boundary: a bar that nearly touches it
# is a green test that is one refactor from red — the thing a CI badge cannot tell you.
const _MARGIN_W = 620
const _BAR_H = 18

function _margin_svg(checks::Vector{Check}, path::String)
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
        m = c.tol > 0 ? c.delta / c.tol : 0.0
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

# The figure for THIS page's checks: how far each assertion sat from its own tolerance.
function _push_margin_figure!(page_id::Symbol, checks::Vector{Check})
    isempty(checks) && return nothing
    # `data=` must be plot-data (`series=[(; label, x, y)]`) — it is the figure's TEXT channel for the
    # agent backend. The per-check got/want/tol already ride along in the benchmark `checks` JSON, so
    # the series carries only what the picture itself shows: the margin of check i.
    xs = collect(1:length(checks))
    ys = [c.tol > 0 ? c.delta / c.tol : 0.0 for c in checks]
    data = (;
        xlabel="check #",
        ylabel="delta / tol",
        series=[
            (; label="margin", x=xs, y=ys),
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

function _summary_line(ts::PinaxTestSet)
    n = _ntests(ts)
    f = _count(ts, Test.Fail)
    e = _count(ts, Test.Error)
    b = _count(ts, Test.Broken)
    t = isnan(ts.elapsed) ? "" : " · $(round(ts.elapsed; digits=2))s"
    return "$(n - f - e - b)/$(n) passed" *
           (f > 0 ? " · $(f) failed" : "") *
           (e > 0 ? " · $(e) errored" : "") *
           (b > 0 ? " · $(b) broken" : "") *
           t
end

function _render_test_report(ts::PinaxTestSet)
    reset!(; title=ts.title)
    counter = Ref(0)
    # An overview page first: one row per file, so the whole suite is one glance — and the
    # SAME rows land in agent.json as data, so an LLM reads the suite without scraping a log.
    _enter_page!(:overview, ts.title; layout=:wide, summary=_summary_line(ts))
    try
        rows = NamedTuple[]
        _collect_rows!(rows, ts)
        isempty(rows) || _push_table!(;
            data=rows,
            code="",
            caption="Per-file result profile. `worst margin` is the largest `delta/tol` " *
                    "seen in that file: 1.0 means a check landed exactly on its tolerance.",
            id=:per_file,
        )
    finally
        _exit_page!()
    end
    _emit(ts, counter)
    # Both backends, following `report`'s `<out>_html` / `<out>_agent` convention: the gallery is
    # for the human, the agent.json is the same verdict as data — so a reviewing agent reads the
    # suite's margins instead of scraping a CI log.
    doc = current_document()
    gallery = render(doc; out="$(ts.out)_html", theme=:gallery)
    agent = render(doc; out="$(ts.out)_agent", theme=:agent)
    return (; gallery, agent)
end

function _collect_rows!(rows::Vector{NamedTuple}, ts::PinaxTestSet)
    for r in ts.results
        r isa PinaxTestSet || continue
        if ts.page_when(r.description)
            n = _ntests(r)
            f = _count(r, Test.Fail)
            e = _count(r, Test.Error)
            margin = _worst_margin(r)
            push!(
                rows,
                (
                    file=r.description,
                    tests=n,
                    passed=n - f - e - _count(r, Test.Broken),
                    failed=f,
                    errored=e,
                    seconds=isnan(r.elapsed) ? missing : round(r.elapsed; digits=2),
                    worst_margin=margin === nothing ? missing : round(margin; digits=3),
                ),
            )
        else
            _collect_rows!(rows, r)
        end
    end
    return rows
end

# The largest delta/tol among this subtree's NUMERIC checks — how close the file came to red.
function _worst_margin(ts::PinaxTestSet)
    worst = nothing
    for r in ts.results
        if r isa PinaxTestSet
            m = _worst_margin(r)
            m === nothing || (worst = worst === nothing ? m : max(worst, m))
        elseif r isa Test.Result
            nums = _approx_numbers(_result_data_expr(r))
            nums === nothing && continue
            got, want, tol, kind = nums
            tol > 0 || continue
            d = kind === :rel ? abs(got - want) / abs(want) : abs(got - want)
            m = d / tol
            worst = worst === nothing ? m : max(worst, m)
        end
    end
    return worst
end

function _print_summary(ts::PinaxTestSet)
    println("\nPinax test report: ", _summary_line(ts))
    ts.out === nothing || println("  rendered → $(ts.out)_html/  $(ts.out)_agent/")
    return nothing
end
