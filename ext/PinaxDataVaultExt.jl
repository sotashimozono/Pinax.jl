module PinaxDataVaultExt

# DataVault extension for Pinax. Loaded automatically when Pinax, DataVault, and ParamIO are all
# imported (DataVault depends on ParamIO, so importing DataVault pulls ParamIO in). Makes the render
# cache track the underlying data and records figure provenance — the `render(; vault, study)` path.

using Pinax
using ParamIO
using DataVault

# Fold the `.done` marker's content into the cache key, so recomputing the data (DataVault rewrites
# the marker) re-materializes the figure (notes 10). Degrades to "" if the marker is absent or
# DataVault's internal layout changes.
function Pinax._data_fingerprint(vault::DataVault.Vault, params::ParamIO.DataKey)
    try
        df = DataVault._done_file(vault, params)
        return isfile(df) ? string(hash(read(df, String))) : ""
    catch e
        e isa InterruptException && rethrow()
        return ""
    end
end

# Record study-level figure provenance via DataVault (non-fatal).
function Pinax._record_provenance(vault::DataVault.Vault, study)
    try
        s = study === nothing ? vault.run : string(study)
        DataVault.record_figure(vault; study=s)
    catch e
        e isa InterruptException && rethrow()
        @warn "Pinax: DataVault.record_figure failed" exception = e
    end
    return nothing
end

# vault → doc bridge. Discover the vault's completed keys, load each result Dict, let the
# project `recipe` build the doc, render the human gallery + the agent.json with the vault
# wired in (so figure cache tracks `.done` fingerprints and provenance is recorded). The
# driver is project-independent; only `recipe(pairs)` is project-specific.
function Pinax.report(
    vault::DataVault.Vault,
    recipe::Function;
    title::AbstractString,
    out::AbstractString,
    study=nothing,
    kwargs...,
)
    pairs = [(k, DataVault.load(vault, k)) for k in DataVault.keys(vault; status=:done)]
    isempty(pairs) && error("Pinax.report: no :done keys in vault (run=$(vault.run)).")
    Pinax.reset!(; title=String(title))
    recipe(pairs)
    gallery = Pinax.render(; out="$(out)_html", theme=:gallery, vault, study, kwargs...)
    agent = Pinax.render(; out="$(out)_agent", theme=:agent, vault, study, kwargs...)
    return (; gallery, agent, n=length(pairs))
end

end # module PinaxDataVaultExt
