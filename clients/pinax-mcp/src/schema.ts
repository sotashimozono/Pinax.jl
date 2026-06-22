// The Pinax `agent.json` contract, as a runtime-validated schema. This is the ONLY thing the server
// depends on — it consumes any document emitted by `render(theme=:agent)`, never a specific gallery.
//
// `.passthrough()` everywhere so a future Pinax that adds a field (e.g. a format version) still parses
// against this older consumer. Param values are scalars today (the agent emitter writes JSON numbers /
// bools / strings); `params` itself is the three shapes the emitter can produce: a structured axis
// object, a string fallback (opaque params), or null.
import { z } from "zod";

export const ParamScalar = z.union([z.string(), z.number(), z.boolean()]);
export const Params = z.union([z.null(), z.string(), z.record(z.string(), ParamScalar)]);

export const CommentZ = z.object({ author: z.string(), text: z.string() }).passthrough();

export const FigureZ = z
  .object({
    id: z.string(),
    caption: z.string(),
    code: z.string(),
    params: Params,
    assets: z.array(z.string()),
    comments: z.array(CommentZ),
  })
  .passthrough();

export const SectionZ = z
  .object({
    id: z.string(),
    title: z.string(),
    desc: z.string().nullable(),
    figures: z.array(FigureZ),
  })
  .passthrough();

export const PageZ = z
  .object({
    id: z.string(),
    title: z.string(),
    part: z.string().nullable(),
    summary: z.string().nullable().optional(),
    desc: z.string().nullable(),
    figures: z.array(FigureZ),
    sections: z.array(SectionZ),
  })
  .passthrough();

export const PartZ = z
  .object({
    id: z.string(),
    title: z.string(),
    desc: z.string().nullable(),
  })
  .passthrough();

export const AgentDocZ = z
  .object({
    title: z.string(),
    parts: z.array(PartZ),
    pages: z.array(PageZ),
  })
  .passthrough();

export type Figure = z.infer<typeof FigureZ>;
export type Section = z.infer<typeof SectionZ>;
export type Page = z.infer<typeof PageZ>;
export type Part = z.infer<typeof PartZ>;
export type AgentDoc = z.infer<typeof AgentDocZ>;
