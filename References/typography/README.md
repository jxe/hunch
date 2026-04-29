# Typography references

Real screenshots of pre-March-2026 Notion page rendering, used to drive
pixel-correct typography iteration in M2.

## Why these matter

Notion changed its page typography in a March 2026 update. Console targets
the *pre-update* style. The `react-notion-x` library claims to mirror that
style but its CSS doesn't match Notion exactly, so we work directly from
screenshots of real Notion pages from before the change.

**Date constraint:** screenshots must be from **2023, 2024, or January-February
2026**. Anything from March 2026 or later may show the post-update typography
and is not a valid reference.

## Working size

The Anthropic API rejects images over 2000 pixels in either dimension when
multiple images are sent in one request. Resize working copies to fit within
1900px of the larger dimension before checking them in here. Originals at
their full resolution live in `../../notion-screenshots/` (gitignored).

```sh
# Resize an oversized screenshot in place
sips --resampleWidth 1900 input.png --out resized.png    # if width > height
sips --resampleHeight 1900 input.png --out resized.png   # if height > width
```

## Current contents (high-confidence references)

- **`notion_example_page_formatting.jpg`** (1900×1013) — Thomas Frank
  "Notion Page Example". Best all-around reference. Shows: H1 page title +
  caption, H2 "Introduction", multiple paragraphs with inline italic
  (book titles like *Neuromancer*) and inline bold, callout-style
  highlight, and Notion's left sidebar. Use this as the primary diff target.

- **`notion_full_width_page.png`** (1920×1200) — "Blog Post Draft" page.
  Shows: H1 title with a small subtitle group above (Contact us, Twitter
  handles), then an H2 "Clear sidebar setup for easily-accessible
  information" followed by two paragraphs. Good for verifying H2→paragraph
  spacing and sub-heading metadata block layout.

- **`notion_prompt_example.png`** (1500×1900) — "RFC Prompt" page. Shows
  long multi-line **numbered list items** under H2 headings ("How to
  comment", "What to comment about"). The most important reference for
  list-item spacing and heading→list transitions.

- **`notion_ai_for_docs.webp`** (1200×630) — "Introduction" H1 with a
  multi-line paragraph showing selection highlighting. Good for line-height
  / leading verification on body text.

## What's still missing

If higher-quality references appear, look for:

- A page with **consecutive bullets at the same indent** (verify list-item
  to list-item gap)
- **Nested bullets** (indent step verification)
- A **blockquote** with the left bar (1.2em font-size, 3pt border)
- A **fenced code block** with rounded corners and the language label
- **Inline code chip** within a paragraph (rounded background per run)
- A **divider line** between two blocks
- A **toggle** in expanded and collapsed states
