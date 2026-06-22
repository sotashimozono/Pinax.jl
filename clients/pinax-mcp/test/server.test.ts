// End-to-end: spawn the real stdio MCP server over the fixture and drive it with the SDK client,
// so the protocol layer (resources + tools) is exercised, not just the Atlas library.
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const here = dirname(fileURLToPath(import.meta.url));
const serverEntry = resolve(here, "../src/index.js"); // dist/src/index.js
const fixture = resolve(here, "../../test/fixtures/sample");

async function withClient<T>(fn: (c: Client) => Promise<T>): Promise<T> {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry, "--agent", fixture],
  });
  const client = new Client({ name: "pinax-mcp-test", version: "0" }, { capabilities: {} });
  await client.connect(transport);
  try {
    return await fn(client);
  } finally {
    await client.close();
  }
}

test("tools list and run end-to-end over MCP", { timeout: 20000 }, async () => {
  await withClient(async (client) => {
    const tools = (await client.listTools()).tools.map((t) => t.name).sort();
    assert.deepEqual(tools, ["get_unit", "outline", "search"]);

    const outline = await client.callTool({ name: "outline", arguments: {} });
    assert.match((outline.content as any)[0].text, /Demo Atlas/);

    // a figure's substrate, including the structured params object
    const unit = await client.callTool({ name: "get_unit", arguments: { id: "p1_fig1" } });
    const node = JSON.parse((unit.content as any)[0].text);
    assert.equal(node.caption, "figure bound to a NamedTuple");
    assert.deepEqual(node.params, { N: 24, g: 0.5 });

    const hit = await client.callTool({ name: "search", arguments: { query: "converged" } });
    assert.match((hit.content as any)[0].text, /p1_fig1/);

    const miss = await client.callTool({ name: "get_unit", arguments: { id: "nope" } });
    assert.equal(miss.isError, true);
  });
});

test("resources list and read end-to-end over MCP", { timeout: 20000 }, async () => {
  await withClient(async (client) => {
    const uris = (await client.listResources()).resources.map((r) => r.uri);
    assert.ok(uris.includes("pinax://document"));
    assert.ok(uris.includes("pinax://figure/p1_fig1"));

    const fig = await client.readResource({ uri: "pinax://figure/p1_fig1" });
    const node = JSON.parse((fig.contents[0] as any).text);
    assert.deepEqual(node.params, { N: 24, g: 0.5 });

    // a rendered asset comes back with its mime; svg is textual
    const asset = await client.readResource({ uri: "pinax://asset/p1_fig1/0" });
    assert.equal((asset.contents[0] as any).mimeType, "image/svg+xml");
    assert.match((asset.contents[0] as any).text, /<svg/);
  });
});
