# # Example gallery
#
# This is the Pinax script that builds the gallery linked above. It assembles three independent
# examples as three `@page`s of one document; because the document has several pages, Pinax renders
# it as a **thumbnail index plus one HTML page per `@page`**. The script is shown verbatim — running
# it (with the libraries below installed) reproduces the gallery exactly.
#
# Sources: [DynamicalModels.jl](https://github.com/sotashimozono/DynamicalModels.jl),
# [LSystems.jl](https://github.com/sotashimozono/LSystems.jl), and a self-contained Ising model.

using Pinax, DynamicalModels, LSystems, Plots, Random

# ## Example 1 — chaotic attractors (DynamicalModels.jl)
t = collect(0.0:0.02:80.0)
lorenz = ode_solver(RK4, Lorenz(), t, [1.0, 1.0, 1.0])
rossler = ode_solver(RK4, Rossler(), t, [1.0, 1.0, 1.0])
function orbit3d(tr; kw...)
    plot(tr[:, 1], tr[:, 2], tr[:, 3]; legend=false, lw=0.4, size=(420, 360), kw...)
end
function proj(tr, i, j; kw...)
    plot(tr[:, i], tr[:, j]; legend=false, lw=0.4, size=(420, 360), kw...)
end

# ## Example 2 — L-system fractals (LSystems.jl)
function lsys(name, iter; kw...)
    tile = DEFINED_LSYSTEMS[name]
    pos = LSystems.string2positions(tile, grow_string(tile, iter))
    plot(
        [p[1] for p in pos],
        [p[2] for p in pos];
        legend=false,
        aspect_ratio=:equal,
        axis=false,
        ticks=false,
        grid=false,
        lw=0.6,
        size=(380, 380),
        kw...,
    )
end

# ## Example 3 — 2-D Ising Monte Carlo (self-contained)
function sweep!(s, β)
    L = size(s, 1)
    @inbounds for _ in 1:(L * L)
        i = rand(1:L)
        j = rand(1:L)
        nb =
            s[mod1(i-1, L), j] +
            s[mod1(i+1, L), j] +
            s[i, mod1(j-1, L)] +
            s[i, mod1(j+1, L)]
        dE = 2 * s[i, j] * nb
        (dE <= 0 || rand() < exp(-β * dE)) && (s[i, j] = -s[i, j])
    end
    return s
end
function run_ising(L, T; equil, measure)
    s = rand((Int8(-1), Int8(1)), L, L)
    β = 1 / T
    for _ in 1:equil
        sweep!(s, β)
    end
    m = 0.0
    for _ in 1:measure
        sweep!(s, β)
        m += abs(sum(Int, s)) / (L * L)
    end
    return s, m / measure
end
Random.seed!(20240620)
function snap(T)
    heatmap(
        run_ising(64, T; equil=600, measure=1)[1];
        aspect_ratio=:equal,
        c=:grays,
        axis=false,
        ticks=false,
        colorbar=false,
        size=(360, 360),
        title="T = $T",
    )
end
Tc = 2 / log(1 + sqrt(2))

# ## The manuscript: one `@page` per example
Pinax.reset!(; title="Pinax example gallery")

@page :attractors "Chaotic attractors" begin
    @section :lorenz "Lorenz" begin
        @desc md"""
        The **Lorenz** system $\dot x=\sigma(y-x),\ \dot y=x(\rho-z)-y,\ \dot z=xy-\beta z$
        with $\sigma=10,\ \rho=28,\ \beta=8/3$.
        """
        @figure orbit3d(lorenz; xlabel="x", ylabel="y", zlabel="z", title="Lorenz 3-D")
        @caption md"3-D attractor"
        @figure proj(lorenz, 1, 3; xlabel="x", ylabel="z", title="x–z")
        @caption md"$x$–$z$ projection"
        @figure proj(lorenz, 1, 2; xlabel="x", ylabel="y", title="x–y")
        @caption md"$x$–$y$ projection"
    end
    @section :rossler "Rössler" begin
        @desc md"The **Rössler** system $\dot x=-y-z,\ \dot y=x+ay,\ \dot z=b+z(x-c)$ ($a=b=0.2,\ c=5.7$)."
        @figure orbit3d(rossler; xlabel="x", ylabel="y", zlabel="z", title="Rössler 3-D")
        @caption md"3-D attractor"
        @figure proj(rossler, 1, 2; xlabel="x", ylabel="y", title="x–y")
        @caption md"$x$–$y$ projection"
    end
end

@page :fractals "L-system fractals" begin
    @section :koch "Koch & Sierpiński" begin
        @desc md"Boundary fractals: Koch $D=\log4/\log3$, Sierpiński $D=\log3/\log2$."
        @figure lsys("kochcurve", 4; title="Koch curve", lc=:steelblue)
        @caption "Koch curve"
        @figure lsys("kocksnowflake", 4; title="Koch snowflake", lc=:steelblue)
        @caption "Koch snowflake"
        @figure lsys("sierpinskigasket", 6; title="Sierpiński", lc=:seagreen)
        @caption "Sierpiński gasket"
    end
    @section :curves "Dragons, space-filling & plants" begin
        @desc md"A dragon, a space-filling curve, and a bracketed branching plant."
        @figure lsys("heighwaydragon", 11; title="Heighway dragon", lc=:firebrick)
        @caption "Heighway dragon"
        @figure lsys("hilbeltpath", 5; title="Hilbert curve", lc=:darkorange)
        @caption "Hilbert curve"
        @figure lsys("ternarybranching", 6; title="Ternary branching", lc=:seagreen)
        @caption "Ternary branching"
    end
end

@page :ising "Ising model (Monte Carlo)" begin
    @section :snapshots "Spin configurations" begin
        @desc md"Equilibrated $64\times64$ states across $T_c\approx2.269$: ordered, critical, disordered."
        @figure snap(1.5)
        @caption md"$T<T_c$ — ordered"
        @figure snap(2.27)
        @caption md"$T\approx T_c$ — critical"
        @figure snap(3.5)
        @caption md"$T>T_c$ — disordered"
    end
    @section :magnetization "Magnetization curve" begin
        @desc md"Order parameter $\langle\lvert m\rvert\rangle(T)$ with the Onsager $T_c$ marked."
        @figure begin
            Ts = collect(1.0:0.2:3.6)
            Ms = [run_ising(40, T; equil=400, measure=500)[2] for T in Ts]
            plot(
                Ts,
                Ms;
                marker=:circle,
                lw=1.5,
                label="⟨|m|⟩",
                xlabel="T",
                ylabel="⟨|m|⟩",
                size=(560, 380),
            )
            vline!([Tc]; ls=:dash, lc=:red, label="Tc ≈ 2.269")
        end
        @caption md"$\langle\lvert m\rvert\rangle$ vs $T$"
    end
end

# Render: a multi-page document → a thumbnail index + one page per `@page`.
Pinax.render(; out="gallery")
