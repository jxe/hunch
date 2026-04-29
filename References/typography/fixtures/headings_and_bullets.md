# Headings and Bullets

This fixture exercises every transition between H1, H2, H3, paragraphs, and bullet lists. We assume bullets, numbered lists, and todos share identical spacing — verifying bullets covers all three.

## Section with a lead-in paragraph

A short paragraph sits between the H2 and the list below. The body text wraps to a second line on a normal column width so we can see baseline-to-baseline line-height inside a paragraph as well as the gap before the list.

- First top-level bullet
- Second top-level bullet that wraps to a second line because it has enough text in it to exceed the content-column width on a default layout
- Third top-level bullet
  - Nested bullet under the third
  - Another nested bullet that also wraps so we can see nested line-spacing
    - Depth-two nested bullet
  - Back up to depth one
- Fourth top-level bullet, back at depth zero

After the bullet list, prose resumes. This list-to-paragraph transition needs enough gap below the last item that it doesn't merge into the next paragraph, but not so much that the list feels orphaned.

## Section with bullets directly under the heading

- Bullet directly under an H2 with no lead-in paragraph
- Second bullet
- Third bullet

### A sub-section

A short paragraph under an H3 — H3 should be visibly smaller than H2 but heavier than body.

- Bullet under an H3
- Another bullet under the same H3

### Sub-section directly after another

No body paragraph separates this H3 from the one above.

### And one more

Closing paragraph under the third stacked H3.

## Final H2

Final closing paragraph after the body → H2 → body transition.
