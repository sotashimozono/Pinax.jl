# comments.jl — id-keyed annotation store for the gallery (notes 01 §4).
#
# Comments are a communication layer over the rendered figures: a portable, append-only sidecar that
# the human gallery, a CLI, and an LLM loop all read/write **by the section/figure id**. The id is
# the single explicit key linking the Julia manuscript (`@section :id`), the HTML (`<section id=…>`),
# and a comment — so a comment's correspondence to its source is unambiguous.
#
# Format = TOML (robust machine read/write, human-readable, git-diffable, consistent with the
# ParamIO/DataVault stack). Append-only entries per id so multiple writers (me / advisor / LLM) add
# turns without clobbering one another:
#
#     [[comment.eq_energy]]
#     author = "llm"
#     text = "Residual growth is consistent with finite-χ truncation."
#
#     [[comment.eq_energy]]
#     author = "sensei"
#     text = "Check the clean_obs β-overlap removal."
#
#     [bookmark]
#     eq_energy = true
#
# `text` is markdown (rendered when displayed). The browser is a convenience writer (localStorage +
# export, D2); this file is the durable source of truth and is the substrate for the CLI / LLM loop.

"One comment turn: who wrote it and the markdown body."
struct Comment
    author::String
    text::String
end

"""
    read_comments(path) -> (comments, bookmarks)

Read an id-keyed comments TOML. Returns `comments::Dict{Symbol,Vector{Comment}}` (id -> turns, in
file order) and `bookmarks::Set{Symbol}`. A missing or unparseable file yields empties (non-fatal).
"""
function read_comments(path::AbstractString)
    comments = Dict{Symbol,Vector{Comment}}()
    bookmarks = Set{Symbol}()
    isfile(path) || return comments, bookmarks
    data = try
        TOML.parsefile(path)
    catch
        return comments, bookmarks
    end
    for (id, entries) in get(data, "comment", Dict{String,Any}())
        entries isa AbstractVector || continue
        turns = Comment[
            Comment(string(get(e, "author", "")), string(get(e, "text", ""))) for
            e in entries if e isa AbstractDict
        ]
        isempty(turns) || (comments[Symbol(id)] = turns)
    end
    for (id, on) in get(data, "bookmark", Dict{String,Any}())
        on === true && push!(bookmarks, Symbol(id))
    end
    return comments, bookmarks
end

"""
    add_comment(path, id, text; author="") -> path

Append one comment turn for `id` to the TOML at `path` (created if absent), preserving existing
turns and bookmarks. This is the CLI / LLM-loop write path:
`julia -e 'using Pinax; Pinax.add_comment("comments.toml", :eq_energy, "…"; author="llm")'`.
"""
function add_comment(
    path::AbstractString, id, text::AbstractString; author::AbstractString=""
)
    data = _read_toml(path)
    cmt = get!(data, "comment", Dict{String,Any}())
    turns = get!(cmt, string(id), Any[])
    push!(turns, Dict("author" => String(author), "text" => String(text)))
    _write_toml(path, data)
    return path
end

"""
    set_bookmark!(path, id, on=true) -> path

Mark/unmark `id` as bookmarked in the TOML at `path`.
"""
function set_bookmark!(path::AbstractString, id, on::Bool=true)
    data = _read_toml(path)
    get!(data, "bookmark", Dict{String,Any}())[string(id)] = on
    _write_toml(path, data)
    return path
end

_read_toml(path) = isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()

function _write_toml(path, data)
    open(path, "w") do io
        return TOML.print(io, data)
    end
    return nothing
end
