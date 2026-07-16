# # Test → Pinax
#
# A test suite reports **one bit**: green or red. That bit throws away almost everything the suite
# knew — a `@test isapprox(E, oracle; rtol=1e-3)` *computed* `E`, the reference, and the tolerance,
# then printed a checkmark and discarded all three. A check sitting at 97 % of its tolerance is one
# refactor from red, yet the badge shows the same green as a rock-solid one.
#
# Pinax provides an interface that **outputs a testset directly** as a document — one page per test
# file, each check shown with the margin it passed by (`delta / tol`). The report linked at the top of
# this page is that interface run on a small slice of **Pinax's own tests** — the very file below.
#
# ## The interface: `Pinax.test`
#
# The suite stays **plain `@testset` / `@test`** — there is no Pinax-specific macro to add to it. The
# one Pinax touch is the *call*: instead of letting `Pkg.test` include the suite, you call
#
# ```julia
# Pinax.test("test/runtests.jl"; out = "report")   # writes report_html/ + report_agent/
# ```
#
# It opens a capturing root testset, includes the suite (nested `@testset`s inherit it — nothing to
# annotate), renders the document, and re-throws on a red suite so the verdict is never changed. With
# the report machinery absent, the same file runs untouched under a bare `Pkg.test()`.
#
# Below is the slice of Pinax's own tests that produced the linked report. It is ordinary `@testset` /
# `@test`; it *also* uses `@desc` — a manuscript macro — to caption a section, which the report picks
# up but which never touches the verdict.

using Pinax, Test

@testset "margins.jl" begin
    @desc md"""A `Check` keeps `got` / `want` / `tol`, so the report shows the *margin* each test
               passed by. The two checks below both pass, but one is a refactor from red and the
               other is rock-solid — indistinguishable on a green badge, obvious here."""

    solid = Pinax.Check(
        :energy,
        "ground-state energy",
        -1.2731,
        -1.2735,
        abs(-1.2731 + 1.2735) / 1.2735,
        0.01,
        :rel,
        true,
    )
    @test solid.pass
    @test solid.delta / solid.tol < 0.1            # spent < 10 % of its tolerance

    tight = Pinax.Check(
        :gap,
        "excitation gap",
        0.4122,
        0.4102,
        abs(0.4122 - 0.4102) / 0.4102,
        0.005,
        :rel,
        true,
    )
    @test tight.pass
    @test tight.delta / tight.tol > 0.9            # passed, but spent ~97 % of its budget
end

@testset "recovery.jl" begin
    @desc md"An `@test isapprox(got, want; rtol)` is enough — the bridge recovers the numbers the
             assertion actually compared, so the page is legible with no figure code at all."
    @test isapprox(-0.10203402715213993, -0.10242223073749557; rtol=0.01)
end

# ## What you get
#
# Each test *file* (a `.jl`-named `@testset`) becomes a `status = :benchmark` page; each `@test` a
# `Check` carrying its real numbers; and the whole thing renders to three backends from one document:
# `:gallery` (human), `:agent` (`agent.json`, for a reviewing agent), and `:latex`. Sharded CI needs
# nothing extra — each shard dumps its tree and one later job merges the dumps and renders once, so the
# shard boundary never appears in the output.
