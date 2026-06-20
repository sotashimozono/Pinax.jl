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

end # module PinaxDataVaultExt
