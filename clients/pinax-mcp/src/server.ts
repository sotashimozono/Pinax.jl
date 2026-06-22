// The MCP frontend over an Atlas. Generic: it exposes whatever units the agent.json contains.
//
//   resources  pinax://document                     the outline (text)
//              pinax://{kind}/{id}                   any part/page/section/figure node (JSON)
//              pinax://asset/{figureId}/{index}      a figure's rendered asset (image/pdf bytes)
//   tools      outline()                             the document tree, token-lean
//              get_unit(id)                           one unit; a figure -> its verification substrate
//              search(query)                          substring search -> matching unit ids + snippet
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListResourcesRequestSchema,
  ListResourceTemplatesRequestSchema,
  ListToolsRequestSchema,
  ReadResourceRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { readFileSync } from "node:fs";
import { extname } from "node:path";
import type { Atlas } from "./atlas.js";

const MIME: Record<string, string> = {
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".avif": "image/avif",
  ".pdf": "application/pdf",
  ".json": "application/json",
};
const mimeFor = (p: string): string => MIME[extname(p).toLowerCase()] ?? "application/octet-stream";
const isTextual = (m: string): boolean =>
  m.startsWith("text/") || m === "image/svg+xml" || m === "application/json";

export function createServer(atlas: Atlas, info?: { name?: string; version?: string }): Server {
  const server = new Server(
    { name: info?.name ?? "pinax-mcp", version: info?.version ?? "0.1.0" },
    { capabilities: { resources: {}, tools: {} } },
  );

  // ---- resources ----------------------------------------------------------------------------

  server.setRequestHandler(ListResourcesRequestSchema, async () => ({
    resources: [
      {
        uri: "pinax://document",
        name: atlas.doc.title || "document",
        description: "The document outline (parts, pages, sections, figures).",
        mimeType: "text/markdown",
      },
      ...atlas.all().map((u) => ({
        uri: `pinax://${u.kind}/${u.id}`,
        name: `${u.kind}: ${u.label}`,
        mimeType: "application/json",
      })),
    ],
  }));

  server.setRequestHandler(ListResourceTemplatesRequestSchema, async () => ({
    resourceTemplates: [
      { uriTemplate: "pinax://figure/{id}", name: "Figure by id", mimeType: "application/json" },
      { uriTemplate: "pinax://page/{id}", name: "Page by id", mimeType: "application/json" },
      { uriTemplate: "pinax://section/{id}", name: "Section by id", mimeType: "application/json" },
      { uriTemplate: "pinax://part/{id}", name: "Part by id", mimeType: "application/json" },
      { uriTemplate: "pinax://asset/{figureId}/{index}", name: "A figure's rendered asset" },
    ],
  }));

  server.setRequestHandler(ReadResourceRequestSchema, async (req) => {
    const uri = req.params.uri;
    if (uri === "pinax://document") {
      return { contents: [{ uri, mimeType: "text/markdown", text: atlas.outline() }] };
    }
    const m = uri.match(/^pinax:\/\/([a-z]+)\/(.+)$/);
    if (!m) throw new Error(`unsupported resource uri: ${uri}`);
    const [, kind, rest] = m;

    if (kind === "asset") {
      const am = rest.match(/^(.+)\/(\d+)$/);
      if (!am) throw new Error(`bad asset uri (want pinax://asset/{figureId}/{index}): ${uri}`);
      const assets = atlas.figureAssets(am[1]);
      const a = assets[Number(am[2])];
      if (!a) throw new Error(`no asset ${am[2]} for figure ${am[1]}`);
      const mimeType = mimeFor(a.abs);
      const buf = readFileSync(a.abs);
      return {
        contents: [
          isTextual(mimeType)
            ? { uri, mimeType, text: buf.toString("utf8") }
            : { uri, mimeType, blob: buf.toString("base64") },
        ],
      };
    }

    const u = atlas.unit(rest);
    if (!u) throw new Error(`unknown ${kind}: ${rest}`);
    return {
      contents: [{ uri, mimeType: "application/json", text: JSON.stringify(u.node, null, 2) }],
    };
  });

  // ---- tools --------------------------------------------------------------------------------

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
      {
        name: "outline",
        description:
          "Token-lean text outline of the whole document (parts -> pages -> sections -> figures, each with its id).",
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
      },
      {
        name: "get_unit",
        description:
          "Fetch one unit (part / page / section / figure) by its id. A figure returns its full verification substrate: caption, generating code, params binding, asset paths, and comments.",
        inputSchema: {
          type: "object",
          properties: { id: { type: "string", description: "the unit id, e.g. a figure id" } },
          required: ["id"],
          additionalProperties: false,
        },
      },
      {
        name: "search",
        description:
          "Case-insensitive substring search across titles, captions, descriptions, generating code, and comments. Returns matching unit ids with a snippet.",
        inputSchema: {
          type: "object",
          properties: { query: { type: "string" } },
          required: ["query"],
          additionalProperties: false,
        },
      },
    ],
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const { name, arguments: args } = req.params;
    const ok = (text: string) => ({ content: [{ type: "text" as const, text }] });
    const err = (text: string) => ({ content: [{ type: "text" as const, text }], isError: true });
    try {
      if (name === "outline") return ok(atlas.outline());
      if (name === "get_unit") {
        const id = String((args as Record<string, unknown>)?.id ?? "");
        const u = atlas.unit(id);
        return u ? ok(JSON.stringify(u.node, null, 2)) : err(`no unit with id '${id}'`);
      }
      if (name === "search") {
        const query = String((args as Record<string, unknown>)?.query ?? "");
        const hits = atlas.search(query);
        if (hits.length === 0) return ok(`no matches for '${query}'`);
        return ok(
          hits.map((h) => `[${h.kind} ${h.id}] ${h.label}\n  ${h.field}: ${h.snippet}`).join("\n"),
        );
      }
      return err(`unknown tool: ${name}`);
    } catch (e) {
      return err(`error: ${(e as Error).message}`);
    }
  });

  return server;
}

/** Connect a server over stdio (the standard MCP transport for a local subprocess). */
export async function serveStdio(atlas: Atlas, info?: { name?: string; version?: string }): Promise<void> {
  const server = createServer(atlas, info);
  await server.connect(new StdioServerTransport());
}
