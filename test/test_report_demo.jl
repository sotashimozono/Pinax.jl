# test_report_demo.jl — a DEMONSTRATION, because Pinax's own `Pinax.test()` output IS the showcase of
# the test-report feature (the deployed self-report). It is plain `@testset`/`@test` — no Pinax token —
# but written so the rendered report exercises the pieces the bridge adds: a swept `@testset for` folded
# into a convergence figure + a tolerance-margin figure, and `@caption` naming the quantity. The
# assertions are genuine (a real convergent quadrature), so under a bare `Pkg.test()` this is an honest
# smoke test of the environment's floating point; under `Pinax.test()` it draws itself.
@testset "test_report_demo.jl" begin
    @desc md"The midpoint rule for the integral of 4/(1+x^2) on [0,1] converges to π as O(1/n²). The report shows the estimate approaching π and the tolerance budget shrinking — from the numbers the suite already computed, with no figure code."

    midpoint(n) = sum(k -> 4 / (1 + ((k - 0.5) / n)^2), 1:n) / n   # → π as n → ∞

    # An unnamed `@testset for` is a SAMPLE, not a section: these four iterations fold into ONE
    # convergence figure (got vs n, π as the reference, the tolerance as a band) plus a margin figure.
    # `@caption` names the quantity, so the figure is titled `midpoint rule → π`, not the raw expression.
    @testset for n in (8, 32, 128, 512)
        @test isapprox(midpoint(n), π; rtol=0.01)
        @caption "midpoint rule → π"
    end
end
