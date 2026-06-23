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

const text = (r: any) => (r.content as any)[0].text;

test("tools list and run end-to-end over MCP (figures + tables)", { timeout: 20000 }, async () => {
  await withClient(async (client) => {
    const tools = (await client.listTools()).tools.map((t) => t.name).sort();
    assert.deepEqual(tools, ["get_figure_data", "get_unit", "outline", "search"]);

    const outline = text(await client.callTool({ name: "outline", arguments: {} }));
    assert.match(outline, /Demo Atlas/);
    assert.match(outline, /\[table p1_tbl1\]/); // tables in the outline

    // a figure now carries an inline data table (figure_as_table)
    const fig = JSON.parse(text(await client.callTool({ name: "get_unit", arguments: { id: "p1_fig1" } })));
    assert.equal(fig.caption, "magnetization vs temperature");
    assert.deepEqual(fig.table.header, ["series", "x", "y"]);

    // a @table node is addressable the same way
    const tbl = JSON.parse(text(await client.callTool({ name: "get_unit", arguments: { id: "p1_tbl1" } })));
    assert.deepEqual(tbl.header, ["N", "Tc"]);

    // get_figure_data returns the full CSV behind the plot
    assert.match(text(await client.callTool({ name: "get_figure_data", arguments: { id: "p1_fig1" } })), /series,x,y/);

    // search reaches table cells
    assert.match(text(await client.callTool({ name: "search", arguments: { query: "critical" } })), /p1_tbl1/);

    const miss = await client.callTool({ name: "get_unit", arguments: { id: "nope" } });
    assert.equal(miss.isError, true);
  });
});

test("resources list and read end-to-end over MCP", { timeout: 20000 }, async () => {
  await withClient(async (client) => {
    const uris = (await client.listResources()).resources.map((r) => r.uri);
    assert.ok(uris.includes("pinax://document"));
    assert.ok(uris.includes("pinax://figure/p1_fig1"));
    assert.ok(uris.includes("pinax://table/p1_tbl1")); // @table node listed as a resource

    const tbl = await client.readResource({ uri: "pinax://table/p1_tbl1" });
    const node = JSON.parse((tbl.contents[0] as any).text);
    assert.deepEqual(node.rows, [
      [8, 2.1],
      [16, 2.2],
      [32, 2.27],
    ]);

    // a rendered asset comes back with its mime; svg is textual
    const asset = await client.readResource({ uri: "pinax://asset/p1_fig1/0" });
    assert.equal((asset.contents[0] as any).mimeType, "image/svg+xml");
    assert.match((asset.contents[0] as any).text, /<svg/);
  });
});
