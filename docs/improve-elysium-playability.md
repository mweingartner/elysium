# Documentation: Improve Elysium Playability

## Purpose

This change closes four survival-loop failures: hostile monsters that ignored
daylight, creepers that could cancel a started fuse and keep chasing, villagers
without a complete trustworthy barter interaction, and generated structures that
could be flooded or unusable. It makes those systems predictable from visible
world and UI state while preserving Elysium's deterministic simulation.

## Value

Players can rely on dawn as a consistent hostile-mob rule, treat every creeper
hiss as an irreversible warning, understand a merchant transaction before
committing it, and discover newly generated villages and dungeons that are
playable without repair. Maintainers gain shared daylight classification,
authoritative atomic barter receipts, bounded terrain planning, explicit cache
identity, and deterministic regression contracts for every changed output.

## Scope

Every registered `Monster` now follows one direct-sky daylight classifier.
Ordinary monsters ignite; creepers instead start a fuse with no more than 15
ticks remaining. A newly started proximity fuse has 30 ticks; later sunlight may
shorten that deadline to at most 15 remaining ticks but can never reset, pause,
lengthen, or release its latched horizontal position. The host owns fuse
simulation and LAN mirrors render only bounded optional presentation fields.

Adult professioned villagers and wandering traders expose deterministic ordered
catalogs through a passive trade sheet. Opaque one-shot receipts bind the local
game, world, player, merchant, revision, offer, inventory, reach, and line of
sight. LAN clients fail closed until a host-authoritative remote barter protocol
exists. Saves and merchant fields remain untrusted and bounded.

New village plans must validate dry support, headroom, safe spawns, and connected
roads before any write. Ordinary dungeons remain dry, cave-connected, and inside
their origin chunk; a region-budgeted minority may be deliberately underwater
but sealed and dry inside. Existing saved full chunks are not migrated, repaired,
or rewritten, and mixed old/new generation seams remain supported. This change
does not add mobs, items, professions, public networking, waypoints, HUD warnings,
or automatic legacy-world repair.

## Functional details

- Direct qualifying daylight ignites every non-creeper hostile monster. The
  ignition classifier excludes skyless dimensions, shade or low skylight,
  qualifying rain, water, powder snow, valid head protection, and an existing
  fire state. Separately, the existing entity fire logic extinguishes active fire
  in water or powder snow. Flame rendering is driven by authoritative `fireTicks`
  and uses bounded effect density.
- Creeper proximity and sunlight triggers enter the same irreversible state.
  The hiss occurs once, x/z is latched, navigation and horizontal velocity stop,
  LAN clients never advance the timer, and explosion occurs at most once. A new
  proximity fuse lasts 30 ticks, a new sunlight fuse lasts 15, and sunlight on an
  active proximity fuse leaves no more than 15 ticks without lengthening its
  existing deadline.
- Merchant catalogs are profession-specific and ordered across five levels. The
  UI states `Villager wants`, every payment and current holding, `You receive`,
  result count, stock, XP/level, restock/workstation state, and a precise disabled
  reason. Selection and focus have separate non-color geometry; pointer,
  keyboard, controller, tooltips, and macOS Accessibility share one selection and
  commit path.
- Trade preparation is read-only. Commit revalidates authority and all receipt
  bindings, simulates payment plus output on a detached inventory, then publishes
  inventory, use count, XP/level, restock state, and merchant revision together.
  Any failure changes nothing; replay and competing stale receipts fail.
- Structure validation uses the same pure base-terrain function as generation,
  complete cache keys, single-flight computation, hard attempt/member/byte/cache
  caps, and detached output. Rejected candidates emit no blocks, block entities,
  or entities. Actual-output tests count at least 256 committed dungeons and cap
  underwater results at one sixteenth.

## Usage

At dawn, an exposed ordinary hostile visibly catches fire. An exposed creeper
immediately hisses, stops moving horizontally, uses the rapid visible pulse, and
explodes within 15 ticks even if the player moves away; a newly started
proximity-triggered fuse uses 30 ticks and cannot be cancelled. If sunlight
accelerates an active proximity fuse, it leaves at most 15 ticks and never delays
an earlier explosion.

To barter, use the normal use/place action on an adult professioned villager or
wandering trader in local play or as the LAN host. Review the merchant's wanted
resource summary and scroll the complete offer list. Select with pointer,
Up/Down, Home/End, Page Up/Page Down, or controller navigation. The detail pane
shows the exact payment, current holdings, result, stock, and any blocking reason.
Activate `Trade` once when enabled; success updates in place, while missing
payment, level, stock, range, line of sight, stale state, replay, or insufficient
capacity consumes nothing.

When exploring new terrain, villages either appear on validated dry connected
sites or are omitted after bounded candidate attempts. Ordinary dungeons are dry
and cave-connected. Rare underwater dungeons are intentionally sealed with a dry
interior. Previously saved full chunks retain their existing contents.
