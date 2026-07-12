# RPG Pixel-Font Glyph Remediation Plan

## Design Mock — production glyph fidelity

**Verdict: PASS.** This repair makes the ordinary Metal-rendered RPG surface display the already
approved model copy. It introduces no new wording, controls, states, or interaction.

### Observed user-visible failure

The real installed screenshot
`/tmp/pebble-storage-launch-proof-20260711/disposable-rpg-window.png` renders required Unicode
characters as the bitmap font's fallback `?`: the preset and footer lose `·`, the selected adornment
loses `✓`, and the same production path cannot faithfully present directional arrows or frozen
typographic punctuation. The AppKit harness is not sufficient evidence because it uses a system
font rather than the production Metal bitmap atlas.

### Required glyph contract

The production pixel font must provide distinct, non-fallback glyphs for every bare one-scalar Swift
`Character` already used by approved RPG visible copy:

| Scalar | Name | Required RPG use and recognizable shape |
| --- | --- | --- |
| `·` U+00B7 | middle dot | centered separator in attributes, costs, summaries, and footer help; not a baseline period |
| `✓` U+2713 | check mark | selected-card non-color cue; rising two-stroke check, not `/`, `V`, or `?` |
| `←` U+2190 | left arrow | `← Move Left`; full shaft plus unambiguous left head |
| `→` U+2192 | right arrow | `Move Right →`; full shaft plus unambiguous right head |
| `’` U+2019 | right single quotation mark | frozen possessive/contraction copy such as `host’s`; upper punctuation, not a question mark |
| `…` U+2026 | horizontal ellipsis | one glyph containing three evenly spaced baseline-centered dots |
| `—` U+2014 | em dash | frozen status/detail separation; centered horizontal stroke visibly longer than ASCII hyphen |

ASCII punctuation and letters retain their existing pixels and advances. Required Unicode scalars
may never route to the fallback glyph. Unsupported scalars may continue to use the existing bounded
fallback; this change does not broaden accepted model/input grammar.

Each key below is the exact scalar with no variation selector, combining mark, normalization, or
ASCII substitution. Drawing and measurement continue to iterate Swift extended grapheme clusters.
A multi-scalar grapheme such as `✓\u{FE0F}` is unsupported and must resolve once to the existing
fallback in both paths; it may not be split into separately drawn/measured UTF-8 bytes or scalars.
No normalization is added. Approved RPG copy retains the bare listed scalar.

### Pixel geometry and readability

- Each required glyph is drawn on the canonical bitmap grid with integer pixel placement, the same
  baseline, cap region, logical cell height, and non-antialiased edge language as the existing Pebble
  font.
- Strokes remain at least one source pixel and retain an open counter or directional gap where
  needed, so nearest-neighbor scaling cannot merge `✓`, `←`, `→`, `’`, `…`, `—`, `·`, and `?`.
- Glyphs remain recognizable and fully inside their logical cell at every RPG text scale currently
  used by header, authority/help, card, row, operation, status, and footer rendering at 360x224,
  520x330, and 700x420.
- Standard and High Contrast use the existing foreground tokens; High Contrast changes contrast,
  not glyph identity, advance, baseline, wrapping, or copy. No required distinction becomes
  color-only.

### Measurement and wrapping parity

- The model's approved string, `visualLines`, and semantic/accessibility copy remain byte-for-byte
  unchanged. Neither renderer substitutes ASCII spellings such as `*`, `v`, `->`, `<-`, `'`, `...`,
  or `-`, and no caller sanitizes required Unicode into fallback-safe copy.
- Production measurement must assign every required bare one-scalar `Character` its real glyph
  advance. Drawing and measuring use the same `Character`-to-glyph mapping; no UTF-8 byte or scalar
  inside one extended grapheme is measured or drawn as a separate character.
- Model-owned wrapping remains authoritative. The Metal renderer and AppKit harness consume the
  same complete `visualLines` and may not independently rewrap, clip, ellipsize, or reconstruct
  punctuation. Required glyph advances must fit every existing model-approved frame without moving
  a control, widening a hit target, or changing focus/reveal geometry.
- Standard and High Contrast captures must have identical line breaks, baselines, descriptor
  frames, and semantic IDs. Only the existing appearance colors/focus geometry may differ.

### Accessibility and interaction invariants

- Accessibility label/value/help and VoiceOver announcements retain the original Unicode strings;
  the bitmap glyph lookup is visual-only.
- Semantic IDs, commands, actionability, focus order, hit frames, scrolling, authority precedence,
  and receipt/origin validation do not change.
- The selected state continues to expose check shape, literal `Selected`, and double border. Move
  controls retain both their directional glyph and complete literal label. Glyph support is not a
  substitute for the existing non-color text and geometry.

### Ordinary installed acceptance

After Security and Test PASS, a fresh signed `/Applications/Pebble.app` must be inspected through
the production Metal renderer, not only the AppKit harness. At all three required viewports, capture
standard and High Contrast evidence containing:

1. **Creation Path:** selected card shows a real `✓`; preset separators render as `·`; `Path`, card
   copy, icon, selected literal, and double border remain unchanged and unclipped.
2. **Creation Review:** path/branch, attributes, cost/guidance, and chord rows render every `·`, `’`,
   `…`, or `—` present in the exact model copy without fallback or changed line breaks.
3. **Footer:** `Back · Next` renders the centered middle dot and remains disjoint from fixed
   Back/Next/Create/Close controls.
4. **Move controls:** `← Move Left` and `Move Right →` render distinct full arrows, complete labels,
   unchanged directional adornments, and unchanged half-open hit frames.
5. **Authority/status:** exercise exact frozen help/status strings containing `host’s`, `…`, or `—`
   where applicable; visible text, semantic summary, and accessibility copy must match exactly.

For every capture, compare production pixels with the semantic/model string and record the installed
executable hash/signature. Automated atlas/measurement checks must prove each required scalar maps
to a unique non-fallback glyph, round-trips through draw and measure, preserves model line breaks,
and remains within its cell at every shipped RPG scale. Pixel inspection must explicitly reject any
`?`, tofu box, clipped stroke, merged arrow/check, baseline drift, copy substitution, or
standard/High-Contrast geometry divergence. Any RPG copy, layout, accessibility, authority, or
interaction change returns to Design Review rather than being accepted as a font fix.

## Architecture — frozen production pixel glyphs

### Decision and production surface

The defect is confined to `Sources/Pebble/UICanvas.swift`. `drawText`, `glyphWidth`, and
`textWidth` already iterate Swift `Character` values and share the
`GLYPHS[ch] ?? GLYPHS["?"]!` fallback. The resource-pack branch is deliberately limited to
U+0020...U+007E, so these seven non-ASCII scalars must use Pebble's deterministic built-in glyphs
even when `font/ascii.png` is active. No RPG model, layout, renderer, resource-pack parser,
accessibility, or Core API change is required.

Append exactly these entries to `GLYPHS`. Arrays are left-to-right columns; bits are the existing
top-to-bottom rows. The advance remains the existing `columns.count + 1` contract.

| Scalar | Frozen columns | Advance |
| --- | --- | --- |
| `·` | `[0x18]` | 2 |
| `✓` | `[0x20, 0x40, 0x20, 0x10, 0x08, 0x04]` | 7 |
| `←` | `[0x08, 0x1c, 0x2a, 0x08, 0x08, 0x08, 0x08]` | 8 |
| `→` | `[0x08, 0x08, 0x08, 0x08, 0x2a, 0x1c, 0x08]` | 8 |
| `’` | `[0x01, 0x03, 0x06, 0x04]` | 5 |
| `…` | `[0x40, 0x00, 0x40, 0x00, 0x40]` | 6 |
| `—` | `[0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08]` | 8 |

These values are frozen, not illustrative. Every set bit stays in rows 0...6; the middle dot is
distinct from baseline `.`, arrows have full shafts and opposite heads, the quote stays high, the
ellipsis is one three-dot glyph, and the em dash is longer than ASCII `-`. Do not alias `✓` to
existing `✔`, substitute ASCII, synthesize at runtime, load these scalars from a pack, or add a
second advance table.

Built-in measurement/draw parity remains structural: `drawText` advances by `g.count + 1`,
`glyphWidth` returns the same value, and `textWidth` delegates non-pack characters to `glyphWidth`.
Preserve the one-scalar `32 <= value < 127` pack range in both paths. Drawing additionally requires
the pack GUI texture, while `applyResourcePacks` installs and clears that texture and
`packFontWidths` together on the existing main-thread lifecycle; do not claim the predicates are
textually identical. All seven required non-ASCII characters bypass pack widths in synchronized
nil/nil and texture/widths states. An unmatched trailing `§` is outside approved RPG copy; exercised
approved strings must contain no introducer or complete two-Character format pairs before claiming
draw/measure parity.

### Files and verification

1. Edit only production file `Sources/Pebble/UICanvas.swift` to add the seven rows. Do not edit
   `RPGScreensM.swift`, `RPGScreenModel.swift`, `RPGUIHarnessM.swift`, `RPGUIHarness.swift`, or
   `ResourcePacks.swift` unless review first proves the existing routing predicate has drifted.
2. Add `Tests/PebbleCoreTests/RPGPixelFontSourceTests.swift`, using the existing App-target
   source-test pattern. Parse/assert the exact seven bitmaps and advances; prove each is nonempty,
   uses only row bits 0...6, differs from `?`, every pre-existing glyph, and the other six; rasterize
   each into an isolated eight-row monochrome bitmap and compare checked inline pixel snapshots.
   Require each new key exactly once and exactly 108 unique total keys. After removing the seven exact
   appended entry lines, the existing `GLYPHS` declaration must reproduce the reviewed 101-key
   baseline SHA-256 `9c8db10f4946068dfcb52ceeb0df4a6cc16a849dbadaf9a30a9d677eafe35860`.
3. In that test, source-audit `drawText`, `glyphWidth`, and `textWidth`: the required scalars resolve
   through `GLYPHS`; draw and measurement derive the same advance; `§x` remains zero-width;
   unsupported one-scalar characters and multi-scalar graphemes still use one `?`; pack ASCII remains
   32...126; required characters bypass pack widths in nil and active synchronized pack states; and
   neither `UICanvas.swift` nor `RPGScreensM.swift` substitutes ASCII for required copy.
4. Retain the existing exact model tests, especially `← Move Left` / `Move Right →`, complete
   `visualLines`, selected adornment, and semantic/accessibility copy. Add a narrow model-source
   assertion only if needed to collect all seven scalars; it may assert copy but never rewrite it.
5. A fresh release changes Pebble, not PebbleCore, PebbleStorage, or `pebsmoke`. Update only the
   reviewed Pebble product hash in `scripts/verify-pebble-storage-release-surface.sh` after the exact
   warning-free build if all other pins remain exact. Any other API, manifest, object, product, or
   production-file delta fails this architecture gate.
6. Add no production DEBUG/SPI/package test seam. The new test keeps its trusted-source parser and
   rasterizer entirely in the test target. Security(code) confirms no new glyph mutator, callback,
   cache, environment switch, symbol, or resource-pack input reaches release beyond the seven
   immutable entries.

### Risk-to-evidence map

| Risk | Required evidence |
| --- | --- |
| Required copy still renders `?` | Exact source lookup test for all seven; installed Metal screenshots |
| Draw and measured widths diverge | Frozen advance assertions plus mixed ASCII/Unicode source test |
| Pack overrides required glyphs | Default-pack, user-pack ASCII, and procedural-fallback routing assertions |
| Grapheme or formatting handling splits/under-measures text | Bare one-scalar and multi-scalar fallback cases; complete-format-pair audit for approved strings |
| Existing glyphs drift under the repair | Exact 101-key baseline declaration hash after removing the seven reviewed lines |
| Glyph clips or becomes ambiguous | Isolated bitmap snapshots and installed inspection at every RPG scale |
| Copy/layout/accessibility changes hide the defect | Unchanged model/renderer diff plus existing model, renderer-source, semantic, and accessibility suites |
| Stale or harness renderer is inspected | Fresh verifier, installed hash/signature, and `/Applications/Pebble.app` screenshots |

### Dependency order

1. Design Mock above — **PASS**.
2. This Architecture contract — **PASS**.
3. Design Review validates the bitmaps at 360x224, 520x330, and 700x420; Security (plan) validates
   bounded static data, pack isolation, and no input/API expansion.
4. Builder adds the seven entries, then the isolated/source tests, with no copy workaround.
5. Security (code) reviews the exact diff. Tester runs the new tests; affected RPG model, renderer,
   semantic, and accessibility suites; source scan; warning-free release; full XCTest; 457-check
   `pebsmoke`; release verifier; and pipeline.
6. Install that exact signed build. In the ordinary installed Metal app—not the AppKit harness—open
   the real RPG screen and capture standard and High Contrast creation, review, footer, move-control,
   and authority/status states at all three viewports. Compare visible pixels to semantic/model copy,
   reject `?`, tofu, clipping, changed wrapping, or control movement, record executable hash/signature,
   and prove normal launch remains live. Code changes invalidate installed evidence.

### Conditions for Builder

- Add exactly seven built-in glyphs with the exact columns and advances above; preserve all existing
  glyphs, pack ASCII, formatting codes, fallback, baseline, and scaling.
- Preserve RPG strings, `visualLines`, semantic IDs, accessibility label/value/help, descriptor and
  hit frames, focus/scroll state, authority precedence, commands, and controller/keyboard behavior.
- Add no font asset, dependency, parser, cache, mutable registry, public/package/SPI API, model
  sanitization, renderer rewrap, or resource-pack Unicode trust path.
- Preserve the dirty worktree, stage only this correction, and derive the product hash only from the
  exact reviewed release artifact.

**Architecture verdict: PASS.** Static UICanvas glyph coverage is the smallest sufficient change to
make approved RPG Unicode copy measurable and drawable in production. Build remains blocked until
Design Review and independent Security-plan PASS. Any model copy, pack parsing, layout,
accessibility, API, or dynamic-font change returns to Architecture.

## Security (plan) review — 2026-07-11

Security reviewed the pre-amendment plan at SHA-256
`674ec70e3f77438eddefc451c0dbea06c6b90e5dd90b365bb5d073f9a652a564`. The bounded immutable
seven-entry approach introduces no new untrusted parser or resource-pack capability. Three details
were made binding above: keys are exact bare one-scalar Swift `Character` values while multi-scalar
graphemes fall back once without normalization; pack routing preserves the existing main-thread
synchronized texture/width lifecycle without falsely claiming textually identical predicates; and
the pre-existing 101-key declaration is frozen by an independently captured baseline hash.

Each frozen bitmap has at most seven columns, only row bits 0...6, and an advance of columns plus one,
so lookup, raster work, and width arithmetic remain constant and bounded per `Character`. Required
non-ASCII keys cannot enter the U+0020...U+007E pack branch. The source-only test adds no release
seam. RPG copy, wrapping, semantics, accessibility, hit/focus geometry, receipts, and resource-pack
parsing remain outside Builder authority; all unchanged object, manifest, Core/storage product, and
pebsmoke pins remain exact while only Pebble is renewed.

**Security(plan) verdict: PASS.** Build is authorized only for the exact seven immutable entries and
test-only source/raster assertions above. Security(code), affected tests, warning-free release, pin
verifier, signed install, and ordinary Metal-renderer pixel proof remain mandatory downstream.

## Builder evidence — 2026-07-11

Builder implemented the approved plan at SHA-256
`aa8ae48f497076852acd12911b624a94f55301eabddc7fed5bb6942876b70c24`. The only production
change is the seven exact frozen `GLYPHS` entries in `Sources/Pebble/UICanvas.swift`. No RPG copy,
model, layout, renderer routing, accessibility, resource-pack parsing, API, cache, or mutable font
surface changed.

`RPGPixelFontSourceTests` parses the production declaration and proves 108 unique keys with every
new key occurring once; the seven exact bitmaps and advances; nonempty row-0...6 bounds; no alias
with `?`, any of the 101 prior glyphs, or another new glyph; checked inline eight-row rasters;
baseline/cap placement and shipped RPG scale bounds; default and synchronized active ASCII-pack
routing; draw/measure advance parity; zero-width complete formatting pairs; one-fallback behavior
for unsupported one-scalar and multi-scalar graphemes; and unchanged approved RPG source copy. After
removing the seven exact appended lines, the declaration reproduces the reviewed 101-key SHA-256
`9c8db10f4946068dfcb52ceeb0df4a6cc16a849dbadaf9a30a9d677eafe35860`.

Verification evidence, all final exit status 0:

- `swift test --filter RPGPixelFontSourceTests`: 5 tests, 0 failures;
- affected pixel-font/model/renderer/semantic/accessibility/source suites: 84 tests, 0 failures in
  22.970 s;
- full `swift test`: 967 tests, 0 failures in 222.078 s;
- `swift build -c release`: warning-free, completed in 103.39 s;
- `bash scripts/security-scan.sh`: passed, including the 126-file SQLite boundary scan;
- `swift run -c release pebsmoke`: 457 passed, 0 failed;
- `bash scripts/verify-pebble-storage-release-surface.sh`: verified after the final release rebuild;
- `git diff --check`: passed.

Reviewed SHA-256 consequences:

- `Sources/Pebble/UICanvas.swift`:
  `023b65e2d6e8b45ab62f3059b8b92df7f54f71310e528f6fb558996b28456a42`;
- `Tests/PebbleCoreTests/RPGPixelFontSourceTests.swift`:
  `9ab94f3f921722e0ebeefea6d4c9dc7df1fa77e4a7086d3cafe37e5ca74d06cb`;
- `scripts/verify-pebble-storage-release-surface.sh`:
  `128f773532c2a729cc8274605d0bc27ac84ad4373dc810e8e574299fbb067709`;
- fresh Pebble product:
  `3bbff96d8154f412b6c8745b05745f3056037d5322c761b67b7143cb26a4df60`.

Every artifact required to remain stable did so after the warning-free build and the later
`pebsmoke` release-graph rebuild: `PebbleStorage.o`
`ed37590e383037968b25905cb7ecd1d29e8faa43ba1f62a4919baebf9aabc6ba`, `PebbleCore.o`
`7e7caeec1e760a60739736ad240993562bd972e29e6a03c6c54ace486b37751a`, and `pebsmoke`
`5e1d47e14ab3e427a0ff35ef6ae2a00b887d38c5c53883bf2afc40a556e5f2ec`. Accordingly, Builder
renewed only `EXPECTED_PEBBLE_PRODUCT_SHA256`; all other verifier pins remained exact.

**Builder verdict: PASS.** Production and automated release gates are green. Per the assigned
Builder boundary, no installation, deployment, ordinary installed Metal screenshot proof, commit,
or push was performed; those downstream gates remain for the owning orchestrator.

## Security (code) review — 2026-07-11

**Security(code) verdict: PASS.** Security independently reviewed the implementation against the
approved plan SHA-256 `aa8ae48f497076852acd12911b624a94f55301eabddc7fed5bb6942876b70c24`.
The production `UICanvas.swift` hash is
`023b65e2d6e8b45ab62f3059b8b92df7f54f71310e528f6fb558996b28456a42`. Removing exactly the
seven reviewed entry lines reconstructs the complete pre-change production file byte-for-byte at
SHA-256 `f5a7fb711bbdd3f6f96a5cd9884857b4dd6f317b4e234e69359c67094e6b6970`; therefore no draw,
measurement, fallback, formatting, pack, cache, parser, renderer, or other UICanvas behavior changed.

The parsed table contains exactly 108 unique keys. Each new bare one-scalar `Character` occurs once
with the frozen columns and columns-plus-one advance, is nonempty, uses only row bits 0...6, and is
distinct from the fallback, all 101 prior glyphs, and the other six additions. Removing the seven
lines reproduces the reviewed declaration hash
`9c8db10f4946068dfcb52ceeb0df4a6cc16a849dbadaf9a30a9d677eafe35860`.
Independent raster review confirms the centered middle dot, rising check, mirrored full arrows,
high right quote, three-dot ellipsis, and seven-column centered em dash remain within the frozen cell.

`drawText` and `glyphWidth` still resolve one Swift `Character` through the same immutable
`GLYPHS[ch] ?? GLYPHS["?"]!` mapping and use `columns.count + 1`; `textWidth` still delegates
non-pack characters to `glyphWidth`. The seven non-ASCII characters cannot satisfy the unchanged
single-scalar U+0020...U+007E pack range. Unsupported one-scalar and multi-scalar graphemes still
fall back exactly once, no normalization or scalar/UTF-8 splitting was added, and complete formatting
pairs retain their zero-width behavior. Resource-pack installation/parsing is unchanged and
`ResourcePacks.swift` is git-clean.

The reviewed RPG model, production/harness renderers, semantic/accessibility sources, IDs, commands,
copy, wrapping, and geometry hashes remain unchanged. No production DEBUG/SPI/package seam, glyph
mutator, callback, environment switch, dynamic asset, or Unicode resource-pack trust path was added.
The source-only test hash is
`9ab94f3f921722e0ebeefea6d4c9dc7df1fa77e4a7086d3cafe37e5ca74d06cb`; its parser enforces unique
keys and exact full-table baseline recovery rather than merely searching for glyph spellings.

Independent closing evidence:

- `RPGPixelFontSourceTests`: **5 tests, 0 failures**;
- release-surface verifier: PASS, exit 0, with explicit `Pebble storage release surface verified.`;
- fresh Pebble hash/pin:
  `3bbff96d8154f412b6c8745b05745f3056037d5322c761b67b7143cb26a4df60`;
- replacing only that pin with its prior value reconstructs the complete pre-remediation verifier at
  SHA-256 `47ed918601ac8a7962b9e65a2d9ccf4cf52518a98d5a734d5c6d376a6043a9f7`;
- unchanged release artifacts remain exact: `PebbleStorage.o`
  `ed37590e383037968b25905cb7ecd1d29e8faa43ba1f62a4919baebf9aabc6ba`, `PebbleCore.o`
  `7e7caeec1e760a60739736ad240993562bd972e29e6a03c6c54ace486b37751a`, and pebsmoke
  `5e1d47e14ab3e427a0ff35ef6ae2a00b887d38c5c53883bf2afc40a556e5f2ec`;
- the Pebble artifact is newer than `UICanvas.swift`, and `git diff --check` passed.

No Security(code) finding remains. This PASS does not claim signed installation, ordinary installed
Metal-renderer glyph inspection, deployment, commit, or push. Any production, test, verifier, pin,
or artifact change invalidates this review.
