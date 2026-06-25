# examples/ising_datavault.jl
#
# A small, self-contained DataVault + Pinax showcase. A 2D Ising Monte Carlo temperature sweep is
# stored in a DataVault, then read back to build a Pinax gallery — an M(T) phase-transition curve and
# an animated GIF of the spin lattice near Tc. It demonstrates the data layer (DataVault: persist +
# discover) feeding the presentation layer (Pinax, whose `render(; vault)` cache is data-aware via the
# PinaxDataVaultExt extension). Re-running skips keys already marked `:done`, so the heavy Monte Carlo
# runs once; the figures are rebuilt from the stored data.
#
#     julia --project=examples examples/ising_datavault.jl
#
# Any environment with Pinax + DataVault + ParamIO + Plots works (examples/Project.toml is one).
# Outputs land under examples/out/ by default (override with DATAVAULT_OUTDIR / PINAX_OUT):
# the gallery (human face), agent.json (LLM face), and a @benchmark verdict (the trust gate).

using Pinax, DataVault, ParamIO, Plots, Random, Statistics, Printf

ENV["GKSwstype"] = get(ENV, "GKSwstype", "100")   # headless GR (renders without a display)
gr()

# ---- the model: 2D Ising, Metropolis single-spin flips, periodic boundaries ----

function metropolis_sweep!(spins, β, rng)
    N = size(spins, 1)
    @inbounds for _ in 1:(N * N)
        i = rand(rng, 1:N)
        j = rand(rng, 1:N)
        nn =
            spins[mod1(i - 1, N), j] +
            spins[mod1(i + 1, N), j] +
            spins[i, mod1(j - 1, N)] +
            spins[i, mod1(j + 1, N)]
        ΔE = 2 * spins[i, j] * nn
        if ΔE <= 0 || rand(rng) < exp(-β * ΔE)
            spins[i, j] = -spins[i, j]
        end
    end
    return spins
end

magnetization(spins) = abs(sum(spins)) / length(spins)

function run_ising(T; N=32, sweeps=500, seed=1)
    rng = MersenneTwister(seed)
    β = 1 / T
    spins = fill(1, N, N)   # ordered start: stays ordered below Tc, disorders above → clean M(T)
    Ms = Float64[]
    frames = Matrix{Int}[]
    for s in 1:sweeps
        metropolis_sweep!(spins, β, rng)
        s > sweeps ÷ 2 && push!(Ms, magnetization(spins))   # measure over the second half
        s % 8 == 0 && push!(frames, copy(spins))            # snapshot every 8th sweep (for the GIF)
    end
    return (; M=mean(Ms), frames=frames)
end

# ---- compute: fill the vault (a re-run recomputes only the :pending keys) ----

const HERE = @__DIR__
const CONFIG = joinpath(HERE, "configs", "ising.toml")
const OUTDIR = get(ENV, "DATAVAULT_OUTDIR", joinpath(HERE, "out"))

vault = Vault(CONFIG; run="mc", outdir=OUTDIR)

println("=== 2D Ising Monte Carlo → DataVault ===")
for key in DataVault.keys(vault; status=:pending)
    T = Float64(key.params["system.T"])
    N = Int(key.params["system.N"])
    sweeps = Int(key.params["system.sweeps"])
    mark_running!(vault, key)
    @printf("  T = %.3f … ", T)
    res = run_ising(T; N=N, sweeps=sweeps)
    DataVault.save!(
        vault, key, Dict{String,Any}("T" => T, "M" => res.M, "frames" => res.frames)
    )
    mark_done!(vault, key; tag_value=res.M)
    @printf("M = %.3f\n", res.M)
end

# ---- read back from the vault to build the figures ----

done = sort(DataVault.keys(vault; status=:done); by=k -> Float64(k.params["system.T"]))
Ts = Float64[]
Ms = Float64[]
for key in done
    d = DataVault.load(vault, key)
    push!(Ts, d["T"])
    push!(Ms, d["M"])
end

const Tc = 2.269
key_tc = done[argmin(abs.(Ts .- Tc))]
T_tc = Float64(key_tc.params["system.T"])
frames_tc = DataVault.load(vault, key_tc)["frames"]

gifpath = joinpath(OUTDIR, "ising_spins.gif")
anim = @animate for f in frames_tc
    heatmap(
        f;
        c=:grays,
        clims=(-1, 1),
        axis=false,
        ticks=false,
        legend=false,
        aspect_ratio=1,
        title=@sprintf("Ising spins, T = %.2f", T_tc),
    )
end
gif(anim, gifpath; fps=12)

mtfig = plot(
    Ts,
    Ms;
    marker=:circle,
    legend=false,
    xlabel="temperature T",
    ylabel="|magnetization| per spin",
    title="2D Ising: M(T)",
)
vline!(mtfig, [Tc]; ls=:dash, c=:red)

# ---- the gallery: figures read from the vault, rendered with the data-aware cache ----

Pinax.reset!()
@page :ising "2D Ising — Monte Carlo" summary = "A Metropolis temperature sweep stored in a DataVault, read back into figures." begin
    @section :mag "Magnetization vs temperature" begin
        @desc md"Order parameter from the vault: the magnetization $|m|$ collapses through the critical temperature $T_c \approx 2.269$ (dashed line)."
        @figure mtfig caption = "Each point is one DataVault key (one temperature)."
    end
    @section :spins "Spin dynamics near Tc" layout = :wide begin
        @desc md"The raw spin snapshots stored in the vault, played back as an animation."
        @figure gifpath params = key_tc caption = "Spin lattice near \$T_c\$ — data-aware, so it re-renders only when this key's vault data changes."
    end
end

# A second page — the TEST SET (the trust gate). The same MC numbers, checked against the textbook
# Ising limits: this renders as a green/red test-report for a human AND a machine-checkable verdict in
# agent.json for an LLM, so "the MC looks right" becomes a checked PASS/FAIL instead of a guess.
@benchmark :validation "Ising sanity — M(T) vs known limits" begin
    @desc md"The Monte Carlo must reproduce the textbook limits: ordered (\$|m|\to 1\$) well below \$T_c\$, disordered (finite-size residual) well above."
    @expect "M_ordered" "low-T |m| (ordered phase)" got = Ms[1] want = 1.0 tol = 0.2
    @expect "M_disordered" "high-T |m| (residual)" got = Ms[end] want = 0.0 tol = 0.3
    @expect "transition" "drops through Tc" got = Ms[1] - Ms[end] want = 0.8 tol = 0.45
end

# Render the TWO faces of the SAME doc — pixels for a human, data (+ the verdict) for an LLM.
out = get(ENV, "PINAX_OUT", joinpath(OUTDIR, "gallery"))
gallery = render(; out=out, vault=vault, study="mc")                                     # human face
agentp = render(; out=joinpath(OUTDIR, "agent"), vault=vault, study="mc", theme=:agent)  # LLM face

println("\n— the two faces of the same result —")
println("  human (gallery): ", gallery)
println("  LLM   (agent):   ", agentp)
ajfile = endswith(agentp, ".json") ? agentp : joinpath(agentp, "agent.json")
if isfile(ajfile)
    v = match(r"\"verdict\":\"([A-Z]+)\"", read(ajfile, String))
    v === nothing ||
        println("  benchmark verdict (what the LLM reads, not a println): ", v.captures[1])
end
println("  vault:           ", vault.outdir)
