# Pinax.jl

> *A board of figures that is also a catalogue.*

Pinax turns the figures your analysis scripts produce into a structured, self-contained HTML
gallery — sections, markdown + math descriptions, cross-references, citations, and an interactive
comment layer — and can export the same manuscript to PDF via a LaTeX theme.

## Example: a gallery of chaotic attractors

The gallery linked below is built **live on this page** as a Documenter `@example`: it integrates
the Lorenz and Rössler systems from
[DynamicalModels.jl](https://github.com/sotashimozono/DynamicalModels.jl), plots them with `Plots`,
and renders a Pinax gallery — the same way you would in an analysis script.

```@example lorenz
using Pinax, DynamicalModels, Plots

# integrate two chaotic attractors (DynamicalModels.jl: model(t, x) -> dx/dt, RK4 solver)
t = collect(0.0:0.02:80.0)
lorenz  = ode_solver(RK4, Lorenz(),  t, [1.0, 1.0, 1.0])
rossler = ode_solver(RK4, Rossler(), t, [1.0, 1.0, 1.0])

# a small plot helper: project a trajectory onto two of its coordinates
proj(tr, i, j; kw...) = plot(tr[:, i], tr[:, j]; legend=false, lw=0.4, size=(480, 380), kw...)
nothing # hide
```

A figure is registered with `@figure`; its expression is **deferred** and materialized at render
time. The description is markdown + `$…$` math (rendered by KaTeX in the gallery):

```@example lorenz
Pinax.reset!(; title = "DynamicalModels.jl — chaotic attractors (Pinax demo)")

@page :attractors "Chaotic attractors" begin
    @section :lorenz "Lorenz" begin
        @desc md"""
        The **Lorenz** system $\dot x=\sigma(y-x),\ \dot y=x(\rho-z)-y,\ \dot z=xy-\beta z$
        with $\sigma=10,\ \rho=28,\ \beta=8/3$ — the classic butterfly attractor.
        """
        @figure proj(lorenz, 1, 3; xlabel="x", ylabel="z", title="Lorenz x–z")
        @caption md"$x$–$z$ projection"
        @figure proj(lorenz, 1, 2; xlabel="x", ylabel="y", title="Lorenz x–y")
        @caption md"$x$–$y$ projection"
    end
    @section :rossler "Rössler" begin
        @desc md"""
        The **Rössler** system $\dot x=-y-z,\ \dot y=x+ay,\ \dot z=b+z(x-c)$
        with $a=b=0.2,\ c=5.7$.
        """
        @figure proj(rossler, 1, 2; xlabel="x", ylabel="y", title="Rössler x–y")
        @caption md"$x$–$y$ projection"
    end
end

Pinax.render(; out = "gallery")   # writes build/gallery/index.html — deployed with these docs
nothing # hide
```

A preview of one panel, shown inline by Documenter:

```@example lorenz
proj(lorenz, 1, 3; xlabel="x", ylabel="z", title="Lorenz attractor (x–z)")
```

```@raw html
<p style="margin:1rem 0"><a href="gallery/index.html"><b>▶ Open the interactive Pinax gallery</b></a>
— sections, captions, KaTeX math, and the comment layer.</p>
```

## API

```@autodocs
Modules = [Pinax]
```
