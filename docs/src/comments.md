# Comments

Pinax galleries carry an optional **comment layer** — a lightweight way to annotate the gallery
*at* each figure or section, so the binding between a remark and its target is visually unambiguous.
It is meant as a communication channel (author ⇄ reviewer ⇄ tooling) over a figure-heavy document.

Enable it in the preamble:

```julia
@pinaxsetup features = (:comments, :bookmarks, :export)
```

Every **figure** and every **section** then gets a small `✎` control: click it to comment on that
node. Sections are commented at their heading; figures at their caption.

## Two layers: committed vs local

A comment lives in one of two places:

| layer | where it lives | how it is shown |
| --- | --- | --- |
| **committed** | `comments.toml` next to the gallery | rendered **server-side** when you `render`, baked into the HTML |
| **local** | the viewer's **browser `localStorage`** | added live by the JS, marked `(unsaved)` |

The committed layer is the durable, CLI/LLM-readable source of truth; the local layer is a per-browser
working cache.

## Comments on a deployed (static) gallery

!!! warning "Comments are local to the browser until exported"
    A deployed gallery (e.g. on GitHub Pages) is **static — there is no backend**. A reviewer's
    comments are therefore saved **only in their own browser's `localStorage`** (namespaced per page
    URL). They are not shared with other viewers and do not persist on the server.

To make local comments durable or shareable, the round-trip is explicit:

1. The reviewer clicks **Export comments.toml** in the toolbar — this merges the committed baseline
   with their local additions and downloads `comments.toml`.
2. They send that file to the author.
3. The author drops it next to the gallery and **re-renders** (`render(...)` reads
   `comments.toml`), baking the comments into the committed/server-side layer, then re-deploys.

The toolbar shows a running `N unsaved — Export to save` count and a note spelling this out, so a
reviewer is never surprised that closing the tab would lose un-exported comments. **Clear local**
discards this browser's unsaved comments and bookmarks.

## Programmatic API

Comments can also be read and written from Julia / the command line, which is how tooling
participates in the channel:

```julia
using Pinax
add_comment("comments.toml", :eq_energy, "this curve looks off below T=0.5"; author = "llm")
comments, bookmarks = read_comments("comments.toml")
```

`add_comment` is append-only and keyed by the node id (a figure or section anchor), the same id the
`✎` editor uses — so a comment added from the CLI and one added in the browser land on the same node.
