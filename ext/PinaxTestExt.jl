# PinaxTestExt — the `Test`-dependent half of the test bridge (the Test-free half is src/testset.jl).
#
# This module is deliberately small. Its ONLY job is to observe a running suite through Test's
# `AbstractTestSet` interface and hand Pinax a `TestNode` tree. Summaries, the margin figure, the
# document, the TOML dump, and the merge of several shards' dumps are all plain Julia over `TestNode`
# in Pinax proper — where they need no `Test`, and are testable without it.
module PinaxTestExt

using Pinax
using Pinax:
    Check,
    TestNode,
    _check_from,
    _looks_like_a_file,
    _summary_line,
    dump_test_report,
    render_test_report,
    report_dump,
    report_enabled,
    report_out
using Test: Test, AbstractTestSet

"""
    _testset_type() -> Type

`Test.DefaultTestSet` unless the report is switched on — see `Pinax.testset_type`. Falling back to
the STOCK type (rather than to a Pinax set that merely skips rendering) is the point: with the env
var unset there is no new code in the test path at all, so turning the bridge on cannot regress a
suite that was passing.
"""
_testset_type() = report_enabled() ? PinaxTestSet : Test.DefaultTestSet

mutable struct PinaxTestSet <: AbstractTestSet
    description::String
    results::Vector{Any}          # nested PinaxTestSet | Test.Result
    t0::Float64
    elapsed::Float64
    out::String                   # root only: where to render
    dump::String                  # root only: dump the tree here INSTEAD of rendering ("" = render)
    page_when::Function           # root only: which testsets become pages
    title::String
    ignore::Bool                  # set by @pinaxignore: run, count, but do not render
end

# Both entry points land here: `@pinaxtestset "…"` (options only ever on the ROOT), and a NESTED
# @testset, which Julia constructs from the parent's TYPE as `T(desc)` — with no options at all,
# which is exactly why the root's options have to be able to come from the environment.
function PinaxTestSet(
    description::AbstractString;
    out=report_out(),
    dump=report_dump(),
    page_when::Function=_looks_like_a_file,
    title::AbstractString="Test report",
)
    return PinaxTestSet(
        String(description),
        Any[],
        time(),
        NaN,
        String(out),
        String(dump),
        page_when,
        String(title),
        false,
    )
end

# @pinaxignore, from inside the testset body. A no-op unless the innermost set is one of ours — so it
# is safe to leave in the code with the report switched off (where the set is a DefaultTestSet).
function Pinax._ignore_current_testset!()
    Test.get_testset_depth() == 0 && return nothing
    ts = Test.get_testset()
    ts isa PinaxTestSet && (ts.ignore = true)
    return nothing
end

Test.record(ts::PinaxTestSet, res) = (push!(ts.results, res); res)

function Test.finish(ts::PinaxTestSet)
    ts.elapsed = time() - ts.t0
    if Test.get_testset_depth() > 0
        Test.record(Test.get_testset(), ts)      # nest into the parent
        return ts
    end
    # ── ROOT ─────────────────────────────────────────────────────────
    root = _to_node(ts)
    if ts.ignore
        nothing
    elseif !isempty(ts.dump)
        # A CI shard: dump the tree, render NOTHING. One later job merges every shard's tree into the
        # single gallery the design implies — one page per test FILE, not one gallery per shard.
        dump_test_report(root, ts.dump)
        println("\nPinax test report: ", _summary_line(root), "\n  dumped → ", ts.dump)
    else
        render_test_report(root; out=ts.out, title=ts.title, page_when=ts.page_when)
        println(
            "\nPinax test report: ",
            _summary_line(root),
            "\n  rendered → $(ts.out)_html/  $(ts.out)_agent/",
        )
    end
    n_fail, n_err = _count(ts, Test.Fail), _count(ts, Test.Error)
    if n_fail + n_err > 0
        # Stay a well-behaved testset: a failing suite must still fail the process.
        error("PinaxTestSet: $(n_fail) failed, $(n_err) errored")
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

# A Pass/Fail/Error becomes a Check. A Broken one does NOT: it has no verdict to show — it did not
# pass, but the runner is perfectly happy about it, and encoding it as `pass=false` would paint the
# page red and flip the benchmark verdict to FAIL. It is counted instead.
_is_check(r) = r isa Test.Pass || r isa Test.Fail || r isa Test.Error

function _to_node(ts::PinaxTestSet)
    checks = Check[]
    children = TestNode[]
    nbroken = 0
    nerror = 0
    for r in ts.results
        if r isa PinaxTestSet
            push!(children, _to_node(r))
        elseif _is_check(r)
            r isa Test.Error && (nerror += 1)
            push!(checks, _check_from(_result_data_expr(r), _label(r), r isa Test.Pass, 0))
        elseif r isa Test.Result
            nbroken += 1
        end
    end
    return TestNode(
        ts.description;
        elapsed=ts.elapsed,
        ignore=ts.ignore,
        checks=checks,
        nbroken=nbroken,
        nerror=nerror,
        children=children,
    )
end

function _count(ts::PinaxTestSet, T::Type)
    n = 0
    for r in ts.results
        r isa PinaxTestSet ? (n += _count(r, T)) : (r isa T && (n += 1))
    end
    return n
end

end # module
