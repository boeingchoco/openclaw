import { expectDefined } from "@openclaw/normalization-core";
import type {
  MarkdownBlock,
  MarkdownCodeRegion,
  MarkdownOwnership,
  ParsedOwnership,
} from "./reasoning-tag-parser.js";

// Resume only at a column-zero block after a blank line and a resetting block.
// Containers, lazy lines and indented code can carry parser state across blocks.
// Reparse the candidate suffix before adopting it; references can rewrite earlier
// inline code, so texts containing "]:" always use the whole parser.
const OWNERSHIP_CACHE_MIN_LENGTH = 256;
// Each streamed reply keeps about two boundaries and four recent texts per delta.
const SETTLED_BOUNDARY_LIMIT = 16;
const RECENT_OWNERSHIP_LIMIT = 32;
// Cached texts stay reachable, so both caches share a budget of retained source
// characters; a text over half of it is parsed without caching.
const RETAINED_CHARS_LIMIT = 1_000_000;
const RESETTING_BLOCK_TYPES = new Set(["heading", "paragraph", "thematicBreak"]);
const BLANK_LINE_RE = /(?:\r\n|\r(?!\n)|\n)[^\S\r\n]*(?:\r|\n)/u;
// CommonMark code needs a literal delimiter or indentation, even inside containers.
const CODE_SYNTAX_RE = /[`~\t]| {4}/u;

type SettledBoundary = {
  /** Source through the first character of the boundary block. */
  prefix: string;
  /** Offset of the boundary block, where parsing resumes. */
  start: number;
  regions: MarkdownCodeRegion[];
  completedParagraphs: MarkdownOwnership["completedParagraphs"];
  /** A later candidate that did not reproduce, so it is not checked again. */
  rejectedStart?: number;
};

export function createMarkdownOwnershipCache(parseSource: (text: string) => ParsedOwnership) {
  const settledBoundaries: SettledBoundary[] = [];
  // Reply directive and media parsing ask about the same text several times per delta.
  const recentOwnership: Array<{ text: string; ownership: MarkdownOwnership }> = [];

  function trimToRetainedBudget() {
    let retained =
      recentOwnership.reduce((sum, entry) => sum + entry.text.length, 0) +
      settledBoundaries.reduce((sum, boundary) => sum + boundary.prefix.length, 0);
    // The newest text and boundary each fit in half of the budget.
    while (retained > RETAINED_CHARS_LIMIT && recentOwnership.length > 1) {
      retained -= recentOwnership.pop()?.text.length ?? 0;
    }
    while (retained > RETAINED_CHARS_LIMIT && settledBoundaries.length > 1) {
      retained -= settledBoundaries.pop()?.prefix.length ?? 0;
    }
  }

  function findSettledBoundary(text: string): SettledBoundary | undefined {
    if (text.length < OWNERSHIP_CACHE_MIN_LENGTH || text.includes("]:")) {
      return undefined;
    }
    const index = settledBoundaries.findIndex((boundary) => text.startsWith(boundary.prefix));
    if (index === -1) {
      return undefined;
    }
    const [boundary] = settledBoundaries.splice(index, 1);
    settledBoundaries.unshift(expectDefined(boundary, "settled Markdown boundary"));
    return boundary;
  }

  function resumeOwnership(text: string, boundary: SettledBoundary): ParsedOwnership {
    const { start } = boundary;
    const tail = parseSource(text.slice(start));
    const shift = <T extends { start: number; end: number }>(item: T): T => ({
      ...item,
      start: item.start + start,
      end: item.end + start,
    });
    const regions = [...boundary.regions, ...tail.ownership.regions.map(shift)];
    return {
      ownership: {
        regions,
        codeSpans: regions.map((region): [number, number] => [region.start, region.end]),
        textSpans: [],
        retainStart: start + tail.ownership.retainStart,
        completedParagraphs: [
          ...boundary.completedParagraphs,
          ...tail.ownership.completedParagraphs.map(shift),
        ],
      },
      blocks: tail.blocks.map(shift),
    };
  }

  function createSettledBoundary(
    text: string,
    parsed: ParsedOwnership,
    current: SettledBoundary | undefined,
  ): SettledBoundary | undefined {
    // Index 0 is either the first block or the block `current` starts at.
    for (let index = parsed.blocks.length - 1; index > 0; index -= 1) {
      const previous = expectDefined(parsed.blocks[index - 1], "Markdown block");
      const { start } = expectDefined(parsed.blocks[index], "Markdown block");
      if (!startsAfterReset(text, previous, start)) {
        continue;
      }
      if (start === current?.rejectedStart || !resumesIdentically(text, parsed, start)) {
        if (current) {
          current.rejectedStart = start;
        }
        return undefined;
      }
      return {
        prefix: text.slice(0, start + 1),
        start,
        regions: parsed.ownership.regions.filter((region) => region.start < start),
        completedParagraphs: parsed.ownership.completedParagraphs.filter(
          (paragraph) => paragraph.start < start,
        ),
      };
    }
    return undefined;
  }

  function resumesIdentically(text: string, parsed: ParsedOwnership, start: number): boolean {
    const tail = parseSource(text.slice(start));
    return (
      sameRanges(parsed.blocks, tail.blocks, start, "type") &&
      sameRanges(parsed.ownership.regions, tail.ownership.regions, start, "block") &&
      sameRanges(
        parsed.ownership.completedParagraphs,
        tail.ownership.completedParagraphs,
        start,
        "hasReferenceCandidate",
      )
    );
  }

  return {
    parseOwnership(text: string): MarkdownOwnership {
      if (text.length < OWNERSHIP_CACHE_MIN_LENGTH || text.length > RETAINED_CHARS_LIMIT / 2) {
        return parseSource(text).ownership;
      }
      const recent = recentOwnership.find((entry) => entry.text === text);
      if (recent) {
        return recent.ownership;
      }
      const boundary = findSettledBoundary(text);
      const parsed = boundary ? resumeOwnership(text, boundary) : parseSource(text);
      // Only a text that grew from a recent one is likely to be asked about again.
      const growing =
        boundary !== undefined || recentOwnership.some((entry) => text.startsWith(entry.text));
      const next =
        growing && !text.includes("]:") ? createSettledBoundary(text, parsed, boundary) : undefined;
      if (next && boundary) {
        // findSettledBoundary moved the boundary it returned to the front.
        settledBoundaries[0] = next;
      } else if (next) {
        settledBoundaries.unshift(next);
        settledBoundaries.length = Math.min(settledBoundaries.length, SETTLED_BOUNDARY_LIMIT);
      }
      recentOwnership.unshift({ text, ownership: parsed.ownership });
      recentOwnership.length = Math.min(recentOwnership.length, RECENT_OWNERSHIP_LIMIT);
      trimToRetainedBudget();
      return parsed.ownership;
    },

    /** Settled code regions when the text after the boundary has no code syntax. */
    findSettledCodeRegions(text: string): MarkdownCodeRegion[] | undefined {
      const boundary = findSettledBoundary(text);
      return boundary && !CODE_SYNTAX_RE.test(text.slice(boundary.start))
        ? boundary.regions
        : undefined;
    },
  };
}

function sameRanges<T extends { start: number; end: number }>(
  whole: T[],
  tail: T[],
  start: number,
  field: keyof T,
): boolean {
  let index = 0;
  while (index < whole.length && expectDefined(whole[index], "Markdown range").start < start) {
    index++;
  }
  if (whole.length - index !== tail.length) {
    return false;
  }
  for (const range of tail) {
    const original = expectDefined(whole[index++], "Markdown range");
    if (
      original.start !== range.start + start ||
      original.end !== range.end + start ||
      original[field] !== range[field]
    ) {
      return false;
    }
  }
  return true;
}

function startsAfterReset(text: string, previous: MarkdownBlock, start: number): boolean {
  const resetting =
    RESETTING_BLOCK_TYPES.has(previous.type ?? "") ||
    (previous.type === "code" &&
      /^(?:`{3}|~{3})/u.test(text.slice(previous.start, previous.start + 3)));
  // A visible first character at column 0 after a blank line always starts a block.
  return (
    resetting &&
    (text[start - 1] === "\n" || text[start - 1] === "\r") &&
    text[start] !== " " &&
    text[start] !== "\t" &&
    BLANK_LINE_RE.test(text.slice(previous.end, start))
  );
}
