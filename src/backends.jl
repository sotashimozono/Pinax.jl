# backends.jl — figure backend abstraction (notes 04). The core is plotting-agnostic.
#
# The contract is just two verbs:
#   is_figure(x)            … is x a backend figure object? (Plots/Makie ext sets this true)
#   pinax_save(x, base, fmt) … save the figure to base.<fmt>, return the actual path (ext implements)
# Pre-made file paths are handled directly by the core (no extension needed, notes 04).

"Is `x` a backend figure object? Defaults to false (Plots/Makie ext overrides)."
is_figure(::Any) = false

"""
    pinax_save(x, base, fmt) -> path

Save the figure object `x` to `base` (an extensionless base path) in `fmt` (:svg/:pdf/…)
and return the actual path. Per-backend implementations are injected via package
extensions (weakdeps) (notes 04).
"""
function pinax_save(x, base, fmt)
    return error(
        "Pinax: no `pinax_save` method for $(typeof(x)). " *
        "Pass a file path, or load the Plots/Makie extension.",
    )
end

"""
    _figure_table(x) -> table | nothing

Extract a backend figure's plotted data for the agent backend's text/CSV view — an LLM reasons over
numbers far more cheaply and precisely than over pixels. Returns `nothing` when the data is not
introspectable (a pre-made image path, or a plot the loaded extension can't read); plotting
extensions specialize it. Return shape: `(; xlabel, ylabel, series)`, each series `(; label, x, y)`.
"""
_figure_table(::Any) = nothing

"""
    _save_with(saver, obj, base, fmt) -> path

Helper for backend extensions. Builds the destination path `base.<fmt>`, ensures its
directory exists, runs `saver(obj, dest)` — the contract is **`(obj, dest)`: figure first,
path second** — verifies a file was actually written, and returns it.
"""
function _save_with(saver, obj, base, fmt)
    dest = string(base, ".", fmt)
    dir = dirname(dest)
    isempty(dir) || mkpath(dir)
    saver(obj, dest)
    isfile(dest) || error("Pinax: backend save produced no file at $(dest)")
    return dest
end

_ext(p) = (e=splitext(p)[2]; isempty(e) ? "" : lowercase(e[2:end]))

# Pre-made file (first-class): same-format copy (v1 has no conversion, notes 04).
function _copyfile(src::AbstractString, base)
    isfile(src) || error("Pinax: @figure file not found: $(src)")
    ext = _ext(src)
    dest = isempty(ext) ? string(base) : string(base, ".", ext)
    mkpath(dirname(dest))
    cp(src, dest; force=true)
    return dest
end

# ---- data-table emit: the agent backend's text view of a figure's plotted data ----

function _csv_field(v)
    s = string(v)
    needs = occursin(',', s) || occursin('"', s) || occursin('\n', s)
    return needs ? string('"', replace(s, '"' => "\"\""), '"') : s
end
_csv_num(v::Real) = isfinite(v) ? string(v) : ""   # NaN/Inf -> blank cell
_csv_num(v) = _csv_field(v)                         # categorical x (strings/dates)

# Long-format CSV (series,x,y). Each series is uniformly downsampled to <= `maxrows` points (a header
# comment records the reduction) so a dense plot stays cheap to read.
function _print_csv_table(io, tbl, maxrows::Int)
    xl = get(tbl, :xlabel, "")
    yl = get(tbl, :ylabel, "")
    reduced = any(s -> min(length(s.x), length(s.y)) > maxrows, tbl.series)
    note = reduced ? " (downsampled: uniform stride, <= $(maxrows) pts/series)" : ""
    println(
        io,
        "# pinax figure data — xlabel=",
        _csv_field(xl),
        " ylabel=",
        _csv_field(yl),
        note,
    )
    println(io, "series,x,y")
    for s in tbl.series
        n = min(length(s.x), length(s.y))
        step = n > maxrows ? cld(n, maxrows) : 1
        for i in 1:step:n
            println(io, _csv_field(s.label), ",", _csv_num(s.x[i]), ",", _csv_num(s.y[i]))
        end
    end
    return nothing
end

# Write a figure's plotted data as `<base>.csv`, or return `nothing` if it exposes none.
function _write_table(x, base; maxrows::Int=2000)
    tbl = _figure_table(x)
    tbl === nothing && return nothing
    dest = string(base, ".csv")
    mkpath(dirname(dest))
    open(io -> _print_csv_table(io, tbl, maxrows), dest, "w")
    return dest
end

"""
    _materialize(fig, base, fmts) -> Vector{String}

Call the deferred `fig.gen` **exactly once** to produce the figure, write the assets,
and return their paths (notes 02 pass 3). Figure objects are saved per `fmt` via
`pinax_save`; an existing file path is copied (the file must exist when `gen()` returns).
"""
function _materialize(fig::Figure, base, fmts)
    x = fig.gen()
    if is_figure(x)
        out = String[]
        for fmt in fmts
            # `:table` is a pseudo-format: a CSV of the plotted data, not an image (skipped when the
            # figure exposes no introspectable data, e.g. a Makie scene the ext can't read).
            path = fmt === :table ? _write_table(x, base) : pinax_save(x, base, fmt)
            path === nothing || push!(out, path)
        end
        return out
    elseif x isa AbstractString
        return String[_copyfile(x, base)]
    else
        error(
            "Pinax: @figure produced $(typeof(x)); expected a file path or a known plot " *
            "(load the Plots/Makie extension).",
        )
    end
end
