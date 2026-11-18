---
name: EPUB Edit
description: A native macOS window for editing one EPUB.
colors:
  accent: "AccentColor"
typography:
  welcome-title:
    fontFamily: "system-ui"
    fontSize: "30pt"
    fontWeight: 700
rounded:
  cover: "3pt"
  cover-placeholder: "5pt"
  description: "6pt"
  type-sample: "8pt"
  drop-target: "12pt"
spacing:
  field-label: "6pt"
  cover-stack: "14pt"
  field-columns: "16pt"
  sample-inset: "18pt"
  form-stack: "20pt"
  section-gap: "24pt"
  editor-inset: "28pt"
components:
  cover-area:
    width: "144pt"
    height: "202pt"
  type-sample:
    rounded: "{rounded.type-sample}"
    padding: "{spacing.sample-inset}"
---

# EPUB Edit

## Overview

Each document window keeps the book cover in view while the reader edits its details or formatting. The welcome window centers the app icon and the Open EPUB action. Both use standard macOS controls.

## Colors

SwiftUI supplies the text and surface colors. The cover column and the Finder instructions use the `.bar` style. Help text, the EPUB version, and the cover placeholder use `.secondary` foreground. The placeholder uses a `.quaternary` fill at 65% opacity. The description and type sample use `.background` with a 1 pt `.separator` stroke. The welcome window shows the system accent around its drop target while a file hovers over it.

## Typography

Use macOS system text styles for the editor. Section headings use `.title2.bold()`, field and sample labels use `.headline`, and the description uses `.body`. Help text uses `.callout` and the EPUB version uses `.caption`.

The reading sample uses an 18 pt system serif for Book default and Serif, and the system default design for Sans serif. Its extra line spacing is 2, 6, or 11 pt for Book default, Comfortable, or Spacious respectively.

## Layout

All dimensions are macOS layout points. The editor opens at 760 × 610 and resizes down to 640 × 505. A divider separates the fixed 192 pt cover column from the flexible form. The section picker uses its native width above the scrollable fields. Publisher and Language share a row, with 108 pt reserved for Language. The formatting grid is at most 350 pt wide.

The welcome window opens at 520 × 380. An 86 × 86 pt app icon sits above the title, with the Finder instructions in a bar along the bottom.

## Elevation & Depth

The cover thumbnail uses a black shadow at 16% opacity, with a 5 pt radius and a 3 pt downward offset. Dividers and native materials distinguish the other surfaces.

## Shapes

The thumbnail fits the cover area and preserves the image’s aspect ratio. Its clip has slightly tighter corners than the empty cover placeholder. On the welcome window, the drop outline has a 3 pt stroke.

## Components

- **Open and Save.** Open EPUB uses a large bordered prominent button. Save is a prominent item at the trailing end of the unified document toolbar and enables when the document has edits.
- **Document controls.** A segmented control switches between Details and Formatting. Fix for Kindle sits at the trailing edge of the same row. The result appears below, with Show in Finder for a completed export.
- **Metadata fields.** Large rounded-border text fields have labels above them. The multiline description has a minimum height of 105 pt and an ideal height of 125 pt.
- **Cover.** Place the cover action below the image and the EPUB version below the action. A missing or unreadable preview shows a book symbol and a text explanation.
