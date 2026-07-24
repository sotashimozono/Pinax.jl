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
    CodeBlock,
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
    report_out,
    report_title
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
    codes::Vector{CodeBlock}
    panels::Vector{String}
    desc::Union{Desc,Nothing}
    content::Vector{Pair{Symbol,Int}}   # declaration order of figures/tables/panels/checks/codes
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

# The ROOT is constructed with options (by `Pinax.test`'s in-process `@testset PinaxTestSet` or the
# delegation preamble); a NESTED `@testset` is constructed by Julia from the parent's TYPE as
# `T(desc)` with no options — which is exactly why the root's options come from the environment
# (`Pinax.test` sets `PINAX_TEST_OUT` / `_DUMP` / `_TITLE`).
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
        CodeBlock[],
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
        chk.source = _source_str(res)                 # WHERE it failed (issue #69 I)
        chk.code = _capture_region(res)               # the code that produced it (default: whole region)
        push!(ts.checks, chk)
        push!(ts.content, :check => length(ts.checks))
    end
    return res
end

# "file:line" from a Test result's `source::LineNumberNode`, or "" — duck-typed via `hasproperty` since
# a `Pass` may carry no source across Julia versions, and only a FAILING check really needs it.
function _source_str(res)
    hasproperty(res, :source) || return ""
    s = getproperty(res, :source)
    (s isa LineNumberNode && s.file !== nothing) || return ""
    return string(basename(String(s.file)), ":", s.line)
end

# The SOURCE REGION that produced a test — its computation plus the assertion — read straight from the
# file at record time (it exists while the suite runs, in the sandbox too). By default this is the whole
# region since the PREVIOUS test in the same file (so consecutive tests do not repeat each other's
# setup), bounded to `_MAX_REGION_LINES` so a first test does not drag in a whole file's preamble.
const _MAX_REGION_LINES = 12
const _REGION_LAST = Dict{String,Int}()   # file → last test line consumed (reset per capture)
function _capture_region(res)
    hasproperty(res, :source) || return ""
    s = getproperty(res, :source)
    (s isa LineNumberNode && s.file !== nothing) || return ""
    file = String(s.file)
    line = s.line
    isfile(file) || return ""
    lines = try
        readlines(file)
    catch
        return ""
    end
    (1 <= line <= length(lines)) || return ""
    prev = get(_REGION_LAST, file, 0)
    from = max(1, line - _MAX_REGION_LINES + 1)
    (0 < prev < line) && (from = max(from, prev + 1))
    _REGION_LAST[file] = line
    return rstrip(join(lines[from:line], "\n"))
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

# The interface `Pinax.test` (docstring in src/testset.jl). In the EXTENSION, `PinaxTestSet` is an
# ordinary visible name, so the in-process form is a plain `@testset PinaxTestSet` — no gensym, no
# per-suite token; the suite the user writes is pure `@testset`.

# `Pinax.test(runtests)` — render a specific file in the CURRENT process (no sandbox): a capturing
# root, include, render. The root's `finish` renders and re-throws on a red suite.
function Pinax.test(
    runtests::AbstractString; out=report_out(), title::AbstractString=report_title()
)
    file = abspath(runtests)
    isfile(file) || error("Pinax.test: no such test file — $(file)")
    # A fresh `Module()` has NO module-local `include` / `eval` (unlike a `module … end`), so a
    # `runtests.jl` that `include`s its test files would hit `UndefVarError: include`. Define them.
    m = Module(gensym(:PinaxTest))
    Core.eval(m, :(include(p) = $(Base.include)($m, p)))
    Core.eval(m, :(eval(x) = $(Core.eval)($m, x)))
    empty!(_REGION_LAST)
    withenv("PINAX_TEST_OUT" => String(out), "PINAX_TEST_TITLE" => String(title)) do
        Test.@testset PinaxTestSet "$(title)" begin
            Base.include(m, file)
        end
    end
    return nothing
end

# The `Pkg.test`-delegation half (called by the `-L` preamble): push an UNBALANCED capturing root, so
# the suite's top-level `@testset` — which the preamble runs BEFORE — inherits it and records into it.
# Test never `finish`es our root, so its natural throw is suppressed; the atexit hook re-imposes the
# verdict via the process exit code.
function Pinax._install_test_capture!()
    # The `-L` preamble runs in EVERY `Pkg.test` subprocess. During precompilation (`generating_output`)
    # our side effects (`push_testset`, `atexit`) would break the cache image — and there is no suite to
    # capture there anyway — so install NOTHING then. The cache-flags probe is handled by the empty-root
    # guard in `_finalize_test_capture!` (it installs but renders nothing). Only the test run captures.
    Base.generating_output() && return nothing
    empty!(_REGION_LAST)
    root = PinaxTestSet(
        report_title(); out=report_out(), dump=report_dump(), title=report_title()
    )
    Test.push_testset(root)
    atexit(() -> _finalize_test_capture!(root))
    return nothing
end

function _finalize_test_capture!(root::PinaxTestSet)
    Test.get_testset_depth() > 0 && Test.pop_testset()
    # A `-L` preamble runs in EVERY `Pkg.test` subprocess — the cache-flags probe and precompile, not
    # just the test run — and those capture nothing. An empty root therefore means "not the test run":
    # do nothing (no render, no print, no exit) so their stdout stays clean for `Pkg` to parse.
    (isempty(root.children) && isempty(root.checks)) && return nothing
    if root.ignore
        nothing
    elseif !isempty(root.dump)
        dump_test_report(root, root.dump)
        println("\nPinax test report: ", _summary_line(root), "\n  dumped → ", root.dump)
    else
        render_test_report(root; out=root.out, title=root.title, page_when=root.page_when)
        println(
            "\nPinax test report: ",
            _summary_line(root),
            "\n  rendered → $(root.out)_html/  $(root.out)_agent/",
        )
    end
    nfail, nerr = _nfail(root), _nerror(root)
    (nfail + nerr > 0) && exit(1)   # red suite → nonzero exit (finish's throw can't fire in atexit)
    return nothing
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
