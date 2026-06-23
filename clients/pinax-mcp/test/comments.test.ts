import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "smol-toml";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CommentStore } from "../src/comments.js";

const tmpToml = (): string => join(mkdtempSync(join(tmpdir(), "pinax-mcp-")), "comments.toml");

// ---- CommentStore: byte-compatible with Pinax.read_comments / Pinax.add_comment ----

test("addComment appends id-keyed array-of-tables (the shape read_comments expects)", () => {
  const path = tmpToml();
  const store = new CommentStore(path);
  store.addComment("eq_energy", "first note", "llm");
  store.addComment("eq_energy", "second note", "sensei");
  store.addComment("p1_fig1", "other unit", "llm");

  const data = parse(readFileSync(path, "utf8")) as any;
  assert.equal(data.comment.eq_energy.length, 2);
  assert.deepEqual(data.comment.eq_energy[0], { author: "llm", text: "first note" });
  assert.deepEqual(data.comment.eq_energy[1], { author: "sensei", text: "second note" });
  assert.equal(data.comment.p1_fig1.length, 1);
});

test("appends are preserved across store instances (append-only, multi-writer)", () => {
  const path = tmpToml();
  new CommentStore(path).addComment("s1", "a", "x");
  const turns = new CommentStore(path).addComment("s1", "b", "y"); // fresh instance, same file
  assert.deepEqual(turns, [
    { author: "x", text: "a" },
    { author: "y", text: "b" },
  ]);
});

test("text with quotes/backslash/newline round-trips (TOML escaping handled)", () => {
  const path = tmpToml();
  const store = new CommentStore(path);
  const tricky = 'has "quotes", a \\backslash and\na newline';
  store.addComment("fig", tricky, "llm");
  assert.equal(store.comments("fig")[0].text, tricky);
  assert.equal((parse(readFileSync(path, "utf8")) as any).comment.fig[0].text, tricky);
});

test("setBookmark writes the [bookmark] table next to comments", () => {
  const path = tmpToml();
  const store = new CommentStore(path);
  store.addComment("fig", "n", "llm");
  store.setBookmark("fig", true);
  const data = parse(readFileSync(path, "utf8")) as any;
  assert.equal(data.bookmark.fig, true);
  assert.equal(data.comment.fig.length, 1);
});

test("a missing store is non-fatal (empty)", () => {
  const store = new CommentStore(join(tmpdir(), "pinax-mcp-nope-xyz", "c.toml"));
  assert.deepEqual(store.comments("any"), []);
});

// ---- end-to-end: the write tool over MCP, gated on --comments ----

const here = dirname(fileURLToPath(import.meta.url));
const serverEntry = resolve(here, "../src/index.js");
const fixture = resolve(here, "../../test/fixtures/sample");

test("add_comment is exposed only with --comments and persists over MCP", { timeout: 20000 }, async () => {
  const cf = tmpToml();
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry, "--agent", fixture, "--comments", cf],
  });
  const client = new Client({ name: "pinax-mcp-test", version: "0" }, { capabilities: {} });
  await client.connect(transport);
  try {
    const tools = (await client.listTools()).tools.map((t) => t.name);
    assert.ok(tools.includes("add_comment"));
    assert.ok(tools.includes("set_bookmark"));

    const res = await client.callTool({
      name: "add_comment",
      arguments: { id: "p1_fig1", text: "verified", author: "llm" },
    });
    assert.match((res.content as any)[0].text, /comment added to 'p1_fig1'/);

    // commenting on an id not in the document is rejected
    const bad = await client.callTool({ name: "add_comment", arguments: { id: "ghost", text: "x" } });
    assert.equal(bad.isError, true);
  } finally {
    await client.close();
  }

  // the file is now a Pinax-compatible comments.toml
  const data = parse(readFileSync(cf, "utf8")) as any;
  assert.deepEqual(data.comment.p1_fig1[0], { author: "llm", text: "verified" });
});

test("without --comments the write tools are absent (read-only by default)", { timeout: 20000 }, async () => {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry, "--agent", fixture],
  });
  const client = new Client({ name: "pinax-mcp-test", version: "0" }, { capabilities: {} });
  await client.connect(transport);
  try {
    const tools = (await client.listTools()).tools.map((t) => t.name);
    assert.ok(!tools.includes("add_comment"));
  } finally {
    await client.close();
  }
});
