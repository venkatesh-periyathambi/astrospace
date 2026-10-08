/**
 * Home page content configuration.
 *
 * Everything the landing page shows beyond the post lists is configured here,
 * so the page itself stays presentational.
 *
 * To change the hero diagram, edit the `HeroDiagram` import in
 * `src/pages/index.astro` and update HERO.diagram below to match.
 */

export const HERO = {
  /** Small line above the headline. */
  kicker: "Vanakkam",
  /** The headline. Lead with what the site is about. */
  headline: "Notes on databases, data, and AI.",
  /** One line under the headline. Keep it short and concrete. */
  standfirst:
    "Write-ups of real customer problems from the field, with the diagrams I wish the docs had.",
  /** A second, lighter line for the non-work topics. */
  aside:
    "Occasionally travel, cooking, cricket, DIY and whatever is going on in the garden.",
  /** Caption and link for the hero diagram. */
  diagram: {
    caption: "From: The Pre-Filter and Post-Filter Cliff in Vector Search",
    href: "/posts/vector-search-pre-filter-post-filter-cliff",
  },
};

/**
 * Topic tiles. `tag` must match a tag used in post frontmatter.
 * Post counts are computed at build time, and tiles with no posts are hidden.
 */
export const TOPICS: { label: string; tag: string }[] = [
  { label: "Databases", tag: "databases" },
  { label: "AWS", tag: "aws" },
  { label: "Vector Search", tag: "vector-search" },
  { label: "AI and RAG", tag: "rag" },
];

/**
 * Multi-part series, newest first.
 * `posts` holds post ids, which are blog filenames without the extension,
 * in reading order. Missing, draft or future-dated posts are skipped, and a
 * series with nothing published is hidden.
 */
export const SERIES: {
  title: string;
  description: string;
  posts: string[];
}[] = [
  {
    title: "RAG Retrieval Non-Determinism",
    description:
      "Why an identical query returns a different top 10, and how to bound the variance instead of chasing determinism.",
    posts: [
      "rag-retrieval-nondeterminism-causes",
      "rag-retrieval-nondeterminism-fixes",
    ],
  },
];
