---
name: visualize
description: Native macOS service management with the restraint of Apple System Settings.
rounded:
  inset-surface: "10pt"
  widget-hover: "8pt"
spacing:
  surface-padding: "14pt"
  section-gap: "12pt"
  detail-padding: "24pt"
  widget-padding: "12pt"
---

# Design System: visualize

## Overview

**Creative North Star: "Apple System Settings"**

Use familiar macOS controls, quiet neutral surfaces, and a clear hierarchy of project, service, and supporting details. Keep the established sidebar, toolbar, and Docker footer. This document covers the existing project detail, service graph cards, and menu bar popover; it does not prescribe new product surfaces.

**Key Characteristics:**
- Native SwiftUI controls and semantic system typography.
- Neutral adaptive surfaces with monochrome technology icons.
- Compact summaries with supporting details behind disclosures.

Evidence comes from SwiftUI source review. Running-app screenshots and interaction verification were blocked by denied Computer Use access; no visual pass is claimed.

## Colors

The existing neutral palette follows macOS appearance through semantic colors. Native color expressions are recorded in `.impeccable/design.json`, rather than fixed CSS approximations.

### Neutral
- `Color(nsColor: .controlBackgroundColor)` supplies inset surfaces and graph cards.
- `.primary` supplies primary text, neutral control tint, and widget hover shading.
- `.secondary` supplies metadata; template technology icons use native label color at 0.85 opacity; `.tertiary` supplies subtle chevrons.
- `.green`, `.orange`, `.red`, and `.gray` retain their operational status roles. These are state signals, not decorative brand accents.

**The Adaptive Neutral Rule.** Preserve native semantic colors across light and dark appearances; do not substitute a fixed gray palette or colored technology logos.

## Typography

Use the system font through SwiftUI semantic styles. Project names use `.title.bold()`; service names and section headings use `.headline`; summaries and controls use `.callout`; paths and auxiliary metadata use `.caption`, with `.caption2` for widget chevrons. Disclosure labels can use `.callout.weight(.medium)`.

Reserve monospaced text for commands, environment variable names, and graph ports. Use monospaced digits for numeric ports, counts, and PIDs. Paths use ordinary system text with middle truncation where specified by the view.

## Layout

Project detail is a leading-aligned scrolling column capped at 1040pt including its 24pt padding. Groups use 12pt spacing. Section headings add 16pt above and 2pt horizontally. Service summaries use 10pt internal spacing and 16pt between metadata items; `ViewThatFits` changes metadata from a horizontal row to a vertical stack when needed.

The menu bar popover is 400pt wide with 12pt padding and screen-height-limited scrolling. Listener rows use 10pt horizontal and 8pt vertical padding. The main window retains `NavigationSplitView`, its 200pt minimum / 240pt ideal sidebar, native toolbar, bottom Docker status, and 720 × 440pt minimum size.

## Elevation & Depth

Inset surfaces and graph cards use flat tonal layering without custom shadows or material fills. Native controls retain their platform rendering. Graph selection uses a primary-color stroke at 0.7 opacity and 2pt width; unselected cards use secondary at 0.2 opacity and 1pt width.

## Shapes

Use the frontmatter's rounded inset surface and softer widget hover shape. `InsetSurface` supplies the shared padding and background; its compact form removes both so running-instance details fit inside an existing service surface. Graph cards use the inset radius and measure 260 × 116pt.

## Components

### Service and infrastructure surfaces

`InsetSurface` groups service, infrastructure, Compose, and standalone running-instance content. Service summaries keep identity, status, port, run controls, and missing-environment warnings visible. The collapsed Details disclosure contains the command, run mode, and environment details. Compose files and running-instance metadata use native disclosures.

### Technology icons

`TechnologyIcon` uses bundled Simple Icons PDF assets with filled paths and 1pt internal padding, as templates with native label color at 0.85 opacity. Sizes are 16pt in graph and widget group headers, 18pt in widget rows and service and infrastructure surfaces, and 24pt in project headers. Unknown technologies use the menu-bar `circle.hexagongrid` symbol in light weight, rendered with the same monochrome treatment. Preserve adjacent text labels; the icons are accessibility-hidden.

### Menu bar rows

Use plain buttons for project identity and ports, with separate stop/restart controls. Hover adds primary color at 0.05 opacity and clears on exit. Rows have no persistent selection state. Clicking the project identity opens the corresponding saved project in the main window; unmatched listeners open the main window. Port buttons open localhost separately.

### Native controls and navigation

Preserve native buttons, menu pickers, disclosures, disabled states, help text, and confirmations. Service and project-header controls use small control size and neutral primary tint. Preserve the sidebar's native project selection; the widget's absence of selection does not apply to the sidebar or graph.

## Do's and Don'ts

- **Do** use native semantic colors and typography.
- **Do** preserve the sidebar, footer, and toolbar structure.
- **Do** keep status and immediate actions visible while disclosing supporting details.
- **Do** keep technology icons monochrome and use the visualize menu-bar symbol fallback.
- **Don't** add persistent widget row selection.
- **Don't** replace native components with web-style approximations or decorative brand colors.
- **Don't** claim a visual or interaction pass from source review alone.
