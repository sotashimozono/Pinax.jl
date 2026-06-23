# CLAUDE.md — Pinax.jl

**The artifact / report layer above the HPC compute stack** (ParamIO → DataVault →
ParallelManager → **Pinax**). One presentation-neutral doc → three backends. Its job in the
workflow: turn results — including a finished `DataVault` sweep, via `report` — into a **human
gallery** *and* an **LLM-readable `agent.json`**. The LLM-facing seam of the whole pipeline is
`agent.json` (data, not pixels). See [`../CLAUDE.md`](../CLAUDE.md) for the compute stack.

## Role / public API — the seam

- **Build a doc** (macros populate an implicit global document): `@pinaxsetup` ·
  `@part`/`@page`/`@section` (structure; `@page status=:trial|:final`) · `@figure` (a deferred
  `plot(...)` / Makie scene / image path) · `@caption`/`@desc` (markdown+math) · `@table` (a
  sibling to figures) · `@raw` (HTML escape hatch).
- **Render** `render(; out, theme=:gallery|:agent|:latex)` — one doc, three backends:
  `:gallery` (self-contained HTML notebook), `:agent` (`agent.json` + `agent.md`, the LLM view),
  `:latex`. Optional `vault=`/`study=` wires DataVault in (cache tracks the data's `.done`
  fingerprint; provenance recorded).
- **Bridge a sweep** `report(vault, recipe; title, out)` — discover the vault's `:done` keys, load
  each Dict, hand the `(key, dict)` pairs to a project `recipe` (which builds the doc), render
  gallery + agent.json. Driver project-independent; only `recipe` is project-specific.
  `sweep_mean(pairs, quantity, axis)` is a generic scalar-vs-swept-param reduction.

## Contracts that trip up callers — read this

- **`@figure`'s expression is DEFERRED** — captured, not run, until `render` (so structure is
  cheap and figures cache). The cache keys on code + `params` (+ the `.done` fingerprint when a
  `vault` is given).
- **`agent.json` is the neutral LLM contract — it carries DATA, not pixels.** `figure_as_table`
  (default on the agent theme) presents a `@figure` *as its plotted-data table* (inline preview +
  full CSV via the MCP `get_figure_data`). Reason over the numbers; don't ask for the image.
- **`status` is a maturity tag a registry interprets:** `:final` (curated) vs `:trial` (raw
  experiment notebook — what `report` auto-output usually is). Pinax only carries it.
- **Two-env reality:** Pinax needs a plotting backend (Plots/Makie, heavy); compute needs its own
  heavy deps (ITensorMPS, …). They don't share an env in practice — compute writes a `DataVault`
  (or CSV), Pinax reads it. On HPC this maps to compute-node vs login-node; the seam is the vault.
- **pinax-mcp is a SEPARATE PROCESS** (`npx pinax-mcp --agent <out>`), not a Julia import. The
  neutral seam is the `agent.json` contract, not a repo/language boundary (it lives in
  `clients/pinax-mcp/` of this repo so emitter + schema co-evolve).

## Where to look for usage

- `test/test_datavault.jl` — the `report(vault, recipe)` bridge end-to-end.
- `test/test_agent.jl`, `test/test_table.jl` — the agent backend + `@table` / figure-as-table.
- `ext/PinaxDataVaultExt.jl` / `PinaxParamIOExt.jl` — the DataVault/ParamIO seams (vault → doc,
  DataKey → stable figure id).
- `notes/00–11` (gitignored, Japanese OK) — the design spec.

## Invariants when changing this package

- **All shipped code comments & docstrings are ENGLISH** (notes/ may be Japanese).
- **Format in a clean env with JuliaFormatter v2** (`Pkg.activate(mktempdir()); Pkg.add(name="JuliaFormatter", version="2"); format(".")`) — the default env's stale formatter diverges from CI.
- CI gates **every** PR: `FormatCheck` (v2, no auto-fix) + `VersionCheck` (bump `Project.toml`) +
  Documentation/preview. Bump the Julia version even for a Node-only `clients/pinax-mcp` change.
- **Keep the `agent.json` contract stable** — it is the seam the MCP server, registries (Archeion),
  and LLMs depend on. Evolve emitter (`themes/agent.jl`) + consumer schema (`clients/pinax-mcp`) +
  the shared fixture together, in one PR.
