# Examples

Every example here is built **live** with Pinax: compute something, describe a manuscript with
`@page` / `@section` / `@figure`, then `render`.

The page below assembles all three examples into a **single Pinax document with three pages** and
renders one gallery. Because it is one document, Pinax's own **Contents** panel becomes a map of
contents across everything — there is no hand-written index here, it is just what Pinax emits when
you give it more than one page. Open the gallery to see it.

```@example moc
using Pinax, DynamicalModels, LSystems, Plots, Random

# Example 1 — chaotic attractors (DynamicalModels.jl)
t = collect(0.0:0.02:80.0)
lorenz  = ode_solver(RK4, Lorenz(),  t, [1.0, 1.0, 1.0])
rossler = ode_solver(RK4, Rossler(), t, [1.0, 1.0, 1.0])
orbit3d(tr; kw...) = plot(tr[:, 1], tr[:, 2], tr[:, 3]; legend=false, lw=0.4, size=(420, 360), kw...)
proj(tr, i, j; kw...) = plot(tr[:, i], tr[:, j]; legend=false, lw=0.4, size=(420, 360), kw...)

# Example 2 — L-system fractals (LSystems.jl)
function lsys(name, it; kw...)
    tile = DEFINED_LSYSTEMS[name]
    p = LSystems.string2positions(tile, grow_string(tile, it))
    plot([q[1] for q in p], [q[2] for q in p]; legend=false, aspect_ratio=:equal,
         axis=false, ticks=false, grid=false, lw=0.6, size=(380, 380), kw...)
end

# Example 3 — 2-D Ising Monte Carlo (self-contained)
function sweep!(s, β)
    L = size(s, 1)
    @inbounds for _ in 1:L*L
        i = rand(1:L); j = rand(1:L)
        nb = s[mod1(i-1,L), j] + s[mod1(i+1,L), j] + s[i, mod1(j-1,L)] + s[i, mod1(j+1,L)]
        dE = 2 * s[i, j] * nb
        (dE <= 0 || rand() < exp(-β * dE)) && (s[i, j] = -s[i, j])
    end
end
function run_ising(L, T; equil, measure)
    s = rand((Int8(-1), Int8(1)), L, L); β = 1 / T; m = 0.0
    for _ in 1:equil; sweep!(s, β); end
    for _ in 1:measure; sweep!(s, β); m += abs(sum(Int, s)) / (L * L); end
    return s, m / measure
end
Random.seed!(20240620)
snap(T) = heatmap(run_ising(64, T; equil=600, measure=1)[1]; aspect_ratio=:equal, c=:grays,
                  axis=false, ticks=false, colorbar=false, size=(360, 360), title="T = $T")
Tc = 2 / log(1 + sqrt(2))
nothing # hide
```

```@example moc
Pinax.reset!(; title = "Pinax example gallery")

@page :attractors "Chaotic attractors" begin
    @section :lorenz "Lorenz" begin
        @desc md"Lorenz $\dot x=\sigma(y-x),\ \dot y=x(\rho-z)-y,\ \dot z=xy-\beta z$ ($\sigma=10,\rho=28,\beta=8/3$)."
        @figure orbit3d(lorenz; title="Lorenz 3-D"); @caption "3-D attractor"
        @figure proj(lorenz, 1, 3; title="x–z"); @caption md"$x$–$z$"
        @figure proj(lorenz, 1, 2; title="x–y"); @caption md"$x$–$y$"
    end
    @section :rossler "Rössler" begin
        @desc md"Rössler $\dot x=-y-z,\ \dot y=x+ay,\ \dot z=b+z(x-c)$ ($a=b=0.2,c=5.7$)."
        @figure orbit3d(rossler; title="Rössler 3-D"); @caption "3-D attractor"
        @figure proj(rossler, 1, 2; title="x–y"); @caption md"$x$–$y$"
        @figure proj(rossler, 2, 3; title="y–z"); @caption md"$y$–$z$"
    end
end

@page :fractals "L-system fractals" begin
    @section :koch "Koch & Sierpiński" begin
        @desc md"Boundary fractals: Koch $D=\log4/\log3$, Sierpiński $D=\log3/\log2$."
        @figure lsys("kochcurve", 4; title="Koch curve", lc=:steelblue); @caption "Koch curve"
        @figure lsys("kocksnowflake", 4; title="Koch snowflake", lc=:steelblue); @caption "Koch snowflake"
        @figure lsys("sierpinskigasket", 6; title="Sierpiński", lc=:seagreen); @caption "Sierpiński gasket"
    end
    @section :curves "Dragons, space-filling & plants" begin
        @desc md"A dragon, a space-filling curve, and a bracketed branching plant."
        @figure lsys("heighwaydragon", 11; title="Heighway dragon", lc=:firebrick); @caption "Heighway dragon"
        @figure lsys("hilbeltpath", 5; title="Hilbert curve", lc=:darkorange); @caption "Hilbert curve"
        @figure lsys("ternarybranching", 6; title="Branching", lc=:seagreen); @caption "Ternary branching"
    end
end

@page :ising "Ising model (Monte Carlo)" begin
    @section :snapshots "Spin configurations" begin
        @desc md"Equilibrated $64\times64$ states across $T_c\approx2.269$."
        @figure snap(1.5); @caption md"$T<T_c$ — ordered"
        @figure snap(2.27); @caption md"$T\approx T_c$ — critical"
        @figure snap(3.5); @caption md"$T>T_c$ — disordered"
    end
    @section :magnetization "Magnetization curve" begin
        @desc md"Order parameter $\langle\lvert m\rvert\rangle(T)$ with the Onsager $T_c$ marked."
        @figure begin
            Ts = collect(1.0:0.2:3.6)
            Ms = [run_ising(40, T; equil=400, measure=500)[2] for T in Ts]
            plot(Ts, Ms; marker=:circle, lw=1.5, label="⟨|m|⟩", xlabel="T", ylabel="⟨|m|⟩", size=(560, 380))
            vline!([Tc]; ls=:dash, lc=:red, label="Tc ≈ 2.269")
        end
        @caption md"$\langle\lvert m\rvert\rangle$ vs $T$"
    end
end

Pinax.render(; out = "galleries/all")
nothing # hide
```

```@raw html
<p style="margin:1rem 0"><a href="../galleries/all/"><b>▶ Open the gallery</b></a> — its <b>Contents</b> panel is the map of contents across all three examples, generated by Pinax.</p>
```

## Walkthroughs

Each example also has its own page with the source and a step-by-step walkthrough:

- [1 · Chaotic attractors](examples/attractors.md) — [DynamicalModels.jl](https://github.com/sotashimozono/DynamicalModels.jl)
- [2 · L-system fractals](examples/lsystems.md) — [LSystems.jl](https://github.com/sotashimozono/LSystems.jl)
- [3 · Ising model (Monte Carlo)](examples/ising.md) — self-contained
