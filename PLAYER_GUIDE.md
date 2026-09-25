# Elysium Player Guide

Elysium is a beta voxel survival game for macOS. This guide describes what the current Elysium game
actually supports; it does not assume that a feature works exactly as it does in Minecraft. For system
requirements and installation, start with the [Elysium project overview](README.md#install-and-run).

**Contents**

- [Quick start: your first world](#quick-start-your-first-world)
- [Controls and screen navigation](#controls-and-screen-navigation)
- [Understand the HUD and maps](#understand-the-hud-and-maps)
- [Core play loop](#core-play-loop)
- [Explore the world](#explore-the-world)
- [Usage-based skill trees](#usage-based-skill-trees)
- [Trade with villagers](#trade-with-villagers)
- [Save, manage, and recover worlds](#save-manage-and-recover-worlds)
- [Local-network multiplayer](#local-network-multiplayer)
- [Object templates](#object-templates)
- [Scripting, attributes, events, and AI](#scripting-attributes-events-and-ai)
- [Options, accessibility, and local AI](#options-accessibility-and-local-ai)
- [Troubleshooting and current limitations](#troubleshooting-and-current-limitations)

## Quick start: your first world

1. From the title screen, choose **Singleplayer**.
2. Choose **Create New**.
3. Enter a **World Name**. Leave **Seed** blank for a random seed, or enter one when you want to be
   able to generate the same starting terrain again with the same Elysium version and world-generation
   choices.
4. Choose **Survival** for gathering, crafting, hunger, damage, and progression, or **Creative** for
   building with broad item access and without ordinary damage, consumption, or durability costs.
5. Choose a difficulty. **Peaceful** suppresses ordinary hostile-monster spawning. **Easy**, **Normal**,
   and **Hard** retain hostile survival play at increasing challenge levels.
6. Choose a world type:

   - **Default** is the standard terrain generator.
   - **Superflat** creates a flat building world.
   - **Large Biomes** produces larger biome regions.
   - **Amplified** exaggerates terrain height.
   - **Rich Resources** combines ore-rich rolling hills with plentiful caves and more underground lava areas.
   - **Single Biome** adds a separate **Biome** choice.
   - **Nether World** starts you in the Nether beside an active portal, with basic iron tools and oak logs.
   - **Lost World**, **Jurassic Giants**, **Cretaceous Frontiers**, and **Ancient Seas** offer prehistoric
     wildlife, a supplied starter hut, extra caves and underground lava, and occasional small volcanoes.
   - **Reality Derived** opens an interactive Arnis map. Search for a location, draw or resize a
     rectangle, leave **Include buildings** checked to import OpenStreetMap and supplemental Overture
     buildings or clear it to omit buildings, then choose **Generate Map**. Real terrain and other mapped
     features such as roads and waterways remain in both cases. Keep the selection
     within the size message shown by the dialog; higher Scale values require a smaller rectangle.

   **Debug Mode** is an advanced diagnostic preset, not part of the normal cycle. Hold Option while
   activating **World Type** only if you deliberately want to expose that extra choice.
   Reality Derived generation downloads OpenStreetMap, elevation, and land-cover data and can take
   several minutes. The dialog remains cancellable. Elysium imports the completed selected area as
   ordinary authoritative chunks. A smooth 64-block transition outside the selected boundary joins the
   imported elevation to terrain from the Seed; exploration beyond it uses the standard generator.
   A failed or cancelled generation does not add a partial world to Saved Worlds.
7. Choose **Size**: **Small** is 1,000 blocks wide, **Medium** 4,000, **Large** 8,000,
   **Extra-Large** 12,000, and **Max** 15,811. Terrain is generated as you explore, so a larger
   choice does not allocate the whole map at creation. The edge is an invisible travel boundary with
   ordinary terrain continuing into the horizon, not a wall. Reality Derived applies the tier to the
   selectable real-world area; at 1×, Max reaches just under 250 km², while higher scales require a
   proportionally smaller selection.
8. For procedural world types, set **Dungeons** to **None**, **Normal**, **More**, **Plentiful**, or **Many**. **None** disables new
   dungeon placement; each later setting increases the number of placement attempts during generation.
9. Choose **Create World**. **Generating world...**, **Loading world…**, and **Building terrain** mean
   Elysium is working. Wait for the world to open; do not repeatedly submit creation.

### A practical first day

- Gather logs and turn them into basic building and crafting materials.
- Make a crafting table to move from the inventory's 2×2 crafting area to a 3×3 grid.
- Craft a wooden pickaxe, mine stone, and upgrade your tools.
- Collect food and make a lit shelter before exploring far from your starting area.
- Look at **Advancements** from the pause menu when you want the next major progression objective.
- Open **Skills** with `K` to see which real actions advance each tree and which advanced actions are
  ready for the fast bar.
- Press Escape and choose **Save & Quit to Title** when ending the session. Worlds also autosave during
  play, but **Save & Quit to Title** is the recommended clean exit.

### Pause, resume, or recover

Escape opens the paused **Game Menu**:

| Choice | What it does |
| --- | --- |
| **Back to Game** | Resume the current world. |
| **Advancements** | Review the main survival progression. |
| **Options...** | Change video, audio, world, controls, accessibility, or local-AI settings. |
| **Open to LAN** | Host the current local world on the local network. |
| **Save & Quit to Title** | Save and leave the current session. |

If **You Died!** appears, choose **Respawn** to return to the current world or **Title Screen** to leave
the session. Respawning is a death-recovery action; it is different from loading a saved world later.

## Controls and screen navigation

Open **Options... → Controls** to inspect or change gameplay bindings. Choose **Capture**, press the new
key or chord, and use **Reset** to restore that action's default. Escape cancels a capture. If the chord
conflicts with another action, Elysium shows the conflict before **Use Anyway** can apply it. Protected
macOS and application shortcuts cannot be assigned as gameplay controls.

### Configurable gameplay controls

These are the 25 current default bindings:

| Action | Default |
| --- | --- |
| Forward | `W` |
| Back | `S` |
| Left | `A` |
| Right | `D` |
| Jump | `Space` |
| Sneak | `Left Shift` |
| Sprint | `Left Control` |
| Inventory | `E` |
| Drop Item | `Q` |
| Chat | `T` |
| Command | `/` |
| Perspective | `F5` |
| Swap Offhand | `F` |
| Equip Torch (off-hand) | `G` |
| Equip Shield (off-hand) | `H` |
| Skills | `K` |
| Cycle Skill Action | `O` |
| Use Selected Skill Action | `L` |
| Skill Action Quick Slot 1 | `Shift+1` |
| Skill Action Quick Slot 2 | `Shift+2` |
| Skill Action Quick Slot 3 | `Shift+3` |
| Skill Action Quick Slot 4 | `Shift+4` |
| Skill Action Quick Slot 5 | `Shift+5` |
| Skill Action Quick Slot 6 | `Shift+6` |
| Skill Action Quick Slot 7 | `Shift+7` |
| Skill Action Quick Slot 8 | `Shift+8` |
| Skill Action Quick Slot 9 | `Shift+9` |

Double-tapping forward also starts sprinting with the default movement setup.

The off (left) hand carries a torch or shield alongside whatever the right hand holds. **G** equips
or unequips a torch and **H** a shield — each pulls one from your inventory and returns it on a
second press, while **F** still swaps the off hand with the selected hotbar slot. A held torch, in
either hand, lights the area around you, so a pickaxe in the right hand and a torch in the left lets
you mine without placing torches first. With a shield in the off hand and a sword, mace, or empty
main hand, holding the **use** action raises the shield: while raised it blocks a frontal melee or
projectile hit outright, including its knockback, but not attacks from the side or behind, falling,
fire, or other environmental damage. Ordinary tools use detailed, extruded resource-pack art
without a visible holding hand; bows and shields retain their specialized hand animations.

### Fixed mouse and application shortcuts

These inputs are routed separately and do not appear as configurable gameplay bindings:

| Input | Action |
| --- | --- |
| Mouse movement | Look around. |
| Left click | Attack or break; use a held consumable; confirm template placement. With a bed held, select its head position, then its adjacent foot position. |
| Right click | Use or place; cancel template placement. |
| Middle click | Pick the targeted block. |
| `1` through `9` | Select a hotbar slot. |
| Escape | Close the current screen or open the **Game Menu**. |
| `F1` | Toggle the HUD. |
| `F3` | Toggle the debug overlay. |
| `F11` | Toggle fullscreen. |
| `M` | Expand or collapse the live map. |
| `-` / `=` | Make the compact map smaller or larger. |
| `,` / `.` | Zoom the map out or in. |
| `Command-C` | Copy a targeted connected build as a template. |
| `Command-V` | Open the template placement browser. |
| Arrow keys (during placement) | Left/Right rotate the pending wireframe; Up pushes it away; Down pulls it closer. |
| `Command-Z` | Undo the most recent template placement. |

Physical-controller support currently covers skill actions, the Skills workspace, and the villager trading
sheet. Do not expect a controller to replace the keyboard and mouse for movement, camera, inventory, or
crafting.

### Enter text

Click or otherwise focus a visible text field before typing or pasting. Elysium currently accepts text
in these player-facing places:

- **World Name** and **Seed** during world creation.
- Chat and Command input.
- The Sign editor.
- **Item Name** in **Repair & Name**.
- Creative **Search** and the inventory/crafting recipe filter.
- **Template Name** when copying a build.
- **Ollama Model** under the **Ai** options tab.
- Multiplayer's **Player**, host-side **Code** and **Port**, **Manual Host**, and join-side **Port** and
  **Code** fields.

Return selects a highlighted recipe-search result and submits a manual LAN join from its connection
fields. Creative and recipe searches update as you type. **Create World** submits **World Name** and
**Seed**; the sign editor says “Press Enter / Esc to finish”; **Template Name** has **Save** and
**Cancel**; and **Ollama Model** has **Save Model** and **Clear Model**. The anvil's **Item Name** updates
its result without a separate save button. Elysium does not currently provide a field for naming the
live map or renaming a saved world.

## Understand the HUD and maps

The HUD keeps the crosshair, hotbar, health, hunger, armor, experience, status information, and compact
live map visible during play. It also shows air while submerged, skill-action fast-bar slots when available, and
the health of a living mount while you ride it. Your inventory exposes the equipped armor and offhand
slots. In first person, ordinary tools, food, and blocks enter from the lower outer edge without a
visible arm; an empty slot draws nothing. Holding the attack button repeats the tool stroke, and
release lets the active stroke finish. Equipment lowers before a replacement rises, with a cosmetic
whole-item twirl that yields to actions and Reduce Motion. The minimap covers overlapping items
without moving them. The earned part
of the experience bar reveals a fixed red-to-violet rainbow as it fills; its length and centered level
number remain the non-color progress cues. Use `F1` when you want an unobstructed view and `F3` when you
need the debug overlay.

Use `M` to open the expanded live map. Drag or use the arrow keys to pan, and use `,` / `.` to zoom.
Use `-` / `=` to resize the compact HUD map. The map reflects explored, loaded world data and does not
pause gameplay, so move somewhere safe before studying it. It is a live view, not a collection of
named or saved map files.

## Core play loop

### Gather, build, and manage inventory

Break blocks and collect dropped items, then open the inventory to equip gear, arrange the hotbar, and
craft. The inventory provides a 2×2 crafting grid. Place and use a crafting table for the full 3×3 grid.
Furnaces, brewing stands, enchanting tables, anvils, and other workstations extend the items and upgrades
you can make. Containers hold resources outside your carried inventory.

Choose **Sort A-Z** or press `Command-S` in an open player inventory or chest to order its storage slots
by item name and type. Sorting moves complete stacks without merging or changing them. Player sorting
includes the 27 carried slots and nine hotbar slots, but leaves armor, offhand, crafting, result, and cursor
slots untouched. Chest sorting covers the complete chest, including both halves of a large chest, but
does not rearrange the player rows shown below it. Chest sorting is unavailable while playing as a LAN
client because the current host snapshot does not include enough item metadata for identical ordering.

In Survival, the recipe popup lists recipes you can currently craft from available ingredients. Both
grids — the inventory's 2×2 and a crafting table's 3×3 — pool ingredients from your carried inventory
plus every nearby container within 50 blocks of you, in all directions (including above and below).
Chests, barrels, foundries (the furnace family), hoppers, brewing stands, dispensers, droppers, shulker
boxes, and chest boats and chest/hopper minecarts all count as sources, and crafting withdraws from them
automatically. When leftover ingredients return to storage, they go only to general containers — never
into a foundry or brewing-stand slot. This pooling applies in single-player and when you are hosting; on
a machine that has joined someone else's LAN world, crafting uses only your carried inventory. Open the
recipe popup and type to filter it live by a word or substring in the recipe name; use Up/Down to move
through results and Return to select one.

Workstations have distinct jobs. A furnace smelts, a brewing stand makes potions, and an enchanting table
enchants equipment. An anvil repairs and names items; a grindstone repairs or combines items and removes
enchantments; a stonecutter offers stone-cutting recipes; a smithing table upgrades or trims equipment;
and a powered beacon grants a selected effect. Use the workstation to open its own screen.

- **No craftable items** means none of the recipes for that grid can be made from the resources currently
  available.
- **No matching recipes** means the active search text filters out every currently listed recipe. Delete
  some search text or clear the filter.

### Survive and progress

In Survival, manage health, hunger, shelter, equipment, and food. Sleeping, farming, combat, experience,
enchanting, brewing, death, respawn, bosses, and Advancements are part of the main progression. Creative
is intended for building and exploration without the ordinary Survival damage and consumption loop.

Direct daylight is useful against ordinary hostile monsters: exposed ones ignite once dawn or daytime
light is strong enough. Shelter, water, powder snow, protective headgear, or sufficiently heavy rain can
prevent or interrupt burning in applicable cases. Creepers behave differently: qualifying daylight starts
a short fuse. Once a creeper's fuse latches—whether from daylight or player proximity—it stops horizontal
pursuit and finishes the explosion instead of cancelling and continuing the chase. Keep your distance.

Use **Advancements** for the main route: begin with wood and basic tools, upgrade through stone, iron, and
diamond, enchant equipment, reach the Nether, find the materials needed to locate a stronghold, enter the
End, and face the Ender Dragon. The Wither and outer End exploration are additional goals rather than
requirements for starting a successful world.

## Explore the world

Elysium has three dimensions:

- The overworld contains the starting survival loop, biomes, caves, villages, dungeons, and strongholds.
- The Nether is reached through a lit Nether portal and supplies materials used in later progression.
- The End is reached through an activated stronghold portal and contains the Ender Dragon and outer-End
  exploration.

You can instead choose **World Type: Nether World** when creating a world. All the usual size, game-mode,
difficulty, and dungeon-density choices remain available, but your first entry and
fallback respawn are in the Nether. You begin beside a lit portal with two iron pickaxes, an iron sword,
an iron shovel, and 64 oak logs. Additional lit gateway chambers occur throughout the Nether, so an
Overworld route is never dependent on finding and completing a rare ruined frame. The chosen map size is
the Nether's playable width; its paired Overworld is eight times wider to preserve normal portal scaling.

The four optional **Prehistoric Worlds** profiles replace the ordinary natural population with their
roster of prehistoric creatures. Each creature has its own calls and action sounds, including attacks and
movement. A player-attributed kill gives ordinary experience based on that creature's configured combat
difficulty—health, active damage, and predator/charge behaviour—not merely its apparent size. This is
separate from the usage-based Melee and Ranged skill-tree XP described below.

New dinosaur maps also have more underground caves and lava regions. Look for occasional small rocky
volcanoes on dry land, with exposed lava inside their craters. They do not erupt, but their lava is still
dangerous—keep creatures and wooden builds away. Ancient Seas retains its oceans; volcanoes appear only
where there is suitable dry land. The starter hut and its nearby trees are kept clear of volcanoes.

These dinosaur terrain features belong to newly created **v3** maps. Existing v1/v2 dinosaur maps keep
their original terrain even as you explore. Rich Resources improvements apply whenever terrain is
generated, including previously explored, unmodified areas saved only as entity records. Chunks saved
with their full block data remain intact, so boundaries can show a change in cave patterns.

### Wildlife renewal and forests

Open **Options... → World → Creature Respawn** and choose **Daily** (the default), **Alternate Days**,
or **Weekly**. These mean every **1, 2, or 7 in-game dawns**, not real-world days. Sleeping through a
night counts as reaching the next dawn. Each saved world retains its progress when you leave and
reload; changing the preference takes effect at a future eligible dawn, not immediately.

At that dawn, Elysium attempts to refill vacancies near active players, subject to population caps and
safe, loaded habitat. Regular maps use their ordinary animal, flying-creature, and aquatic tables.
Prehistoric maps use their selected roster instead. New **land dinosaurs** follow a repeating
**herbivore, herbivore, carnivore** sequence across successful spawns—even across separate dawns.
This is a birth ratio, not a guarantee that the surviving population always has that ratio. **Ancient
Seas** has no land-herbivore roster: its pterosaurs, marine reptiles, and existing wild-fish prey remain
eligible without inventing herbivorous sea creatures. Initial wildlife in newly explored terrain is
unchanged; the preference controls replenishment, not initial world generation or ordinary monsters.

The setting applies to worlds you play locally or host; a LAN guest follows the host's choice.
Closed, paused, or inactive worlds do not earn offline dawns. Freezing the daylight cycle freezes the
dawn schedule. Changing the clock with a command does not itself age trees or immediately spawn
creatures, but the next natural wrap to dawn counts; clock commands remain administrator shortcuts.
Sleeping also advances tree age by the skipped portion of the night. Disabled mob spawning, a full
population, or unsuitable habitat does not accumulate a later catch-up swarm. The
Nether and End have no sunrise and keep their existing spawning rules.

When a **natural tree's remaining trunk loses its connection to supported ground**, its unsupported
wood and associated leaves disappear gradually over the next simulated day. Leaf decay occasionally
produces a seedling: some are dropped as collectible saplings, while some plant themselves on nearby
clear, suitable soil. Planted saplings use the normal light and growth rules; tree growth checks space
before placing wood and foliage rather than overwriting an obstruction. Collectible seedlings do not
all turn into trees, and new trees are not guaranteed for every chopped trunk.

This cleanup tracks natural-tree provenance, not just a wood-block shape. Player-built beams and
unmarked trees in older, fully saved chunks are left alone; it does not guess which wooden structures
are disposable. Restore a grounded trunk connection before decay finishes to save the remaining
supported natural blocks. Tree updates require their relevant chunks to be loaded; due decay resumes
in bounded steps after returning to an area. The clock does not advance while the world is closed or
paused, and freezing Overworld daylight also freezes deterioration. Turning off tile drops prevents
both dropped and self-planted seedlings from this decay.

### Weather, travel, and generated sites

Weather changes as the world runs. Rain and thunder affect visibility and direct-daylight conditions;
rain can also interrupt applicable burning. Elysium includes boats, minecarts, chest-carrying variants,
and rideable creatures. Use the normal use/place action to mount or interact with an eligible vehicle;
living mounts expose their health on the HUD while ridden.

New village sites are moved to dry, supported terrain when a valid nearby site exists; otherwise the
village is omitted. Ordinary dungeons are dry and cave-connected. A small minority of dungeons can
appear as deliberately sealed underwater rooms.

Those guarantees apply when Elysium generates new terrain. Already-saved full chunks—including chunks
created by older versions or modified by a player—are not rewritten or repaired. Mixed boundaries
between old and newly generated terrain can therefore remain visible.

## Usage-based skill trees

Every Survival player has the same four independent trees: **Mining**, **Melee**, **Ranged**, and
**Crafting**. There is no character class, sub-class, starter-kit, permanent build choice, or world
creation switch for this system. Open **Skills** from the inventory or press `K` to see all four trees,
their XP, rank tracks, per-item crafting mastery, and fast-bar actions.

Ordinary experience, enchanting, and **Advancements** remain the base survival journey. Skill-tree XP is
separate and comes only from successful, authoritative play in Survival; misses, invalid targets, and
Creative-mode actions do not advance a tree. Each tree has five primary ranks followed by five advanced
ranks. Advanced ranks begin only after primary rank 5.

| Rank | Cumulative tree XP |
|---|---:|
| Primary 0–5 | 0, 100, 250, 450, 700, 1,000 |
| Advanced 0–5 after primary cap | 1,000, 1,200, 1,450, 1,750, 2,100, 2,500 |

### Mining

Breaking a supported ore block with a successful harvest gives Mining XP. Coal, copper, iron, and nether quartz give 2 XP; lapis, amethyst, and emerald give 4; gold, nether gold, redstone, diamond, ancient debris, and labradorite give 6. Labradorite is included in the progression table for compatible future content; this update does not itself add a labradorite block, item, or world-generation feature.

Each primary Mining rank adds 10% harvesting speed on hard stone and ore, up to 50%. After reaching primary rank 5, each advanced rank adds a 10% ore-yield bonus, up to 50%. Yield rolls are deterministic for the same authoritative world state, so this benefit never consumes or perturbs world-generation randomness.

### Melee

A successful sword hit on an animal or hostile enemy gives 4 Melee XP. Each primary rank adds 10% to the equipped sword's base damage, up to 50%; enchantments, criticals, and special-action multipliers apply separately. After primary rank 5, each advanced rank unlocks one sword action. The actions appear in the first available slot of the second fast bar and can be used with `Shift+1` through `Shift+9`.

| Advanced rank | Action | Effect |
|---|---|---|
| 1 | **Stun Enemy** | Stops a targeted enemy's actions and horizontal movement for 30 seconds (600 simulation ticks). It is mechanically prone during that control state; this release does not add a separate prone model pose. |
| 2 | **Spartan Kick** | Deals 1.5× equipped-sword damage and safely shoves the target up to 5 blocks. |
| 3 | **Round House** | Deals 1× equipped-sword damage to each hostile surrounding the player. |
| 4 | **Disarm Enemy** | Forces the target to drop its equipped items. |
| 5 | **Battle Cry** | Deals 3× equipped-sword damage; it has a 2-minute cooldown. |

### Ranged

A successful bow hit on an animal or hostile enemy gives 4 Ranged XP. Each primary rank adds 10% to the equipped bow's base damage, up to 50%. Ranged uses the same five-rank gate and fast-bar pattern as Melee, with bow-specific counterparts.

| Advanced rank | Action | Effect |
|---|---|---|
| 1 | **Pinning Shot** | Stops a targeted enemy's actions and horizontal movement for 30 seconds (600 simulation ticks). It is mechanically prone during that control state; this release does not add a separate prone model pose. |
| 2 | **Power Shot** | Deals 1.5× equipped-bow damage and safely shoves the target up to 5 blocks. |
| 3 | **Volley** | Deals 1× equipped-bow damage to hostile enemies around the aimed target. |
| 4 | **Disarming Shot** | Forces the targeted enemy to drop its equipped items. |
| 5 | **Eagle Eye** | Deals 3× equipped-bow damage; it has a 2-minute cooldown. |

### Crafting

Completing a crafting-grid recipe awards Crafting XP from the actual resolved ingredients: more and rarer resources contribute more. Crafting treats copper as tier 1, iron as tier 2, gold/redstone/lapis/quartz/amethyst as tier 3, emerald/diamond as tier 4, and ancient-debris/netherite as tier 5 (or a higher registered rarity when one exists). Each output item type can contribute XP for its first 100 completed craft rounds, then that item is mastered and stops granting Crafting XP even when another recipe makes the same output. The mastery counter is attached to a committed output, not to a preview or attempted craft, so cancelled or failed crafts do not consume its limit.

Primary Crafting ranks improve batch throughput: the maximum committed rounds per craft request progress from 1 to 2, 4, 8, 16, and 32. Advanced ranks improve the quality recorded on eligible crafted gear. Quality increases maximum durability by 10%, 20%, 35%, 55%, and 80%, and weapon base damage by 2.5%, 5%, 10%, 15%, and 25%. It also improves compatible repair outcomes by 5%, 10%, 15%, 20%, and 30%. These bonuses stay with the crafted stack and are used consistently by durability, damage, and repair logic.

At advanced rank 5, **Field Repair** appears in the action fast bar. With a damaged eligible item in the main hand and its compatible repair material in the inventory, it restores one quarter of that item's maximum durability, improved by its crafting quality. It has a 30-second cooldown; Creative mode does not consume repair material.

### Legacy saves and LAN authority

When an older save loads, Elysium translates its closest relevant class ranks into the four trees once: Delver mining skills map to Mining, Warden melee skills to Melee, Ranger bow skills to Ranged, and Tinker crafting/repair skills to Crafting. Former class spells and unrelated class-only perks retire rather than being assigned to an unrelated tree. New tree state is then saved in the existing versioned player envelope; a newer, unknown player-state version is not downgraded or overwritten.

On a LAN world, the host owns skill XP, rank changes, targets, damage, displacement, dropped items, cooldowns, and the replicated player state. A client can request an unlocked action but cannot supply its own skill-tree state or bypass the host's equipment, range, target, or cooldown checks.

## Trade with villagers

Adult villagers with professions and wandering traders can barter for the resources they value. Use the
normal use/place action while close to an eligible trader and in line of sight. Trading is currently
available to a local player and to the LAN host; LAN clients cannot trade.

The barter sheet shows:

- the resource types the trader wants;
- each offer's required count and result count;
- how many required resources you currently hold;
- remaining stock, villager level, and workstation or restock status; and
- the reason **Trade** is unavailable when an offer is blocked.

Select an offer with the pointer, or use Up/Down for one row, Home/End for the first or last offer,
Page Up/Page Down for a page, and Enter or Space to activate **Trade**. On a controller, the directional
pad or left stick moves through rows, Left/Right or the shoulder buttons moves by a page, A activates,
and B closes the sheet.

The complete offer is applied together: payment is not taken unless the output can also be delivered.
A trade can be disabled because you lack resources, the offer is out of stock, the villager level or
workstation state is not ready, you moved out of range or line of sight, your inventory lacks room, or
you are a LAN client. **Trade changed - review offers** means the merchant or your resources changed
since the sheet was prepared; reread the refreshed offer before trying again. If the header says
**Trading unavailable**, move back into valid range and line of sight or leave the sheet and retry with
an eligible merchant. A LAN client must ask the host to trade instead.

Different professions seek different resource groups and carry different offer catalogs. Revisit working
villagers as they progress and restock; wandering traders use a separate traveling catalog.

## Save, manage, and recover worlds

Elysium stores local worlds, player state, settings, key bindings, and templates under:

```text
~/Library/Application Support/Elysium/
```

For a manual backup, first quit Elysium. In Finder, copy the complete `Elysium` application-support
folder to a separate backup location and verify that the copy exists before changing or deleting local
data. Do not edit the live world database, and do not assume that an incomplete or unverified copy can
recover a deleted world.

### Select and open saved worlds

- Click a row to select one world.
- Command-click a row, or click its checkbox, to toggle it.
- Shift-click selects a range; Command-Shift-click adds a range.
- **Select All** and **Clear All** operate on the complete list. Command-A also selects all when the list
  has keyboard focus.
- Arrow keys move through the list. Shift-Arrow extends selection, Command-Arrow moves focus without
  changing selection, and Space toggles the focused row.
- **Play Selected** or **Host Selected** requires exactly one selected world.

### Permanently delete saved worlds

> **Permanent data-loss warning:** **Delete** removes every selected local world and its chunks, player
> data, Advancements, and skill-tree data. There is no cloud copy or guaranteed recovery. Back up first if you
> may want the data again.

1. Review the checked worlds and choose **Delete**. Delete and Backspace keys intentionally do nothing.
2. Review every name in the separate confirmation. **Cancel** has initial focus.
3. Confirm only when the complete list is correct.

If the saved-world list changed before confirmation, review the refreshed selection rather than assuming
the earlier list still applies. If deletion fails, use **Try Again** only after another review or choose
**Cancel**. If Elysium cannot prove the result, **Saved Worlds Need Reloading** locks the browser to a
read-only reload instead of repeating deletion. Reload the list and inspect what remains; this state does
not promise recovery of anything already deleted. Saved-world deletion is local and never deletes the
host's world from a LAN client.

## Local-network multiplayer

Elysium multiplayer is for a trusted local network. It has no public matchmaking, cloud relay, or built-in
NAT traversal. Do not expose the game through port forwarding, disable firewall or macOS protections, or
treat a join code as protection against a hostile network. The host owns the simulation and saved world.

LAN discovery and play can expose the world name, the local Mac user's full name as a player identity,
chat, and gameplay state to LAN participants. Changing **Player** does not guarantee complete anonymity.
Use LAN only with people and a network you trust, and do not host or join when that disclosure is
unacceptable.

### Host a world

1. Choose **Multiplayer** from the title screen, or choose **Open to LAN** from a paused local world.
2. Review **Player**. Optionally enter a host-side **Code** and **Port**.
3. Choose **Host World**. From the title screen, select one saved world to host or create a new one.
4. Share the displayed connection details only with people on the trusted LAN.
5. Use **Stop** when you want to stop hosting or browsing.

### Join a world

1. If a local world is open, press Escape and choose **Save & Quit to Title** first. Joining never replaces
   an active local world.
2. Choose **Multiplayer** and **Browse LAN**.
3. Select a discovered world. If discovery is unavailable, enter **Manual Host**, the join-side **Port**,
   and any required **Code** supplied by the host.
4. Review **Player**, then choose **Join World**.

A join code is an access gate, not encryption and not a defense against other hostile participants on the
same LAN. Current LAN clients cannot trade; skill-tree state and action resolution remain host-owned.

## Object templates

Object templates let you reuse a connected build:

1. Target part of the connected construction and press `Command-C`.
2. Enter a **Template Name** and save it. Very large or terrain-like connected selections can be rejected
   rather than copied without bounds.
3. Press `Command-V` to browse saved templates and open a placement preview.
4. Steer the wireframe before committing: the Left and Right arrow keys (or the mouse wheel) rotate
   it, the Up arrow pushes it away from you, and the Down arrow pulls it closer — hold Up or Down to
   glide the distance. Left click places it; right click cancels placement.
5. Press `Command-Z` to undo the most recent template placement.

Template placement is previewed and validated before it changes the world. Undo applies to the most recent
template placement, not to every ordinary building action. In either saved-template browser, **Delete**
or Delete/Backspace while the template list is focused opens a confirmation naming the exact template.
**Cancel** has initial focus, Escape cancels, and only **Delete Template** performs the deletion.

## Scripting, attributes, events, and AI

Elysium has a full player- and AI-facing scripting system: objects (blocks, entities, players,
dimensions, the world) carry named custom attributes, typed custom event declarations, handlers,
and up to 8 attached Lua scripts each, running on a sandboxed, deterministic Lua 5.4.8 runtime.
Scripts can watch another live object's events or attribute changes, schedule named timers that
survive a save/reload, and ask the local AI for a reply. You drive
all of this from chat commands, an in-game multi-line script editor, and a read-only Inspector; the
`/ai` assistant can author and manage scripts, attributes, subscriptions, and custom events too,
through the exact same checks.
Authoritative storage and execution below are host-only. Attached/background execution and ordinary
command, AI, and LAN one-off runs require both the per-world trust switch and the kill switch; the
local editor's narrow Run Once exception is explained below. Every mutation command is refused on a
joined LAN world until the host grants scripting (see "Guest scripting" below); the supported
commands are then forwarded to and executed by the host. This section covers the chat/editor surface;
for the complete Lua API reference, the ref and value grammars, and more worked examples, see
[docs/SCRIPTING_GUIDE.md](docs/SCRIPTING_GUIDE.md).

### Attributes

Chat commands let you read and set small, named pieces of data on a block, entity, player,
dimension, or the world itself.

- `/attr set <target> <name> <value>` — set an attribute. `<target>` is always required: `self`,
  `looking` (whatever is under your crosshair), or a canonical reference such as `entity:12` or
  `block:overworld:10,64,3`.
- `/attr get <target> <name>` — read one attribute.
- `/attr list <target>` — list every attribute currently set on the target.
- `/attr define <target> <name> <value> [readonly] [--force]` — declare a custom attribute name by
  giving it an initial value. Later writes may use a different supported value type. Add `readonly`
  to make it read-only from then on, or `--force` to redefine an existing readonly attribute.
- `/attr remove <target> <name> [--force]` — clear one custom attribute; `--force` is required for
  one defined as read-only.
- `/inspect [target]` — a readable dump of a target's built-in fields (block state such as facing,
  half, or open/closed) plus every attribute set on it. Unlike `/attr`, `/inspect`'s target is
  optional: omit it to default to `looking`, then `self` if nothing is under your crosshair.
- `/objects near [radius]` — lists nearby entities and attributed blocks, closest first (default radius
  if omitted).

Values are typed: a bare number (`3`, `-1.5`), `true`/`false`, a quoted string (`"like this"`), or a
reference to another object — written with a `ref:` prefix plus the target grammar (`ref:entity:12`,
`ref:block:overworld:10,64,3`, `ref:player`). The `ref:` prefix is required; without it, the text is
stored as a plain string instead. Some built-in fields are read-only (for example a door's
`waterlogged` state) and refuse a `/attr set`.

Custom attributes and attached scripts share one name namespace on an object: an attribute command
will not replace a same-named script, and attaching a script will not replace a same-named attribute.
Detach or remove the existing entry explicitly first. Custom event declarations are stored
separately and do not participate in that collision rule.

Lua and the AI accept ergonomic camelCase while storing new custom names as snake_case
(`favoriteColor` becomes `favorite_color`). Unchanged scripts remain compatible with old worlds that
stored the former collapsed spelling (`doorref`): canonical `door_ref` wins when present, otherwise
the existing legacy key is reused. Built-ins always win before this fallback, so `maxHealth` means
the built-in `max_health`, not a custom `maxhealth` value.

Setting an attribute never bypasses the game's own rules for that block or entity — the engine stays
authoritative. For example, `/attr set` can flip a door's `open` field, but the same redstone logic that
governs every other door still applies afterward: an unsupported door still breaks, and a door wired to
power still swings shut or open on the next power transition regardless of what a command just set.
Every scripting-API write that actually changes a built-in or custom value raises
`attribute.changed` on that object with the writer's provenance. Engine-driven built-ins are compared
only while a matching subscription exists; a polled field's first observation establishes its
baseline and does not fabricate a startup change. A script on any other live object can observe later
changes directly with `target:onAttribute("name", fn)` or through the general subscription API.

**Worked example** — label a chest without touching anything else about it, then read it back:

```
/attr define looking label Ships Locker
/attr get looking label
"Ships Locker"
/attr list looking
label = "Ships Locker"
1 attributes, N bytes, revision 1
```

(`/attr list` always ends with a byte-size and revision summary line; the exact byte count depends
on the world tick the attribute was written at, so it isn't reproduced here.)

Add `readonly` to lock a definition against a later plain `/attr set` (an `/attr define ... --force`
is still allowed, and overwrites it):

```
/attr define self favorite_color blue readonly
/attr set self favorite_color green
favorite_color is readonly — use /attr define --force
```

### Events and subscriptions

You can also register interest in things that happen in the world from chat. A subscription
names a script and a handler function inside it (`<script>.<handler>`) — that handler runs whenever a
matching event fires, exactly like a script's own `on(...)`/`subscribe(...)` calls (see "Scripts"
below), except `/on` lets you wire up a handler in an *existing* script from chat rather than from
inside the script's own source. Event registration and delivery are host-authoritative; a granted
guest forwards supported mutations to the host rather than running them locally.

- `/on <target> <event> [attr] <script>.<handler>` — subscribe. `<target>` is what to watch: `self`,
  `looking`, a canonical reference (`entity:12`, `block:overworld:10,64,3`), a bare kind name
  (`entity`, `player`, `block`, `world`, `dim` — every object of that kind), a kind with a type filter
  (`entity:zombie`, `block:furnace`), or `any` (every object — not accepted for `attribute.changed` or
  `block.changed`, which need a narrower target). `<event>` is a dotted event name from the catalog
  (`block.broken`, `entity.damaged`, `player.joined`, …) or a custom name a script defines
  (`lumber.milestone`). `[attr]` narrows an `attribute.changed` subscription to one attribute name
  (e.g. `health`); omit it to match every ordinary attribute change on the target. Registry names
  such as `inventory[0]` and `be.name` are valid filters even though custom names cannot contain
  brackets or dots. Quantized movement uses the explicit `pos` filter and stays out of the recent
  feed; an actual custom attribute named `pos` is still an ordinary change visible to unfiltered
  handlers. `<script>.<handler>` names
  the script (attached with `/script attach`, see below) and the handler function inside it — both
  parts follow the same attribute-name grammar (lowercase letters, digits, underscore). A handler
  name only resolves once the named script's module body has called `register("<handler>", fn)` (or
  `on(event, {name="<handler>"}, fn)`) at load — an `/on` naming a handler that never registered
  itself stays dormant (no error, it simply never fires) rather than refusing the subscription.
  Subscribing survives save and reload.
- `/unsubscribe <id>` — remove a subscription by the numeric id `/on` printed when you created it.
- `/events recent [limit]` — lists the most recent events the bus has seen (default limit if omitted).
- `/events list <target>` — shows the standard events compatible with that object, followed by its
  custom event declarations and typed payload fields.
- `/events define <target> <event> [field:type ...] [--summary "text"]` — declares a discoverable
  custom event contract on one object. Types are `any`, `boolean`, `integer`, `number`, `string`,
  `object`, `list`, and `map`; add `?` for a nullable/optional field (`actor:object?`).
- `/events remove <target> <event>` — removes that custom declaration. The open event name and old
  subscriptions remain valid, but payload completion and strict validation disappear.
- `/events emit <target> <custom-event> [payload-json]` — raises a custom event by hand. `<target>` is a normal
  object reference, not a kind wildcard. If that object declares the event, every required field,
  type, and extra-field rule is checked. An undeclared custom event remains legal for compatibility.
  Built-in events are facts raised only by the engine and cannot be emitted manually.

Declarations are object-scoped metadata; defining one does not register a handler or automatically
make anything emit it. An object can hold up to 16 declarations, each with up to 32 fields and a
256-byte summary, under the same bounded object/chunk/world persistence envelope as its attributes
and scripts.

`block:<name>`/`entity:<type>` in an `/on` target is a type filter, not a coordinate or an id — it
only reads as a filter when there's no second `:` after it (`block:overworld:10,64,3` still resolves
as a specific block, never as a filter named `overworld:10,64,3`).

**Worked example** — declare a machine event, emit a valid payload, and see it in the recent feed
(no script needed for this part):

```
/events define looking machine.ready item:string count:integer --summary "A machine completed a batch"
/events emit looking machine.ready {\"item\":\"iron_ingot\",\"count\":4}
emitted machine.ready on block:overworld:5,64,2
/events recent 3
#413 t118 machine.ready block:overworld:5,64,2
```

The backslashes preserve JSON's quote characters through chat's one-line command parser. A missing
`count`, a string where an integer was declared, or an extra field is refused before the event enters
the bus.

Standard events are grouped intuitively by subject: every object supports `attribute.changed` and
script lifecycle/timer events; blocks cover placement, first tool strike, breaking, use, changes, and
neighbor updates; entities cover spawn/removal, damage/death/healing, interaction, and targeting;
players add join/leave/respawn, dimension, inventory, attack, sleep, level, and advancement events;
dimensions cover day phase, weather, and explosions; the world covers gamerules, difficulty, AI
replies, and budget diagnostics. The full event/payload table is in
[the Scripting Guide](docs/SCRIPTING_GUIDE.md#standard-event-catalog).

`block.changed` includes metadata-only writes: `oldName` and `newName` may be equal while `oldMeta`
and `newMeta` identify an open/facing/growth-state transition. `block.neighborChanged` is raised for
a notified block when it either carries an object record or matches an exact-object, block-kind
(optionally type-filtered), or all-object subscription. A module may therefore register
`target:on("block.neighborChanged", fn)` for a plain block without first adding an attribute or script
to that target.

`block.toolStrike` is specifically the first transition onto a block while holding a registered tool,
not every repeated swing while the mouse is held. Its payload is `by`, `item`, `blockName`, `face`,
`toolType`, `tier`, and `instant`, so a block can react immediately without creating a high-frequency
hit event. It also fires when the contacted block is unbreakable; in that case `instant` is false.

A more useful worked example — one that actually attaches a handler and reacts to a real event —
follows in "Scripts" just below, since attaching a handler is a `/script` command.

### Scripts

Objects can carry small Lua scripts — up to 8 per object, attached with `/script attach`, pasted
in through a minimal in-game editor, or authored by the local AI through `/ai` (see "Optional local
AI" below). Execution always happens on the host — a guest never runs a script itself, even its own.
Reading (`/script list|show`), the world trust gate, the kill switch, and the AI journal/undo commands
below stay host-only outright. The commands that actually change something — `/attr set|define|
remove`, `/script attach|detach|run`, `/on`, `/unsubscribe`, `/events define|remove|emit`, and `/ai`
— work for a joined guest too once the host grants the matching permission (see "Guest scripting"
below); until then they're refused exactly as before.

- `/script list [target]` — lists the scripts on a target (default `self`), with their mode and
  whether they're currently disabled or faulted.
- `/script show <target> <name>` — the full source, mode, author, trigger(s), and last error (if any)
  of one script.
- `/script attach <target> <name> module <source...>` — attach a **module**-mode script: the source
  runs once when the script loads and typically calls `on(...)`/`subscribe(...)`/`every(...)`/
  `after(...)` to register its own handlers. A module may also call `register("unload", fn)` for a
  synchronous final custom-attribute cleanup when it is edited, disabled, detached, unloaded, or the
  session closes. This is not an event: the function receives no `ev`, cannot wait, emit, subscribe,
  call AI, change scripts/world/built-ins, or call `say`/`sound`/`particles`, and is not available in
  Handler mode.
- `/script attach <target> <name> handler <event> <source...>` — attach a **handler**-mode script:
  the source *is* the handler, triggered on `self` by `<event>` (an `ev` table is bound automatically
  — no `on(...)` needed). Attaching from chat always targets the trigger at `self`; a script's own
  `h:attach(name, source, {on=..., attr=..., target=...})` call (see below) can target any object.
- `/script detach <target> <name>` — remove a script.
- A running script may perform at most 2 combined `h:attach`/`h:detach` operations per simulation
  tick, while all scripts share a 32-operation world-wide limit for that tick. This prevents a
  handler storm from creating unbounded lifecycle work; both limits reset on the next tick.
- `/script run <target> <source...>` — run a one-off script against a target immediately; the source
  is not saved or attached, though permitted changes to live world state may persist. It can't
  subscribe, set timers, or call the AI. This chat command requires a trusted
  world and `doScripts` on.
- `/script stats` — shows live/suspended script and durable-timer counts, pending events, and the
  global Lua instruction tokens charged and remaining this simulation tick. Use it when a busy
  script appears to be falling behind; ordered handler work is deferred, not silently discarded.
- `/script trust` — trust the current world to run scripts. A world you created yourself is already
  trusted; a world imported or migrated from elsewhere starts untrusted (no script on it runs, even
  if it has scripts attached) until you trust it here.
- `/script trust <peer> [ai] [off]` — **hosting a LAN world only**: grant (or, with `off`, revoke) a
  connected guest permission to author/attach/detach/run scripts, set/define/remove attributes,
  subscribe/unsubscribe, and define/remove/emit custom events through you. `<peer>` matches a
  connected player's name.
  Add `ai` to also let that guest use `/ai` (a separate grant — scripting permission doesn't imply AI
  access, and vice versa): `/script trust Alice` grants scripting; `/script trust Alice ai` grants AI
  too; `/script trust Alice off` / `/script trust Alice ai off` revoke either one. This is a different
  command from the bare `/script trust` above (that one trusts the *world*, not a *guest* — the two
  never conflict).

Attached execution refills 50,000 instruction tokens per simulation tick and can bank at most
250,000 after idle ticks. Each callback gets a 5,000-instruction slice; a preempted callback resumes
in deterministic FIFO order, while 20 consecutive preemptions fault a spinner. Short callbacks are
conservatively charged one 1,000-instruction hook quantum, and hook overrun debt is repaid on later
ticks. One script may retain at most 64 suspended callbacks and the world at most 1,024. Scheduler
lanes reserve one 1,000-instruction quantum for later work, so a large load backlog cannot starve AI
replies, resumptions, timers, or events. When the global bucket is empty, the event bus preserves the
exact next recipient and suffix for a later tick rather than reporting that unrun work as delivered;
an awaited AI reply likewise remains paired with its suspended script until credit returns. Prefer
events and named timers over polling or busy loops.
- `/script off` / `/script on` — the scripting kill switch (the `doScripts` game rule under the hood).
  Instant, and independent of trust: `/script off` stops every script this tick regardless of how
  hostile a world's scripts might be.
- `/script journal [limit]` — lists what the AI has done to this world through `/ai` (attributes it
  set, scripts it attached/detached/enabled, subscriptions it created, and event declarations or
  emissions it requested), most recent first: which request, which tool, which object, which model.
  Nothing you or another script does appears here — only AI mutations are journaled.
- `/script undo-ai [n]` — reverts the `n` most recent `/ai` requests' worth of mutations (default 1),
  most recent first. An attribute the AI set goes back to its previous value (or disappears, if the AI
  created it); a script the AI attached is detached (if it was new) or restored to what it replaced
  (if the AI edited an existing script) — unless you've edited that script yourself since, in which
  case undo refuses rather than overwrite your edit and tells you so. Emitting an event or running a
  one-off script can't be undone (whatever it already did in the world stays done); undo-ai still logs
  that it tried, so the journal stays a complete record either way.
- Chat command source is one line — for anything longer, use `/script edit [target] [name]` or
  Command-E to open the native Lua editor. It provides semantic colouring; completion for locals,
  engine globals, inferred tables, methods, properties, event payloads, and live custom attributes;
  signatures and diagnostics; validated snippets; and a searchable **World Objects** list that can
  insert stable canonical references. The Handler event picker shows only produced events compatible
  with the current target, then that target's declared custom events; selecting one feeds its typed
  payload fields to `ev.` completion and Check. Typing `.` or `:` opens member completion immediately,
  and Control-Space requests it anywhere. On a local world with an active script runtime, the editor
  remains available even when scripting is not yet trusted or has been paused: **Check** performs a
  mutation-free dry run, **Save** validates and persists the script without starting it, and **Run
  Once** executes only the visible draft once without saving or attaching that draft. That explicit
  editor Run Once can be used before trusting an imported world, but it is not read-only and can make
  permitted changes to live game state; those changes may persist with the world. It still refuses
  while `doScripts` is off; `/script run`, AI runs, attached scripts, and guest runs keep both gates.
  All three retain the runtime's authoritative validation. If the local runtime is unavailable,
  Check, Save, and Run Once are unavailable because that validation cannot be performed; copy the
  retained draft and restart the world or Elysium before retrying.
  Run cannot suspend, so `wait`/`ai.await` are highlighted with guidance to Save for attached execution;
  Check accepts a valid attached-script suspension without scheduling it or contacting AI.
  When attached execution is paused, the status banner offers **Trust World**, **Turn On Scripts**,
  or **Trust & Turn On**, depending on which gate is off. Its confirmation warns that continuing
  may start every enabled script already attached in the world. Nothing in the editor trusts a
  world or turns on `doScripts` automatically.
  Unsaved source is protected when switching, closing, or quitting Elysium. Optional editor AI is **Manual** by default:
  Option-Command-/ asks the selected local Ollama model for one ghost-text proposal, Tab accepts it,
  and Escape dismisses it. Set editor AI to **Off** for no Ollama requests or explicitly choose
  **On Idle** for automatic requests after a pause; this explicit mode choice persists across app
  sessions until changed. In Handler mode, the proposal sees the current target's compatible
  built-in/custom events and payload fields. In Module mode, it also sees every produced built-in
  payload plus the compatible built-in names and declared custom payloads for each bounded World
  Objects entry, so cross-object subscriptions do not require guessed event names. It also receives
  target members and diagnostics. That snapshot is sent only when you explicitly request a
  suggestion or opt into On Idle;
  AI proposals have no tools and cannot save, run,
  or mutate the world. On a joined LAN world, existing source remains hidden; replacing it requires
  an explicit warning and the host still performs every validation and execution step. The complete
  controls and privacy boundary are in the [Lua Editor reference](docs/LUA_EDITOR.md).
- `/inspector` opens the **Object Inspector** — a read-only window onto whatever you're looking at
  (or `self`/`player`/`world`; click **Retarget** to cycle) showing its attributes, its attached
  scripts, and its event subscriptions. Select a script row and click **Edit Script** to jump straight
  into the editor for it. On a joined LAN world, the Inspector still opens — the attributes section
  and now the scripts section (name, mode, enabled — never the source itself) show whatever the host
  has replicated to you so far, marked "replicated, read-only"; subscriptions still aren't visible to
  guests. `/inspector` itself is never refused for guests — reading is always fine. Writes (`/attr
  set`, `/script attach`, and the rest) are sent to the host and applied there once granted (see
  "Guest scripting" below); until then they're refused exactly like every other unsupported guest
  command.
- Press **F3** for the debug overlay; while a world has any scripts, one extra line reports how many
  are currently live, how many are waiting on a timer or `wait()`, how many durable timers exist, and
  how many events are pending/faulted this window — a quick health check without opening `/script
  list` on every object.

**Worked example** — attach a use-counter to a lever, door, or sign without leaving chat. Handler
mode needs no `on(...)` call: the source *is* the handler, and `self.attrs.<name>` reads and writes
a custom attribute directly.

```
/script attach looking counter handler block.used self.attrs.uses = (self.attrs.uses or 0) + 1
attached counter [handler] to block:overworld:5,64,2 — takes effect next script phase
```

Now use that block (right-click it) a couple of times, then read the count back:

```
/attr get looking uses
2
/script list looking
counter [handler]
```

A one-line chat script has one gotcha worth knowing: the command line is parsed the same way as
every other command, so a bare `"` or `'` in your source is consumed as chat-style quoting, not
kept as a Lua string delimiter — write `\"` to get a literal quote through (`say(\"hi\")`), or use
`/script edit` for anything with string literals in it, which pastes your script in untouched. The
example above needs no quotes at all, which is why it works as a single chat line.

A script's own Lua reference — the object model, event names, attribute access, timers, and
`ai.ask`/`ai.await` — lives in [docs/SCRIPTING_GUIDE.md](docs/SCRIPTING_GUIDE.md), not here; this
section only covers the chat/editor surface for attaching and managing scripts you (or another
script, or the AI) already have the source for.

### Authoring metadata on a joined LAN world

The host's script-set and AI-set attributes on any object now reach connected guests automatically —
no command needed. What a guest sees is always a read-only snapshot (never more than a couple of
seconds behind the host, and never something the guest can edit or that any script running on the
guest's own copy of the world could see, since guests never run scripts at all): open `/inspector` on
the object in question, or `F3`, to check what's arrived so far. This is display-only — nothing about
who's authoritative on a LAN world has changed; the host still runs every script and owns every
attribute write. Custom event declarations are mirrored through the same bounded, read-only channel
for the editor's target-aware picker; only name, fields, and summary are included. The host remains
the sole owner of declaration storage, event emission, subscription registration, and script execution.

### Guest scripting

Once your host runs `/script trust <yourName>` (see above), you can author and manage scripts and
attributes yourself while playing on their world — `/attr set|define|remove`, `/script attach|
detach|run`, `/on`, `/unsubscribe`, and `/events define|remove|emit` all work for you now, exactly as documented
above. Nothing you send runs on your own machine: it's sent to the host, validated and executed there
(the same way the host's own commands are), and the result — accepted or refused, and why — shows up
in your chat a moment later. `self` in any command you send means *your own* player object
(`player:lan:<you>`), not the host's; you can still name the host's own `player` object explicitly if
you want to (and the host trusted you enough to grant scripting at all). Your own scripts and
attributes persist with the host's save of that world — if you reconnect later, they're still there;
if the host deletes that world, they're deleted too. If your host also adds `ai` to your grant,
`/ai <request>` works too — your prompt is sent to the host, which asks its own configured local model
and relays the reply back to your chat (prefixed `<AI>`); you never talk to Ollama yourself, and `/ai
cancel` isn't available to a guest yet. Everything not in this list — reading with `/inspect`/
`/objects` and `/events list|recent`, the world trust gate, the kill switch, and the AI journal/undo
commands — stays host-only regardless of any grant. The editor receives a bounded, source-free mirror
of visible custom event names, field types, and summaries so its picker/completion stays accurate;
that metadata grants no execution or mutation authority.

## Options, accessibility, and local AI

**Options...** contains six tabs:

- **Video** controls render distance, field of view, brightness, GUI scale, graphics effects, fullscreen,
  particles, frame-rate limit, Standard/Ultra/Ray Traced graphics, and the default-on **Show Minimap** setting.
  Turning the compact minimap off clears it from the gameplay HUD but does not disable the expanded
  map opened with `M`. In the Nether, both map views follow the open cavern around your current
  height instead of drawing the sealed ceiling.
- **Audio** controls the master level and categories such as music, blocks, creatures, players, ambient,
  jukebox, and UI.
- **World** sets **Creature Respawn** to Daily, Alternate Days, or Weekly. These are in-game dawn
  intervals for your local/host worlds; see [Wildlife renewal and forests](#wildlife-renewal-and-forests).
- **Controls** manages sensitivity, inverted Y, and configurable gameplay bindings.
- **Access** contains **Subtitles**, **Auto-Jump**, **Reduce Motion**, **Reduced Flashes**, **High Contrast
  UI**, and **Darkness Pulsing**.
- **Ai** configures the optional local Ollama model.

Reduce render distance, particles, shader effects, or the frame-rate limit when performance or heat is a
problem. Use **Reduce Motion** and **Reduced Flashes** when camera movement or effects are uncomfortable;
**High Contrast UI** and **Subtitles** can make visual and audio information easier to follow.

### Graphics modes, water, and clouds

Open **Options... → Video → Shaders** to cycle between **OFF** (Standard), **ULTRA**,
and **RAY TRACED**. Ray Traced appears only when the selected Metal device supports
the required ray-tracing capability. New settings profiles default to Ray Traced,
with Ultra fallback on unsupported hardware. Your existing graphics choice is
preserved, including Standard/OFF; installing the update does not override it.

Ray Traced follows actual loaded world geometry, including objects outside the
camera view, for lighting, shadows, indirect illumination, reflections, and
water/glass transmission. Animated creatures use the same poses and textures as
Standard. It can take a short time to prepare newly loaded geometry; during
preparation, or when the hardware or safe scene budget cannot support it, the game
uses Ultra and displays a notice. Memory allowance scales to the GPU instead of
using a fixed small limit, and temporary memory pressure retries automatically
without reopening the world. `F3` reports the active mode, internal ray-tracing
resolution, GPU frame time, and ray-memory usage/budget. Ray tracing is substantially more demanding than
Standard; lower render distance or choose Ultra when necessary.

Leaf canopies let a portion of daylight through, so wooded areas remain shaded
but navigable. Denser leaf layers block more light; solid roofs block sunlight.
Underground areas remain dim but readable in Ray Traced mode. Torches, lit furnaces,
lanterns, lava, and other artificial lights now have 1.7× the original output and twice the reach;
solid walls stop their placed light, while openings let it spread. Carried lights
are stronger too. Soul flames retain their blue light. These are visual changes:
monster spawning and other gameplay light rules are unchanged.
Lighting changes smoothly through dawn and dusk rather than switching
between separate canopy day/night brightness values.

On supported Macs running macOS 26 or newer, MetalFX reduces ray noise while
preserving texture detail. Other supported systems use the built-in filter.
The world is traced at an aspect-preserving resolution up to 1440 × 900; the HUD
still uses the full window resolution.

Water has subtle moving normals, stronger reflections at grazing angles,
refraction, deeper-water absorption, and restrained shoreline foam. Standard and
Ultra use the visible scene and sky for these effects; Ray Traced also follows
reflected and transmitted rays into the loaded world. Clouds have thickness,
soft lighting, and greater coverage in rain. **Clouds** still switches them off,
and **Reduce Motion** stops the new cloud drift and optical water-wave animation.
The minimap, text, crosshair, and held-item presentation stay separate from world
ray tracing, so their clarity does not depend on ray accumulation.

### Optional local AI

AI is not required to play Elysium. To use it, independently install and run a local Ollama service, then
open **Options... → Ai**, enter or select an **Ollama Model**, and save it. **Refresh Models** discovers
models from the configured loopback service. Cloud-tagged model names are rejected on this Elysium
surface. Use `/ai <request>` in command input after a model is available; `/ai cancel` stops a request
that's still thinking.

Before you use `/ai`, understand the data flow: Elysium sends your request together with current game
context—including the world seed, player position and state, inventory, nearby state, and saved template
names or summaries—to the Ollama service through the local loopback address. Do not put secrets or
personal information in AI requests or template names. Elysium does not control an independently
configured Ollama installation or model provider's retention or onward handling.

Model output is treated as untrusted and reduced to a limited set of validated in-game actions. A request
can fail, produce no usable action, or be rejected without changing the world.

**What the AI can see and do with objects, attributes, scripts, and events.** A request that sounds
like it's about scripting (mentions a script, an attribute, an event, subscribing, attaching, and
similar words) is handled differently from an ordinary building/world request: instead of picking one
action, the AI can look around and make a short sequence of changes in the same request (up to four),
narrating what it's doing as chat lines. It can list and inspect nearby objects and their attributes
and scripts, look up the target-compatible built-in catalog and object-scoped custom event
declarations, and check what a candidate script would do before
committing to it, set or remove a custom attribute, attach or detach a script (every AI-authored
script is checked the same way `/script attach` checks a script you paste in, plus one extra pass
that tries the script out on a scratch copy first and reports anything that looks wrong before it's
saved for real), enable or disable a script, subscribe or unsubscribe to an event, declare, remove,
  or raise a custom event, or run a one-off script. Its authoring prompt carries a compact explicit
  Lua contract; the built-in event section and exact payload names such as `cause` and `blockName`
  are generated from the canonical event registry instead of an independent handwritten event
  list. Every one of these goes through the exact same
validated path as the matching `/attr`/`/script`/`/on`/`/events` command — the AI has no shortcut
around any check a command would hit. A guest cannot execute this lane locally; with the separate AI
grant, its request is forwarded to the host's model and host-side executors. Anything the AI sets or
attaches is undoable with `/script undo-ai`, and `/script journal` shows exactly what it touched (see
"Scripting" above). Inside a script, `ai.ask(prompt)`
and `local reply, err = ai.await(prompt)` now reach the same local Ollama model configured here
(text only, no tools) — `ai.await` pauses that script's handler until the reply arrives (or times out,
or is refused for being over budget) without pausing the rest of the game.

## Troubleshooting and current limitations

| Problem | What to try |
| --- | --- |
| A control does not respond | Open **Options... → Controls**, inspect the binding, use **Capture** or **Reset**, and resolve any shown conflict. Remember that fixed shortcuts are not in this list. |
| Typing goes nowhere | Focus the visible text field first. Close another open screen if it owns text input, then focus the intended field and try again. |
| Recipe list says **No craftable items** | Gather the missing resources or use the correct crafting grid or workstation. |
| Recipe list says **No matching recipes** | Shorten or clear the active search text. |
| **Trade** is disabled | Read its visible reason; check payment, stock, level, workstation, distance, line of sight, inventory room, and whether you are a LAN client. |
| A skill action is unavailable | Open **Skills** with `K`, confirm its tree's primary and advanced ranks, equip the required sword or bow, then read the visible cooldown, target, range, and authority reason. |
| No LAN world appears | Confirm both Macs are on the same trusted LAN, choose **Browse LAN**, or use the host's direct address, port, and code. Do not weaken security or expose the port publicly. |
| Ollama is unavailable | Confirm the independent local service is running, choose **Refresh Models**, select a local model, and retry. Core play does not require AI. |
| The script editor says attached scripts are paused | Check and Save should still work: Check is read-only, and Save keeps the script dormant. The editor's explicit Run Once works before world trust but still requires `doScripts` on. Use the banner's **Trust World**, **Turn On Scripts**, or **Trust & Turn On** action only after reviewing its warning that existing attached scripts may start. |
| The script editor says the script runtime is unavailable | Check, Save, and Run Once are unavailable because authoritative Lua validation cannot run. Copy the retained draft, then restart the world or Elysium and retry. |
| Saved-world selection changed or reload is required | Review the current checked list. Use **Try Again** only after review; use the read-only reload when **Saved Worlds Need Reloading** appears. |
| Resource Packs says settings recovery is required | Stop changing settings and restart Elysium. The saved choice is unknown; the current-session pack generation remains on the prior selection, and further persisted settings changes are blocked until restart. |
| Resource Packs reports that disk durability was not confirmed | The selected pack generation was applied from exact reread settings bytes, but the directory-sync durability could not be confirmed. The recovery latch is not active; restart before relying on the choice surviving a system failure. |
| Performance or effects are uncomfortable | Reduce render distance, particles, shaders, or frame-rate demand; enable the relevant **Access** options. |

Current beta boundaries to keep in mind:

- Only Survival and Creative are available; there is no Hardcore or Spectator mode.
- The map is a live view, not a named/saved map system.
- Controller support is limited to skill actions and trading rather than complete game control.
- Multiplayer is LAN-only, join codes do not make a hostile LAN safe, LAN clients cannot trade, and
  skill-tree state and action resolution remain host-owned.
- Faithful 64x is the pinned baseline. Open **Options... → Video → Resource Packs...** to enable or
  disable Ore Borders 64x and Static Lanterns independently. Both optional add-ons start off; a named
  validation/load error leaves the prior selection active rather than silently applying a partial stack.
- Existing saved full chunks are not regenerated to receive newer terrain-placement guarantees.
- Local AI is optional and depends on an independently running Ollama service.

For an ordinary bug or feature request, use the
[Elysium issue tracker](https://github.com/mweingartner/elysium/issues). For a suspected vulnerability,
follow the private reporting instructions in [Elysium's security policy](SECURITY.md).

Before sharing logs, screenshots, saves or world databases, inspect them for personal data. World,
player, and template names, chat or AI requests, and filesystem paths can identify you or reveal private
information.
