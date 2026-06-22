#!/usr/bin/env node
// CLI: serve any Pinax agent.json over MCP (stdio).
//
//   pinax-mcp --agent path/to/out            # a render directory (contains agent.json)
//   pinax-mcp --agent path/to/agent.json     # the file directly
//   PINAX_AGENT=path/to/out pinax-mcp        # or via env
import { loadAtlas } from "./atlas.js";
import { serveStdio } from "./server.js";

function parseAgentPath(argv: string[]): string {
  let agent = process.env.PINAX_AGENT ?? "";
  for (let i = 0; i < argv.length; i++) {
    if ((argv[i] === "--agent" || argv[i] === "-a") && argv[i + 1] !== undefined) {
      agent = argv[++i];
    }
  }
  return agent;
}

async function main(): Promise<void> {
  const agent = parseAgentPath(process.argv.slice(2));
  if (!agent) {
    console.error(
      "pinax-mcp: pass --agent <path to agent.json or its directory> (or set PINAX_AGENT).",
    );
    process.exit(2);
  }
  const atlas = loadAtlas(agent);
  await serveStdio(atlas);
  // The stdio transport keeps the process alive until the MCP client disconnects.
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
