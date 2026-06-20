# # Example gallery
#
# This is the Pinax script that builds the gallery linked above. It assembles three independent
# examples as three `@page`s of one document; because the document has several pages, Pinax renders
# it as a **thumbnail index plus one HTML page per `@page`**. The script is shown verbatim — running
# it (with the libraries below installed) reproduces the gallery exactly.
#
# Sources: [DynamicalModels.jl](https://github.com/sotashimozono/DynamicalModels.jl),
# [LSystems.jl](https://github.com/sotashimozono/LSystems.jl), and a self-contained Ising model.

using Pinax, DynamicalModels, LSystems, Plots, Random, DataVault, Statistics

# ## Example 1 — chaotic attractors (DynamicalModels.jl)
t = collect(0.0:0.02:80.0)
lorenz = ode_solver(RK4, Lorenz(), t, [1.0, 1.0, 1.0])
rossler = ode_solver(RK4, Rossler(), t, [1.0, 1.0, 1.0])
function orbit3d(tr; kw...)
    return plot(tr[:, 1], tr[:, 2], tr[:, 3]; legend=false, lw=0.4, size=(420, 360), kw...)
end
function proj(tr, i, j; kw...)
    return plot(tr[:, i], tr[:, j]; legend=false, lw=0.4, size=(420, 360), kw...)
end

# ## Example 2 — L-system fractals (LSystems.jl)
function lsys(name, iter; kw...)
    tile = DEFINED_LSYSTEMS[name]
    pos = LSystems.string2positions(tile, grow_string(tile, iter))
    return plot(
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

# ## Example 3 — 2-D Ising Monte Carlo, stored in a DataVault
# The temperature sweep is computed once into a DataVault (data + `.done` markers + `log.toml`
# discovery); the figures are read back from the vault, and `render(; vault)` makes the cache
# data-aware. Re-running recomputes only the keys still marked `:pending`.
function ising_sweep!(s, β)
    L = size(s, 1)
    @inbounds for _ in 1:(L * L)
        i, j = rand(1:L), rand(1:L)
        nb =
            s[mod1(i - 1, L), j] +
            s[mod1(i + 1, L), j] +
            s[i, mod1(j - 1, L)] +
            s[i, mod1(j + 1, L)]
        dE = 2 * s[i, j] * nb
        (dE <= 0 || rand() < exp(-β * dE)) && (s[i, j] = -s[i, j])
    end
    return s
end
function run_ising(T; L=32, sweeps=500)
    s = fill(Int8(1), L, L)                       # ordered start → a clean M(T)
    β, Ms, frames = 1 / T, Float64[], Matrix{Int8}[]
    for k in 1:sweeps
        ising_sweep!(s, β)
        k > sweeps ÷ 2 && push!(Ms, abs(sum(Int, s)) / (L * L))   # measure over the second half
        k % 8 == 0 && push!(frames, copy(s))                      # snapshot for the gif
    end
    return (; M=mean(Ms), frames=frames)
end

Random.seed!(20240620)
Tc = 2 / log(1 + sqrt(2))

# a tiny config drives the sweep: T names the on-disk directory
isingcfg = joinpath(tempdir(), "ising.toml")
write(
    isingcfg,
    """
    [study]
    project_name  = "ising2d"
    total_samples = 1
    outdir        = "ising_data"

    [datavault]
    path_keys = ["system.T"]

    [[paramsets]]

    [paramsets.system]
    T = [1.6, 2.0, 2.27, 2.5, 3.2]
    """,
)

vault = DataVault.Vault(isingcfg; run="mc")
for key in DataVault.keys(vault; status=:pending)
    T = Float64(key.params["system.T"])
    DataVault.mark_running!(vault, key)
    r = run_ising(T)
    DataVault.save!(
        vault, key, Dict{String,Any}("T" => T, "M" => r.M, "frames" => r.frames)
    )
    DataVault.mark_done!(vault, key; tag_value=r.M)
end

# read the sweep back from the vault to build the figures
done = sort(DataVault.keys(vault; status=:done); by=k -> Float64(k.params["system.T"]))
Ts = [DataVault.load(vault, k)["T"] for k in done]
Ms = [DataVault.load(vault, k)["M"] for k in done]
key_tc = done[argmin(abs.(Ts .- Tc))]

isinggif = joinpath("gallery_media", "ising_spins.gif")
mkpath(dirname(isinggif))
isinganim = @animate for f in DataVault.load(vault, key_tc)["frames"]
    heatmap(
        f;
        c=:grays,
        clims=(-1, 1),
        axis=false,
        ticks=false,
        legend=false,
        aspect_ratio=1,
        size=(360, 360),
    )
end
gif(isinganim, isinggif; fps=12)

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

@page :ising "Ising model (Monte Carlo, via DataVault)" begin
    @section :magnetization "Magnetization vs temperature" begin
        @desc md"Order parameter read back from the vault: $\langle\lvert m\rvert\rangle$ collapses through the Onsager $T_c\approx2.269$ (dashed)."
        @figure begin
            plot(
                Ts,
                Ms;
                marker=:circle,
                lw=1.5,
                legend=false,
                xlabel="T",
                ylabel="⟨|m|⟩",
                size=(560, 380),
            )
            vline!([Tc]; ls=:dash, lc=:red)
        end
        @caption md"each point is one DataVault key (one temperature)"
    end
    @section :dynamics "Spin dynamics near Tc" layout = :wide begin
        @desc md"The raw spin snapshots stored in the vault, played back as an animation."
        @figure isinggif params = key_tc
        @caption md"spin lattice near $T_c$ — data-aware (re-rendered only if this key's vault data changes)"
    end
end

# Render: a multi-page document → a thumbnail index + one page per `@page`. Passing the `vault` makes
# the cache data-aware (re-materialize a figure when its vault data changes) and records provenance.
Pinax.render(; out="gallery", vault=vault, study="mc")
