import type { ResolvedMemorySearchConfig } from "openclaw/plugin-sdk/memory-core-host-engine-foundation";
import {
  prepareSimilarityText,
  similarityFromSharedTokens,
  type PreparedSimilarityText,
} from "./tokenize.js";

// Carbonell & Goldstein (1998): maximize λ * relevance - (1-λ) * similarity.

type MMRItem = {
  score: number;
  snippet: string;
};

export type MMRConfig = ResolvedMemorySearchConfig["query"]["hybrid"]["mmr"];

type PreparedMMRItem<T extends MMRItem> = {
  item: T;
  score: number;
  text: PreparedSimilarityText;
  // Call-local ids for text.tokens, so overlap counts read an array instead of hashing strings.
  tokenIds: number[];
  relevance: number;
  maxSimilarity: number;
};

export function applyMMRToHybridResults<T extends MMRItem>(items: T[], lambda: number): T[] {
  if (items.length === 0) {
    return items;
  }
  if (items.length === 1) {
    return [...items];
  }
  if (lambda === 1) {
    return items.toSorted((a, b) => b.score - a.score);
  }
  const prepared: PreparedMMRItem<T>[] = [];
  const tokenIdByToken = new Map<string, number>();
  let maxScore = -Infinity;
  let minScore = Infinity;
  for (const item of items) {
    const score = item.score;
    maxScore = Math.max(maxScore, score);
    minScore = Math.min(minScore, score);
    const text = prepareSimilarityText(item.snippet);
    const tokenIds: number[] = [];
    for (const token of text.tokens) {
      let id = tokenIdByToken.get(token);
      if (id === undefined) {
        id = tokenIdByToken.size;
        tokenIdByToken.set(token, id);
      }
      tokenIds.push(id);
    }
    prepared.push({
      item,
      score,
      text,
      tokenIds,
      relevance: 0,
      maxSimilarity: 0,
    });
  }
  const scoreRange = maxScore - minScore;
  for (const item of prepared) {
    item.relevance = scoreRange === 0 ? 1 : (item.score - minScore) / scoreRange;
  }
  const remaining = new Set(prepared);
  const selected: T[] = [];
  let previous: PreparedMMRItem<T> | undefined;
  // A token belongs to the previous selection when its entry equals the current round.
  const previousTokenRound = new Uint32Array(tokenIdByToken.size);
  let round = 0;
  while (remaining.size > 0) {
    if (previous) {
      round++;
      for (const id of previous.tokenIds) {
        previousTokenRound[id] = round;
      }
    }
    let bestItem: PreparedMMRItem<T> | null = null;
    let bestMMRScore = -Infinity;
    for (const candidate of remaining) {
      // Apply the previous selection's penalty before ranking, in the same pass.
      // Jaccard similarity cannot exceed 1, so saturated maxima need no update.
      if (previous && candidate.maxSimilarity !== 1) {
        let sharedTokens = 0;
        for (const id of candidate.tokenIds) {
          if (previousTokenRound[id] === round) {
            sharedTokens++;
          }
        }
        const similarity = similarityFromSharedTokens(candidate.text, previous.text, sharedTokens);
        if (similarity > candidate.maxSimilarity) {
          candidate.maxSimilarity = similarity;
        }
      }
      const mmrScore = lambda * candidate.relevance - (1 - lambda) * candidate.maxSimilarity;
      if (
        mmrScore > bestMMRScore ||
        (mmrScore === bestMMRScore && candidate.score > (bestItem?.score ?? -Infinity))
      ) {
        bestMMRScore = mmrScore;
        bestItem = candidate;
      }
    }
    if (!bestItem) {
      break;
    }
    selected.push(bestItem.item);
    remaining.delete(bestItem);
    previous = bestItem;
  }
  return selected;
}
