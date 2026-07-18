# Elysium Player Guide

## Purpose

Provide one canonical, player-facing reference for Elysium's current beta instead of requiring players
to assemble gameplay instructions from the README and feature-release documents. The guide supports a
first playable session and later task-based lookup while keeping installation and contributor workflows
in their existing documents.

## Value

New players can move from **Singleplayer** through world creation, first-day play, and a safe save-and-
quit path without assuming prior Minecraft knowledge. Returning players can quickly find verified help
for controls, maps, crafting, six optional character classes, trading, saved worlds, LAN play, object
templates, accessibility, and local AI. Two compact README entry points make the guide discoverable from
the repository landing page and the existing controls section.

## Scope

The release adds the root-level `PLAYER_GUIDE.md` and two relative links in `README.md`; it changes no
game code, defaults, persistence format, networking, packaging, assets, tests, or goldens. The guide
describes current Elysium behavior rather than Minecraft behavior and intentionally is not a recipe,
item, mob, command, or strategy encyclopedia.

Consequential guidance is bounded by current trust and safety constraints: world deletion is permanent
and requires a verified full-folder backup for any recovery attempt; multiplayer is trusted-LAN-only,
host-owned, and does not provide matchmaking, relay, NAT traversal, hostile-network protection, or
complete identity anonymity; and the optional AI surface requires an independently operated local
Ollama service whose retention and onward handling Elysium does not control. The guide uses passive
Markdown, repository-relative documentation links, the canonical GitHub Issues destination, and the
private vulnerability-reporting route in `SECURITY.md`.

## Functional details

- `PLAYER_GUIDE.md` renders as one H1 followed by twelve ordered task-oriented H2 sections and a linked
  contents list. It covers the first-world flow, creation/loading/death recovery states, the complete
  current controls model, HUD/maps, core survival and crafting, exploration, RPG progression, trading,
  saved-world management, LAN, templates, options/accessibility/AI, and troubleshooting/beta limits.
- The controls reference accounts for all 25 configurable default bindings exactly once and separates
  them from fixed hotbar, pause, HUD/debug/fullscreen, map, and template shortcuts. Text-entry guidance
  names only currently shipped fields and explicitly excludes map-name and saved-world-rename fields.
- Character guidance covers Warden, Ranger, Delver, Arcanist, Mender, and Tinker; retained class drafts;
  Class -> Foundation -> Review creation; validation blockers; five character tabs; always-on passive
  skills, prepared active skills and spells; quick slots; fatigue/cooldowns; and class-specific
  progression distinct from ordinary
  experience and Advancements.
- Trading, deletion, LAN, and AI sections place limitations and recovery actions beside the affected
  workflow. Troubleshooting distinguishes recipe-search empty states, disabled or stale trades, invalid
  RPG creation, unavailable LAN/Ollama, saved-world reload states, controls/text focus, and performance
  or accessibility issues.
- Documentation checks passed with one H1, 12 ordered H2s, 14 H3s, 12 of 12 unique contents anchors,
  15 resolved guide links, two README guide links, 25 of 25 control definitions, and 70 required current
  UI, recovery, and safety strings. A warning-free release build passed, 316 focused XCTest cases and
  1,163 full-suite XCTest cases passed with zero failures, and the complete `elysmoke` contract passed
  457 checks with zero failures and no regolding. Commit hooks, GitHub rendering, and local/remote SHA
  parity remain publication-gate evidence.

## Usage

- A new player opens the README's **Player Guide** link, follows **Singleplayer** -> **Create New** ->
  **Create World**, waits through generation/loading states, completes the first-day checklist, then
  uses **Escape** -> **Save & Quit to Title**.
- A returning player uses the guide's contents to jump directly to controls, character progression,
  trading, saved-world management, or LAN hosting/joining without rereading the first-session path.
- Before deleting worlds, the player quits Elysium, copies and verifies the complete Elysium application-
  support folder, reviews every selected world in the Cancel-first confirmation, and proceeds only when
  permanent deletion is intended.
- A player with an independently running local Ollama service reviews the disclosed game-context data
  flow, selects a local model under **Options... -> Ai**, and uses `/ai <request>` knowing that AI is
  optional and output can be rejected or produce no usable action.
