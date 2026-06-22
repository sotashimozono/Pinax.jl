# pinax-mcp

A **general-purpose** library + [MCP](https://modelcontextprotocol.io) server over any Pinax
`agent.json`. It consumes the `render(theme=:agent)` artifact of *any* Pinax document — there is no
per-project knowledge in here; the `agent.json` schema is the only contract.

Pinax's agent backend emits every unit (part / page / section / figure) as an id-addressable JSON
node, each figure carrying its **verification substrate** — the caption (the claim), the generating
code, the params binding, the rendered asset, and the comment thread. `pinax-mcp` serves that to an
LLM so it can reconcile a claim against its evidence.

## Use as a library

```ts
import { loadAtlas } from "pinax-mcp";

const atlas = loadAtlas("path/to/render-out"); // dir with agent.json, or the file itself
atlas.outline();                // token-lean tree of the whole document
atlas.unit("energy_fig1");      // one unit by id (a figure -> its full substrate)
atlas.search("susceptibility"); // substring search -> matching unit ids + snippet
atlas.figureAssets("energy_fig1"); // absolute paths to the rendered assets
```

`Atlas` is pure (no MCP, no network) — useful on its own for scripting over a render.

## Use as an MCP server

```sh
npm install && npm run build
node dist/src/index.js --agent path/to/render-out
# add --comments to enable the write-back (add_comment) tool:
node dist/src/index.js --agent path/to/render-out --comments path/to/comments.toml
```

Register it with an MCP client (Claude Desktop, etc.):

```json
{
  "mcpServers": {
    "pinax": {
      "command": "node",
      "args": ["/abs/path/to/pinax-mcp/dist/src/index.js", "--agent", "/abs/path/to/render-out"]
    }
  }
}
```

### What it exposes

| | |
| --- | --- |
| resource `pinax://document` | the outline (markdown) |
| resource `pinax://{kind}/{id}` | any part/page/section/figure node (JSON) |
| resource `pinax://asset/{figureId}/{index}` | a figure's rendered asset (image/PDF bytes, for vision models) |
| tool `outline()` | the document tree, token-lean |
| tool `get_unit(id)` | one unit; a figure → its verification substrate |
| tool `search(query)` | substring search → matching unit ids + snippet |
| tool `add_comment(id, text, author?)` | append a comment to the store — **only with `--comments`** |
| tool `set_bookmark(id, on?)` | bookmark a unit — **only with `--comments`** |

### Closing the comment loop

With `--comments <comments.toml>`, the agent can write back: `add_comment` appends an
id-keyed turn to the Pinax comment store, byte-compatible with `Pinax.read_comments` /
`Pinax.add_comment`. Re-render the document and the comment is baked into the gallery and the
next `agent.json` — so an LLM's review flows back into the human artifact. Without `--comments`
the server is strictly read-only.

## Develop

```sh
npm test   # builds, then runs the node:test suite against a fixture agent.json
```

The fixture in `test/fixtures/` is a real `render(theme=:agent)` output (a synthetic, non-domain
document) exercising all three `params` shapes a figure can have: a structured axis object, an opaque
string, and none.
