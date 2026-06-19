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
function pinax_save end
function pinax_save(x, base, fmt)
    return error(
        "Pinax: no `pinax_save` method for $(typeof(x)). " *
        "Pass a file path, or load the Plots/Makie extension.",
    )
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

"""
    _materialize(fig, base, fmts) -> Vector{String}

Call the deferred `fig.gen` **exactly once** to produce the figure, write the assets,
and return their paths (notes 02 pass 3). Figure objects are saved per `fmt` via
`pinax_save`; an existing file path is copied (the file must exist when `gen()` returns).
"""
function _materialize(fig::Figure, base, fmts)
    x = fig.gen()
    if is_figure(x)
        return String[pinax_save(x, base, fmt) for fmt in fmts]
    elseif x isa AbstractString
        return String[_copyfile(x, base)]
    else
        error(
            "Pinax: @figure produced $(typeof(x)); expected a file path or a known plot " *
            "(load the Plots/Makie extension).",
        )
    end
end
