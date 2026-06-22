// Atlas — a queryable index over ANY Pinax `agent.json`. Pure (no MCP, no I/O beyond the initial
// load), so it is usable as a plain library: `loadAtlas(path).search("...")`. The MCP server in
// server.ts is just one frontend over this.
//
// Every unit (part / page / section / figure) is addressable by its id — Pinax ids are globally
// unique within a document (they key the comment store), so a single id -> unit map is the index.
import { readFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { AgentDocZ, type AgentDoc, type Figure, type Part } from "./schema.js";

export type UnitKind = "part" | "page" | "section" | "figure";

export interface Unit {
  kind: UnitKind;
  id: string;
  /** A human label: the title for a part/page/section, the caption for a figure. */
  label: string;
  /** The containing unit's id (a page's part, a section's page, a figure's section or page). */
  parent?: string;
  /** The raw agent.json node, returned verbatim by `get_unit` / resource reads. */
  node: any;
}

export interface SearchHit {
  id: string;
  kind: UnitKind;
  label: string;
  field: string;
  snippet: string;
}

export class Atlas {
  readonly doc: AgentDoc;
  /** Directory of the agent.json, used to resolve the relative asset paths it references. */
  readonly baseDir: string;
  private units = new Map<string, Unit>();
  private order: string[] = [];

  constructor(doc: AgentDoc, baseDir: string) {
    this.doc = doc;
    this.baseDir = baseDir;
    this.build();
  }

  private add(u: Unit): void {
    // ids are globally unique within a Pinax document; on the rare hand-built clash, first wins.
    if (this.units.has(u.id)) return;
    this.units.set(u.id, u);
    this.order.push(u.id);
  }

  private build(): void {
    for (const part of this.doc.parts) {
      this.add({ kind: "part", id: part.id, label: part.title, node: part });
    }
    for (const page of this.doc.pages) {
      this.add({
        kind: "page",
        id: page.id,
        label: page.title,
        parent: page.part ?? undefined,
        node: page,
      });
      for (const fig of page.figures) {
        this.add({ kind: "figure", id: fig.id, label: fig.caption, parent: page.id, node: fig });
      }
      for (const sec of page.sections) {
        this.add({ kind: "section", id: sec.id, label: sec.title, parent: page.id, node: sec });
        for (const fig of sec.figures) {
          this.add({ kind: "figure", id: fig.id, label: fig.caption, parent: sec.id, node: fig });
        }
      }
    }
  }

  unit(id: string): Unit | undefined {
    return this.units.get(id);
  }

  all(kind?: UnitKind): Unit[] {
    const us = this.order.map((id) => this.units.get(id)!);
    return kind ? us.filter((u) => u.kind === kind) : us;
  }

  /** A token-lean text outline of the whole document (parts -> pages -> sections -> figures). */
  outline(): string {
    const out: string[] = [`# ${this.doc.title}`];
    const partOf = new Map<string, Part>(this.doc.parts.map((p) => [p.id, p]));
    const figLine = (f: Figure) => out.push(`- [figure ${f.id}] ${f.caption}`);
    let lastPart: string | null | undefined;
    for (const page of this.doc.pages) {
      const pid = page.part ?? null;
      if (pid !== (lastPart ?? null)) {
        lastPart = pid;
        if (pid) out.push(`\n## [part ${pid}] ${partOf.get(pid)?.title ?? pid}`);
      }
      const summary = page.summary ? ` — ${page.summary}` : "";
      out.push(`\n### [page ${page.id}] ${page.title}${summary}`);
      for (const f of page.figures) figLine(f);
      for (const sec of page.sections) {
        out.push(`#### [section ${sec.id}] ${sec.title}`);
        for (const f of sec.figures) figLine(f);
      }
    }
    return out.join("\n");
  }

  /** Case-insensitive substring search over labels, descriptions, summaries, code, and comments. */
  search(query: string): SearchHit[] {
    const q = query.toLowerCase();
    const hits: SearchHit[] = [];
    const consider = (u: Unit, field: string, text: string | null | undefined): void => {
      if (!text) return;
      const i = text.toLowerCase().indexOf(q);
      if (i < 0) return;
      const start = Math.max(0, i - 30);
      const slice = text.slice(start, i + q.length + 30).replace(/\s+/g, " ").trim();
      hits.push({
        id: u.id,
        kind: u.kind,
        label: u.label,
        field,
        snippet: (start > 0 ? "…" : "") + slice + (i + q.length + 30 < text.length ? "…" : ""),
      });
    };
    if (q.length === 0) return hits;
    for (const u of this.all()) {
      const n = u.node;
      consider(u, "label", u.label);
      if (u.kind === "figure") {
        consider(u, "code", n.code);
        if (typeof n.params === "string") consider(u, "params", n.params);
        for (const c of n.comments) consider(u, "comment", `${c.author}: ${c.text}`);
      } else {
        consider(u, "desc", n.desc);
        if (u.kind === "page") consider(u, "summary", n.summary);
      }
    }
    return hits;
  }

  /** Absolute paths of a figure's rendered assets, resolved against the agent.json directory. */
  figureAssets(id: string): { rel: string; abs: string }[] {
    const u = this.units.get(id);
    if (!u || u.kind !== "figure") return [];
    return (u.node.assets as string[]).map((rel) => ({
      rel,
      abs: isAbsolute(rel) ? rel : resolve(this.baseDir, rel),
    }));
  }
}

/** Load an Atlas from an agent.json file, or from a directory that contains one. */
export function loadAtlas(agentPath: string): Atlas {
  const file = agentPath.endsWith(".json") ? agentPath : join(agentPath, "agent.json");
  const raw = JSON.parse(readFileSync(file, "utf8"));
  const doc = AgentDocZ.parse(raw);
  return new Atlas(doc, dirname(resolve(file)));
}
