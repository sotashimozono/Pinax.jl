#!/usr/bin/env node
// CLI: serve any Pinax agent.json over MCP (stdio).
//
//   pinax-mcp --agent path/to/out            # a render directory (contains agent.json)
//   pinax-mcp --agent path/to/agent.json     # the file directly
//   pinax-mcp --agent path/to/out --comments comments.toml   # also enable the add_comment write tool
//   PINAX_AGENT=path/to/out pinax-mcp        # or via env (PINAX_COMMENTS for the store)
import { loadAtlas } from "./atlas.js";
import { CommentStore } from "./comments.js";
import { serveStdio } from "./server.js";

interface Args {
  agent: string;
  comments?: string;
}

function parseArgs(argv: string[]): Args {
  let agent = process.env.PINAX_AGENT ?? "";
  let comments = process.env.PINAX_COMMENTS || undefined;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if ((a === "--agent" || a === "-a") && argv[i + 1] !== undefined) agent = argv[++i];
    else if (a === "--comments" && argv[i + 1] !== undefined) comments = argv[++i];
  }
  return { agent, comments };
}

async function main(): Promise<void> {
  const { agent, comments } = parseArgs(process.argv.slice(2));
  if (!agent) {
    console.error(
      "pinax-mcp: pass --agent <path to agent.json or its directory> (or set PINAX_AGENT).",
    );
    console.error("           add --comments <comments.toml> to enable the add_comment write tool.");
    process.exit(2);
  }
  const atlas = loadAtlas(agent);
  const store = comments ? new CommentStore(comments) : undefined;
  await serveStdio(atlas, { store });
  // The stdio transport keeps the process alive until the MCP client disconnects.
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
