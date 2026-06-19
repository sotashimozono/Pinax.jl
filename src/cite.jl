# cite.jl — BibTeX support for `@cite` / `@bibliography` (notes 03).
#
# `@cite` is a plain LaTeX-style citation: `@bibliography "refs.bib"` declares the source(s),
# `@cite(:key)` (or `[text](@cite key)`) renders `[n]` (numbered by first appearance) linking to a
# generated References section, whose entry hyperlinks to the DOI / URL / arXiv id if present. No
# network access, no paper fetching.
#
# Parsing is delegated to Bibliography.jl (a maintained .bib reader, the high-level wrapper over
# BibParser/BibInternal); we adapt each structured entry into the small `BibEntry` the gallery
# renderer needs, so the theme stays decoupled from the parser's types.

"A bibliography entry reduced to the fields the gallery renders."
struct BibEntry
    key::String
    authors::String
    title::String
    venue::String
    year::String
    doi::String
    url::String
    eprint::String
end

# Parse one .bib file into `key => BibEntry`. Throws on an unreadable/broken file; the caller
# (`_load_bib`) turns that into a diagnostic (non-fatal).
function parse_bib(path::AbstractString)
    out = Dict{Symbol,BibEntry}()
    for (k, e) in Bibliography.import_bibtex(path)
        out[Symbol(k)] = _adapt_entry(e)
    end
    return out
end

# BibInternal.Entry -> BibEntry. `e.in.journal` falls back to `e.booktitle` for proceedings.
function _adapt_entry(e)
    authors = join([strip(string(n.first, " ", n.last)) for n in e.authors], ", ")
    venue = isempty(e.in.journal) ? e.booktitle : e.in.journal
    return BibEntry(
        e.id,
        authors,
        e.title,
        venue,
        e.date.year,
        e.access.doi,
        e.access.url,
        e.eprint.eprint,
    )
end

# Human-readable reference string: "Authors. Title. Venue Year".
function format_bib_entry(e::BibEntry)
    parts = String[]
    isempty(e.authors) || push!(parts, e.authors)
    isempty(e.title) || push!(parts, e.title)
    vy = strip(string(e.venue, (isempty(e.venue) || isempty(e.year)) ? "" : " ", e.year))
    isempty(vy) || push!(parts, vy)
    return join(parts, ". ")
end

# External link target for an entry, by priority: DOI, then URL, then arXiv eprint. `nothing` if none.
function bib_link(e::BibEntry)
    isempty(e.doi) || return "https://doi.org/" * e.doi
    isempty(e.url) || return e.url
    isempty(e.eprint) || return "https://arxiv.org/abs/" * e.eprint
    return nothing
end

# Short label for a reference link, from the URL shape.
function bib_link_label(url::AbstractString)
    occursin("doi.org", url) && return "doi"
    occursin("arxiv.org", url) && return "arXiv"
    return "link"
end
