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

The `Test.AbstractTestSet` subtype that renders a whole testset tree as a Pinax document. It lives
in the `PinaxTestExt` extension, so it needs `using Test` — which you necessarily have, since
`@testset` is Test's own macro.

Julia does not let an extension add a name to its parent's namespace, and `@testset T …` insists that
`T` be a bare identifier naming a real `AbstractTestSet` subtype (`Test.parse_testset_args` rejects
any other expression, and `Test._check_testset` rejects any other value). So the type is fetched and
bound once, in the `runtests.jl` that uses it:

    using Pinax, Test
    const PinaxTestSet = Pinax.testset_type()

    @testset PinaxTestSet "MyPkg" out="test-report" begin
        include("test_a.jl")     # a test FILE       → @page (status = :benchmark)
    end                          # a nested @testset → @section
                                 # each @test        → a Check

That is the whole adoption cost: one line, and not a single test changes. Julia gives a nested
`@testset` the *parent's* type, so every nested testset is captured automatically — nothing to
annotate. The set still fails the process when the suite is red: a report must never turn a failing
suite green.

Renders `<out>_html` (the human gallery) and `<out>_agent` (`agent.json` — the same verdict as data,
so a reviewing agent reads the margins instead of scraping a CI log). With `out=nothing` nothing is
written and the set behaves like a plain recorder.

`page_when(description)::Bool` decides which testsets become their own `@page` rather than a
`@section`. The default treats a testset whose description looks like a test file (ends in `.jl`) as
a page — exactly the `@testset "\$f" begin include(f) end` idiom.
"""
function testset_type()
    ext = Base.get_extension(@__MODULE__, :PinaxTestExt)
    ext === nothing && error(
        "Pinax: the test bridge needs the Test stdlib loaded (`using Test`) — the testset type " *
        "lives in the PinaxTestExt extension.",
    )
    return ext.PinaxTestSet
end

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

function _push_check_raw!(chk::Check)
    c = _current_container()
    c === nothing && return chk
    push!(c.checks, chk)
    push!(c.content, :check => length(c.checks))
    return chk
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
