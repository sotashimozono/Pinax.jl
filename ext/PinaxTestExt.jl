# PinaxTestExt — the `Test`-dependent half of the test bridge (the Test-free half is src/testset.jl).
#
# This module is deliberately small. Its job is to observe a running suite through Test's
# `AbstractTestSet` interface and to BE the container: a `PinaxTestSet` holds Pinax's own structs
# (`Figure`/`Table`/`Check`/`Desc` + content order) directly — there is one document model, held in
# the task-local testset (safe under parallel tests exactly as `Test`'s own stack is). Summaries, the
# margin figure, the fold to a `Document`, and the shard dump/merge are all plain Julia over that
# duck-typed shape in Pinax proper — where they need no `Test`.
#
# A content macro (`@figure`/`@desc`/…) inside a test finds this container through the ONE seam
# `Pinax._current_container()`: we register a probe at load so that seam, staying `Test`-free, can
# route into the open `PinaxTestSet` (or no-op when the report is off — invariant V).
module PinaxTestExt

using Pinax
using Pinax:
    Check,
    Figure,
    Table,
    Desc,
    _anchor,
    _check_from,
    _looks_like_a_file,
    _nerror,
    _nfail,
    _slug,
    _summary_line,
    dump_test_report,
    render_test_report,
    report_dump,
    report_enabled,
    report_out
using Test: Test, AbstractTestSet

function __init__()
    # Register the container probe (a `Ref` assignment, not a method override — no precompile clash).
    Pinax._TEST_CONTAINER_PROBE[] = _current_test_container
    return nothing
end

# The probe `Pinax._current_container()` consults. Returns the innermost open Pinax test container,
# `:inert` (inside a test whose set is NOT ours — the report is off, so content macros no-op), or
# `:none` (not inside any testset — the manuscript path). Task-local via `Test.get_testset`.
function _current_test_container()
    Test.get_testset_depth() == 0 && return :none
    ts = Test.get_testset()
    return ts isa PinaxTestSet ? ts : :inert
end

"""
    _testset_type() -> Type

`Test.DefaultTestSet` unless the report is switched on — see `Pinax.testset_type`. Falling back to
the STOCK type (rather than to a Pinax set that merely skips rendering) is the point: with the env
var unset there is no new code in the test path at all, so turning the bridge on cannot regress a
suite that was passing.
"""
_testset_type() = report_enabled() ? PinaxTestSet : Test.DefaultTestSet

# The testset IS a Pinax container: the same fields a `Section`/`Page` carries, so the content macros
# push into it duck-typed through the seam, and the fold moves the real structs with no second model.
mutable struct PinaxTestSet <: AbstractTestSet
    description::String
    # --- Pinax container payload (one model, held task-local) ---
    id::Symbol
    anchor::String
    figures::Vector{Figure}
    tables::Vector{Table}
    checks::Vector{Check}
    panels::Vector{String}
    desc::Union{Desc,Nothing}
    content::Vector{Pair{Symbol,Int}}   # declaration order of figures/tables/panels/checks
    children::Vector{PinaxTestSet}
    nbroken::Int                        # @test_broken / skipped: counted, never a Check
    nerror::Int                         # failing checks that were ERRORS rather than plain fails
    # --- testset bookkeeping ---
    t0::Float64
    elapsed::Float64
    ignore::Bool                        # @pinaxignore: run + count, but keep out of the document
    # --- root-only options (a nested set is built by Test as T(desc), with none of these) ---
    out::String
    dump::String
    page_when::Function
    title::String
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
    id = _slug(description)
    return PinaxTestSet(
        String(description),
        id,
        _anchor(id),
        Figure[],
        Table[],
        Check[],
        String[],
        nothing,
        Pair{Symbol,Int}[],
        PinaxTestSet[],
        0,
        0,
        time(),
        NaN,
        false,
        String(out),
        String(dump),
        page_when,
        String(title),
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

# Record straight into the container: a nested set is a child; a Pass/Fail/Error becomes a `Check`
# tagged into content order at its emission site; a Broken is counted (see `finish`). Doing the
# conversion HERE (not lazily at finish) is what keeps the tree one model with no `.results` shadow.
function Test.record(ts::PinaxTestSet, res)
    if res isa PinaxTestSet
        push!(ts.children, res)                       # nest
    elseif res isa Test.Broken
        # A broken/skipped test is deliberately NOT a Check: it did not pass, but the runner is happy
        # about it, and `pass=false` would paint the page red and flip the verdict to FAIL. Counted.
        ts.nbroken += 1
    elseif res isa Test.Result                        # Pass / Fail / Error
        res isa Test.Error && (ts.nerror += 1)
        chk = _check_from(_result_data_expr(res), _label(res), res isa Test.Pass, 0)
        push!(ts.checks, chk)
        push!(ts.content, :check => length(ts.checks))
    end
    return res
end

function Test.finish(ts::PinaxTestSet)
    ts.elapsed = time() - ts.t0
    if Test.get_testset_depth() > 0
        Test.record(Test.get_testset(), ts)           # nest into the parent
        return ts
    end
    # ── ROOT ─────────────────────────────────────────────────────────
    if ts.ignore
        nothing
    elseif !isempty(ts.dump)
        # A CI shard: dump the tree, render NOTHING. One later job merges every shard's tree into the
        # single gallery the design implies — one page per test FILE, not one gallery per shard.
        dump_test_report(ts, ts.dump)
        println("\nPinax test report: ", _summary_line(ts), "\n  dumped → ", ts.dump)
    else
        render_test_report(ts; out=ts.out, title=ts.title, page_when=ts.page_when)
        println(
            "\nPinax test report: ",
            _summary_line(ts),
            "\n  rendered → $(ts.out)_html/  $(ts.out)_agent/",
        )
    end
    # Stay a well-behaved testset: a failing suite must still fail the process (invariant IV — a
    # report never turns a red suite green). Counted from the folded checks, duck-typed.
    nfail, nerr = _nfail(ts), _nerror(ts)
    if nfail + nerr > 0
        error("PinaxTestSet: $(nfail) failed, $(nerr) errored")
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

end # module
