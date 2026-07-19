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
- [Optional character classes](#optional-character-classes)
- [Trade with villagers](#trade-with-villagers)
- [Save, manage, and recover worlds](#save-manage-and-recover-worlds)
- [Local-network multiplayer](#local-network-multiplayer)
- [Object templates](#object-templates)
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
   - **Rich Resources** increases the world's resource emphasis.
   - **Single Biome** adds a separate **Biome** choice.

   **Debug Mode** is an advanced diagnostic preset, not part of the normal cycle. Hold Option while
   activating **World Type** only if you deliberately want to expose that extra choice.
7. Set **Dungeons** to **None**, **Normal**, **More**, **Plentiful**, or **Many**. **None** disables new
   dungeon placement; each later setting increases the number of placement attempts during generation.
8. Leave **Character Classes: On** if you want the optional RPG character system in this world. Turn it
   off for the base survival experience without character creation or character abilities.
9. Choose **Create World**. **Generating world...**, **Loading world…**, and **Building terrain** mean
   Elysium is working. Wait for the world to open; do not repeatedly submit creation.

### A practical first day

- Gather logs and turn them into basic building and crafting materials.
- Make a crafting table to move from the inventory's 2×2 crafting area to a 3×3 grid.
- Craft a wooden pickaxe, mine stone, and upgrade your tools.
- Collect food and make a lit shelter before exploring far from your starting area.
- Look at **Advancements** from the pause menu when you want the next major progression objective.
- If classes are enabled, open the character interface when you are ready to create a character; the
  world remains playable before character creation.
- Press Escape and choose **Save & Quit to Title** when ending the session. Worlds also autosave during
  play, but **Save & Quit to Title** is the recommended clean exit.

### Pause, resume, or recover

Escape opens the paused **Game Menu**:

| Choice | What it does |
| --- | --- |
| **Back to Game** | Resume the current world. |
| **Advancements** | Review the main survival progression. |
| **Options...** | Change video, audio, controls, accessibility, or local-AI settings. |
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
| RPG Character | `K` |
| Cycle RPG Action | `O` |
| Use RPG Action | `L` |
| RPG Quick Slot 1 | `Shift+1` |
| RPG Quick Slot 2 | `Shift+2` |
| RPG Quick Slot 3 | `Shift+3` |
| RPG Quick Slot 4 | `Shift+4` |
| RPG Quick Slot 5 | `Shift+5` |
| RPG Quick Slot 6 | `Shift+6` |
| RPG Quick Slot 7 | `Shift+7` |
| RPG Quick Slot 8 | `Shift+8` |
| RPG Quick Slot 9 | `Shift+9` |

Double-tapping forward also starts sprinting with the default movement setup.

### Fixed mouse and application shortcuts

These inputs are routed separately and do not appear as configurable gameplay bindings:

| Input | Action |
| --- | --- |
| Mouse movement | Look around. |
| Left click | Attack or break; use a held consumable; confirm template placement. |
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

Physical-controller support currently covers the RPG interface/actions and villager trading sheet. Do
not expect a controller to replace the keyboard and mouse for movement, camera, inventory, or crafting.

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
live map visible during play. It also shows air while submerged, RPG quick slots when available, and
the health of a living mount while you ride it. Your inventory exposes the equipped armor and offhand
slots. Use `F1` when you want an unobstructed view and `F3` when you need the debug overlay.

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

## Optional character classes

Character classes add a second, optional progression layer to a world. They are available only when
**Character Classes: On** was selected during world creation. Ordinary experience and **Advancements**
continue to track the base survival journey; character levels, skill points, skills, prepared actions,
fatigue, and cooldowns belong to the RPG layer. There are no attributes in this system — a character's
health and fatigue grow automatically with level, at a fixed rate set by its path.

### Choose a path and a sub-class

- **Warden** focuses on armor, shield timing, threat, and protection. Sub-classes: Guardian, Vanguard, and
  Bulwark. Health 26 (+2 per level), Fatigue 10 (+1 per level). Progress through melee victories and
  protecting or mitigating damage.
- **Ranger** focuses on bows, scouting, terrain movement, and survival. Sub-classes: Marksman, Scout, and
  Survivalist. Health 20 (+1 per level), Fatigue 14 (+2 per level). Progress through ranged victories and
  field discoveries.
- **Delver** focuses on mining, traps, underground travel, and treasure. Sub-classes: Miner, Trapper, and
  Treasure-Seeker. Health 24 (+2 per level), Fatigue 12 (+1 per level). Progress through deep exploration,
  dungeons, and excavation.
- **Arcanist** focuses on spellcasting, illusions, wards, and rituals. Sub-classes: Elementalist,
  Illusionist, and Ritualist. Health 16 (+1 per level), Fatigue 20 (+3 per level). Progress through spell
  practice and spell victories.
- **Mender** focuses on healing, food, antidotes, and rescue. Sub-classes: Physic, Harvest, and Sanctuary.
  Health 18 (+1 per level), Fatigue 18 (+2 per level). Progress through healing, cleansing, rescues, and
  provision crafting.
- **Tinker** focuses on redstone, automation, gear, and explosives. Sub-classes: Redstone, Artificer, and
  Sapper. Health 20 (+1 per level), Fatigue 16 (+2 per level). Progress through new recipes, mechanisms,
  and engineering crafts.

Each sub-class defines a three-skill tree, and every skill has 5 ranks. Skills in your chosen sub-class
cost 1 skill point per rank; skills that belong to one of the path's other two sub-classes cost 2 skill
points per rank. Each skill also has its own level requirement per rank, so a focused build reaches its
defining abilities sooner. You gain a skill point for every level after level 1, plus a bonus skill point
at levels 4, 7, 10, 13, 16, and 19.

### Create the character

Character creation is four steps — **Path → Sub-class → Starting Skills → Review** — and every card is a
single click: clicking a card both selects it and advances to the next step (or, on Starting Skills,
toggles it).

1. **Path** — click one of the six path cards. Each card shows the path's focus and its health/fatigue
   growth.
2. **Sub-class** — click one of the chosen path's three sub-class cards. Each card lists its three skills
   and any spell its signature skill grants.
3. **Starting Skills** — click to choose exactly 3 starting skills, each granted at rank 1, from a pool of
   5: your sub-class's 3 skills plus the signature (first) skill of each of the path's other two
   sub-classes. The pool's three signature skills are preselected by default — choosing them reproduces
   the path's classic starting skills, including its starter spells, if any. The screen tracks your choice
   with "Starting skills: *n* of 3 chosen"; a 4th click is blocked once you have 3 until you unchoose one
   first.
4. **Review** — check the path, sub-class, chosen starting skills, any spells granted, the health/fatigue
   growth line, and the starter kit. **Reject** discards the draft and closes without confirmation,
   **Back** returns to Starting Skills with your choices intact, and **Accept** creates the character and
   starter kit together. **Accept** can remain disabled when the current player is not allowed to make the
   change or required inventory capacity is unavailable; follow the visible explanation and retry.

Every step also has a keyboard/controller path: Tab or the arrow keys move focus, Enter/Space/A activates
the focused card or button, and Escape/B steps back (or closes, on the first step).

After creation, the interface has five tabs:

- **Character** summarizes the character's path, sub-class, level, and current selections, along with
  Health and Fatigue shown as base plus per-level growth (for example, "Health 38 (26 + 2 per level)").
- **Skills** shows a **Skill Points** total and one card per skill, grouped by sub-class (your chosen
  sub-class first). Each skill's progress is five pips — filled for earned ranks, hollow for the next
  purchasable rank or a rank you don't yet qualify for. A skill at rank 5 is labeled **Mastered**. Passive
  skills are always on once learned; they never consume a prepared slot.
- **Actives** prepares learned active skills. Up to four active skills can be prepared, then assigned to
  the RPG quick slots.
- **Spells** prepares learned spells. Up to six spells can be prepared, then assigned to quick slots.
- **Progression** shows the selected route, level requirements, automatic rewards, and future steps.

Cycle or activate prepared active skills and spells with the configurable RPG bindings. Fatigue and
cooldowns can temporarily prevent an otherwise prepared action; the interface shows the current reason.
Some character operations remain unavailable to LAN clients because the host owns the world simulation.

If you open a character created before this system was simplified, Elysium migrates it automatically the
first time you load it: the character keeps its path, sub-class, level, and skill ranks; health and
fatigue are recalculated from the level-growth table above; any points freed by the retirement of
attributes become available to spend on the Skills tab; and you see a one-time notice — "Your character
was updated: attributes are retired. Health and fatigue now grow with your level. Unspent skill points are
ready on the Skills tab."

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
> data, Advancements, and RPG data. There is no cloud copy or guaranteed recovery. Back up first if you
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

1. Choose **Multiplayer** and **Browse LAN**.
2. Select a discovered world. If discovery is unavailable, enter **Manual Host**, the join-side **Port**,
   and any required **Code** supplied by the host.
3. Review **Player**, then choose **Join World**.

A join code is an access gate, not encryption and not a defense against other hostile participants on the
same LAN. Current LAN clients cannot trade and some RPG character operations remain host-only.

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
template placement, not to every ordinary building action.

## Options, accessibility, and local AI

**Options...** contains five tabs:

- **Video** controls render distance, field of view, brightness, GUI scale, graphics effects, fullscreen,
  particles, frame-rate limit, and optional Ultra shaders.
- **Audio** controls the master level and categories such as music, blocks, creatures, players, ambient,
  jukebox, and UI.
- **Controls** manages sensitivity, inverted Y, and configurable gameplay bindings.
- **Access** contains **Subtitles**, **Auto-Jump**, **Reduce Motion**, **Reduced Flashes**, **High Contrast
  UI**, and **Darkness Pulsing**.
- **Ai** configures the optional local Ollama model.

Reduce render distance, particles, shader effects, or the frame-rate limit when performance or heat is a
problem. Use **Reduce Motion** and **Reduced Flashes** when camera movement or effects are uncomfortable;
**High Contrast UI** and **Subtitles** can make visual and audio information easier to follow.

### Optional local AI

AI is not required to play Elysium. To use it, independently install and run a local Ollama service, then
open **Options... → Ai**, enter or select an **Ollama Model**, and save it. **Refresh Models** discovers
models from the configured loopback service. Cloud-tagged model names are rejected on this Elysium
surface. Use `/ai <request>` in command input after a model is available.

Before you use `/ai`, understand the data flow: Elysium sends your request together with current game
context—including the world seed, player position and state, inventory, nearby state, and saved template
names or summaries—to the Ollama service through the local loopback address. Do not put secrets or
personal information in AI requests or template names. Elysium does not control an independently
configured Ollama installation or model provider's retention or onward handling.

Model output is treated as untrusted and reduced to a limited set of validated in-game actions. A request
can fail, produce no usable action, or be rejected without changing the world.

## Troubleshooting and current limitations

| Problem | What to try |
| --- | --- |
| A control does not respond | Open **Options... → Controls**, inspect the binding, use **Capture** or **Reset**, and resolve any shown conflict. Remember that fixed shortcuts are not in this list. |
| Typing goes nowhere | Focus the visible text field first. Close another open screen if it owns text input, then focus the intended field and try again. |
| Recipe list says **No craftable items** | Gather the missing resources or use the correct crafting grid or workstation. |
| Recipe list says **No matching recipes** | Shorten or clear the active search text. |
| **Trade** is disabled | Read its visible reason; check payment, stock, level, workstation, distance, line of sight, inventory room, and whether you are a LAN client. |
| Character controls are missing or disabled | Confirm the world was created with **Character Classes: On**. Read the visible creation/action reason; fix the starting-skill selection, preparation, fatigue, cooldown, authority, or inventory issue it identifies. |
| No LAN world appears | Confirm both Macs are on the same trusted LAN, choose **Browse LAN**, or use the host's direct address, port, and code. Do not weaken security or expose the port publicly. |
| Ollama is unavailable | Confirm the independent local service is running, choose **Refresh Models**, select a local model, and retry. Core play does not require AI. |
| Saved-world selection changed or reload is required | Review the current checked list. Use **Try Again** only after review; use the read-only reload when **Saved Worlds Need Reloading** appears. |
| Performance or effects are uncomfortable | Reduce render distance, particles, shaders, or frame-rate demand; enable the relevant **Access** options. |

Current beta boundaries to keep in mind:

- Only Survival and Creative are available; there is no Hardcore or Spectator mode.
- The map is a live view, not a named/saved map system.
- Controller support is limited to RPG and trading surfaces rather than complete game control.
- Multiplayer is LAN-only, join codes do not make a hostile LAN safe, LAN clients cannot trade, and some
  character operations remain host-only.
- Resource packs can be loaded by Elysium, but there is no discoverable in-game resource-pack management
  screen in the current beta.
- Existing saved full chunks are not regenerated to receive newer terrain-placement guarantees.
- Local AI is optional and depends on an independently running Ollama service.

For an ordinary bug or feature request, use the
[Elysium issue tracker](https://github.com/mweingartner/elysium/issues). For a suspected vulnerability,
follow the private reporting instructions in [Elysium's security policy](SECURITY.md).

Before sharing logs, screenshots, saves or world databases, inspect them for personal data. World,
player, and template names, chat or AI requests, and filesystem paths can identify you or reveal private
information.
