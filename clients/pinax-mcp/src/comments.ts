// CommentStore — read/append the Pinax comment sidecar (`comments.toml`), byte-compatible with
// Julia's `Pinax.read_comments` / `Pinax.add_comment`. This is the LLM end of the comment loop:
// an agent appends a turn here, the human re-renders, and the comment is baked into the gallery.
//
// The TOML shape (see src/comments.jl) is id-keyed append-only array-of-tables plus a bookmark table:
//
//     [[comment.eq_energy]]
//     author = "llm"
//     text   = "Residual growth is consistent with finite-χ truncation."
//
//     [bookmark]
//     eq_energy = true
//
// `text` is arbitrary markdown, so we never hand-roll TOML — smol-toml handles string escaping and
// key quoting, and Julia's TOML stdlib reads the result back.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { parse, stringify } from "smol-toml";

export interface CommentTurn {
  author: string;
  text: string;
}

export class CommentStore {
  constructor(readonly path: string) {}

  private read(): Record<string, any> {
    if (!existsSync(this.path)) return {};
    try {
      return parse(readFileSync(this.path, "utf8")) as Record<string, any>;
    } catch {
      // mirror Julia read_comments: an unparseable file is non-fatal and treated as empty.
      return {};
    }
  }

  private write(data: Record<string, any>): void {
    mkdirSync(dirname(this.path), { recursive: true });
    writeFileSync(this.path, stringify(data));
  }

  /** Append one comment turn for `id`, preserving existing turns and bookmarks (Pinax.add_comment). */
  addComment(id: string, text: string, author = ""): CommentTurn[] {
    const data = this.read();
    const comment = (data.comment ??= {});
    const turns = (comment[id] ??= []) as CommentTurn[];
    turns.push({ author, text });
    this.write(data);
    return this.comments(id);
  }

  /** Mark/unmark `id` as bookmarked (Pinax.set_bookmark!). */
  setBookmark(id: string, on = true): void {
    const data = this.read();
    (data.bookmark ??= {})[id] = on;
    this.write(data);
  }

  /** Existing turns for `id`, in file order. */
  comments(id: string): CommentTurn[] {
    const c = this.read().comment?.[id];
    return Array.isArray(c)
      ? c.map((e: any) => ({ author: String(e.author ?? ""), text: String(e.text ?? "") }))
      : [];
  }
}
