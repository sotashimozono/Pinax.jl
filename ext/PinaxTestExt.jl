# PinaxTestExt — the `Test`-dependent half of the test bridge (the Test-free half is src/testset.jl).
#
# Only what genuinely needs `Test` lives here: the `AbstractTestSet` subtype, the `record`/`finish`
# machinery, and reading the numbers back out of a `Test.Result`. Everything else — Expr parsing, the
# `Check`, the SVG figure — stays in Pinax proper, where it is usable and testable without Test.
module PinaxTestExt

using Pinax
using Pinax:
    Check,
    _approx_numbers,
    _check_from,
    _enter_page!,
    _enter_section!,
    _exit_page!,
    _exit_section!,
    _looks_like_a_file,
    _margin,
    _push_check_raw!,
    _push_margin_figure!,
    _push_table!,
    _slug
using Test: Test, AbstractTestSet

mutable struct PinaxTestSet <: AbstractTestSet
    description::String
    results::Vector{Any}          # nested PinaxTestSet | Test.Result
    t0::Float64
    elapsed::Float64
    out::Union{Nothing,String}    # root only: where to render
    page_when::Function           # root only: which testsets become pages
    title::String
end

# Both entry points land here: `@testset PinaxTestSet "…" out=…` (options only ever on the ROOT), and
# a NESTED @testset, which Julia constructs from the parent's TYPE as `T(desc)` — no options.
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
# Miss that and every *failing* check silently loses its numbers, which are precisely the ones you
# want to look at.
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

function _label(r::Test.Result)
    e = hasproperty(r, :orig_expr) ? getproperty(r, :orig_expr) : nothing
    s = e === nothing ? string(typeof(r)) : string(e)
    length(s) > 110 && (s = s[1:107] * "…")
    return s
end

function _check_for(r::Test.Result, i::Int)
    return _check_from(_result_data_expr(r), _label(r), r isa Test.Pass, i)
end

# ── build the document ───────────────────────────────────────────────

function _count(ts::PinaxTestSet, T::Type)
    n = 0
    for r in ts.results
        r isa PinaxTestSet ? (n += _count(r, T)) : (r isa T && (n += 1))
    end
    return n
end
_ntests(ts::PinaxTestSet) = _count(ts, Test.Result)

# `acc` collects every Check pushed anywhere in this subtree, in emission order. A page's checks are
# spread across its @sections (that is the whole nesting), so the page-level margin figure cannot be
# rebuilt from the page container alone — it has to be accumulated on the way down.
#
# `page_when` is threaded from the ROOT rather than read off each nested set: only the root's kwargs
# are user-supplied (Julia constructs nested sets with `T(desc)` and no options), so reading
# `ts.page_when` at depth would silently fall back to the default.
function _emit(
    ts::PinaxTestSet, counter::Ref{Int}, page_when::Function, acc::Vector{Check}=Check[]
)
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
        if page_when(r.description)
            pid = _slug(r.description)
            _enter_page!(
                pid,
                r.description;
                status=:benchmark,           # → the colored pass/fail report
                summary=_summary_line(r),
            )
            try
                page_checks = Check[]
                _emit(r, counter, page_when, page_checks)
                append!(acc, page_checks)
                # Back at page level (every section closed), so the figure lands on the page.
                _push_margin_figure!(pid, page_checks)
            finally
                _exit_page!()
            end
        else
            _enter_section!(_slug(r.description), r.description; summary=_summary_line(r))
            try
                _emit(r, counter, page_when, acc)
            finally
                _exit_section!()
            end
        end
    end
    return acc
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
    Pinax.reset!(; title=ts.title)
    counter = Ref(0)
    # An overview page first: one row per file, so the whole suite is one glance — and the SAME rows
    # land in agent.json as data, so an LLM reads the suite without scraping a log.
    _enter_page!(:overview, ts.title; layout=:wide, summary=_summary_line(ts))
    try
        rows = NamedTuple[]
        _collect_rows!(rows, ts, ts.page_when)
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
    _emit(ts, counter, ts.page_when)
    # Both backends, following `report`'s `<out>_html` / `<out>_agent` convention: the gallery is for
    # the human, the agent.json is the same verdict as data — so a reviewing agent reads the suite's
    # margins instead of scraping a CI log.
    doc = Pinax.current_document()
    gallery = Pinax.render(doc; out="$(ts.out)_html", theme=:gallery)
    agent = Pinax.render(doc; out="$(ts.out)_agent", theme=:agent)
    return (; gallery, agent)
end

function _collect_rows!(rows::Vector{NamedTuple}, ts::PinaxTestSet, page_when::Function)
    for r in ts.results
        r isa PinaxTestSet || continue
        if page_when(r.description)
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
            _collect_rows!(rows, r, page_when)
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
            _approx_numbers(_result_data_expr(r)) === nothing && continue
            m = _margin(_check_for(r, 0))
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

end # module
