module PinaxParamIOExt

# ParamIO extension for Pinax. Loaded automatically when both Pinax and ParamIO are imported.
# Specializes Pinax's param hooks on a ParamIO.DataKey: a stable cache identity, param-derived
# figure ids (so a sweep keeps each figure's id across reordering), and `by=` faceting over a key's
# param axes. Without ParamIO the core hooks fall back (repr / positional id / no faceting).

using Pinax
using ParamIO

# Order-/version-independent identity for the cache key (equal params in any insertion order match).
function Pinax._params_id(p::ParamIO.DataKey)
    try
        return ParamIO.canonical(p)
    catch
        return repr(p)
    end
end

# Filesystem-safe tag derived from the key, used to build a stable figure id.
function Pinax._param_tag(p::ParamIO.DataKey)
    try
        return replace(ParamIO.canonical(p), r"[^A-Za-z0-9_-]" => "_")
    catch
        # canonical can throw on hand-built keys with reserved delimiters; fall back to positional.
        return nothing
    end
end

# Value of a param axis for `by=` faceting, or `missing` if the key lacks that axis.
function Pinax._facet_value(p::ParamIO.DataKey, facet)
    return haskey(p.params, facet) ? p.params[facet] : missing
end

end # module PinaxParamIOExt
