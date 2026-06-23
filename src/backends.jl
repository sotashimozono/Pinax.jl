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
    # flatten newlines so a value never spans CSV lines (the reader splits on raw newlines)
    s = replace(string(v), '\n' => ' ', '\r' => ' ')
    needs = occursin(',', s) || occursin('"', s)
    return needs ? string('"', replace(s, '"' => "\"\""), '"') : s
end
_csv_num(v::Real) = isfinite(v) ? string(v) : ""   # NaN/Inf -> blank cell
_csv_num(v) = _csv_field(v)                         # categorical x (strings/dates)

# Choose <= `budget` indices of `ys` that PRESERVE SHAPE: per contiguous bucket keep the min-y and
# max-y points (plus the two endpoints), so peaks/troughs survive — unlike a uniform stride, which can
# step straight over a sharp feature. The LLM reads this data, so a dropped peak is a wrong read.
# Non-finite / non-numeric y degrades to the bucket's first point (≈ uniform).
function _pick_indices(ys, budget::Int)
    n = length(ys)
    n <= budget && return collect(1:n)
    nb = max(1, budget ÷ 2)                        # 2 points/bucket (its min and its max)
    keep = Set{Int}((1, n))                        # always keep the endpoints
    asnum(v) = (v isa Real && isfinite(v)) ? Float64(v) : nothing
    for k in 1:nb
        lo = 1 + ((k - 1) * n) ÷ nb
        hi = (k * n) ÷ nb
        lo > hi && continue
        imin = imax = lo
        vmin = vmax = nothing
        for i in lo:hi
            v = asnum(ys[i])
            v === nothing && continue
            (vmin === nothing || v < vmin) && (vmin=v; imin=i)
            (vmax === nothing || v > vmax) && (vmax=v; imax=i)
        end
        push!(keep, imin, imax)
    end
    return sort!(collect(keep))
end

# Long-format CSV (series,x,y). Each series is **shape-preservingly** downsampled to <= `maxrows`
# points (min/max per bucket — peaks survive) so a dense plot stays cheap AND faithful to read.
function _print_csv_table(io, tbl, maxrows::Int)
    xl = get(tbl, :xlabel, "")
    yl = get(tbl, :ylabel, "")
    reduced = any(s -> min(length(s.x), length(s.y)) > maxrows, tbl.series)
    note =
        reduced ? " (downsampled: shape-preserving min/max, <= $(maxrows) pts/series)" : ""
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
        for i in _pick_indices(view(s.y, 1:n), maxrows)
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

# Split one CSV line into fields, honoring "quoted" fields and "" escapes (inverse of `_csv_field`).
function _split_csv_line(line)
    fields = String[]
    buf = IOBuffer()
    inq = false
    chars = collect(line)
    i = 1
    while i <= length(chars)
        ch = chars[i]
        if inq
            if ch == '"'
                if i < length(chars) && chars[i + 1] == '"'
                    print(buf, '"')
                    i += 1
                else
                    inq = false
                end
            else
                print(buf, ch)
            end
        elseif ch == '"'
            inq = true
        elseif ch == ','
            push!(fields, String(take!(buf)))
        else
            print(buf, ch)
        end
        i += 1
    end
    push!(fields, String(take!(buf)))
    return fields
end

# Read a Pinax figure-data CSV back into (header, rows, total) for the agent backend's "figure as a
# table" view — the plot object is gone after materialize, but this CSV asset persists across the
# cache. Numeric cells are re-typed; `rows` is downsampled to <= `maxrows` (a cheap inline preview).
function _read_csv_table(path; maxrows::Int=20)
    isfile(path) || return nothing
    lines = [l for l in readlines(path) if !isempty(l) && !startswith(l, "#")]
    isempty(lines) && return nothing
    # col 1 is the (categorical) series label — keep it a String; numeric columns are re-typed, and a
    # blank cell (a NaN/Inf the writer dropped) becomes `missing` (-> JSON null), not the string "".
    cell(j, s) = j == 1 ? s : (isempty(s) ? missing : something(tryparse(Float64, s), s))
    header = _split_csv_line(lines[1])
    allrows = Vector{Any}[
        (f=_split_csv_line(l); Any[cell(j, f[j]) for j in eachindex(f)]) for
        l in @view lines[2:end]
    ]
    return (header=header, rows=_downsample_rows(allrows, maxrows), total=length(allrows))
end

# Downsample long-format (label,x,y) rows to <= `budget`, shape-preservingly PER SERIES (so a peak in
# any one series survives). Groups by the series label (col 1) and keeps min/max-per-bucket on y (col 3).
function _downsample_rows(rows, budget::Int)
    length(rows) <= budget && return rows
    groups = Dict{Any,Vector{Int}}()
    order = Any[]
    for (i, r) in enumerate(rows)
        haskey(groups, r[1]) || push!(order, r[1])
        push!(get!(groups, r[1], Int[]), i)
    end
    nseries = length(order)
    # more series than the budget can afford min+max for → per-series shape preservation is moot;
    # fall back to a uniform stride over all rows so the <= budget bound still holds.
    2 * nseries > budget && return rows[1:cld(length(rows), budget):length(rows)]
    per = max(2, budget ÷ nseries)
    keep = Int[]
    for lbl in order
        gidx = groups[lbl]
        for p in _pick_indices(Any[rows[i][3] for i in gidx], per)
            push!(keep, gidx[p])
        end
    end
    sort!(unique!(keep))
    return rows[keep]
end

# Normalize a `@figure … data=` NamedTuple into a list of `(; label, x, y)` series. Accepts the
# `_figure_table` shape `(; series=[(; label, x, y)], …)` or a convenience `(; x, y[, label])`.
function _series_of(data)
    if hasproperty(data, :series)
        out = NamedTuple[]
        for (i, s) in enumerate(data.series)
            lbl = hasproperty(s, :label) ? string(s.label) : "y$(i)"
            push!(out, (; label=lbl, x=s.x, y=s.y))
        end
        return out
    elseif hasproperty(data, :x) && hasproperty(data, :y)
        lbl = hasproperty(data, :label) ? string(data.label) : "y"
        return [(; label=lbl, x=data.x, y=data.y)]
    end
    return error(
        "Pinax: @figure data= needs `series=[(; label, x, y)]` or `(; x, y[, label])`."
    )
end

# Eager `data=` → the same `(header, rows, total)` long-format the agent backend gets from a
# materialized CSV — but WITHOUT building the plot (no plotting backend needed). Numeric `x`/`y`
# stay native (the agent JSON emits typed rows); `rows` is shape-preservingly downsampled to <= `maxrows`.
function _table_from_data(data; maxrows::Int=20)
    rows = Vector{Any}[]
    for s in _series_of(data)
        n = min(length(s.x), length(s.y))
        for i in 1:n
            push!(rows, Any[s.label, s.x[i], s.y[i]])
        end
    end
    return (
        header=["series", "x", "y"],
        rows=_downsample_rows(rows, maxrows),
        total=length(rows),
    )
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
