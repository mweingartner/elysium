# Dinosaur audio verification

The warning-free isolated production build changes only the Elysium application target.
Audio.swift adds bounded bundled PCM decoding, selected cue playback and listener-relative
40-block creature attenuation; it does not change storage, Core, Lua, save, or LAN authority.

The five focused audio tests passed, including all 36 species/action mappings and actual
PCM rendering that becomes silent outside the radius and resumes inside it. The asset
validator accepts all 108 unique mono 24 kHz / 16-bit WAVs and rejects a deliberately
truncated copy. Source security checks passed. The full impact-selected regression run
passed all 2790 tests, and `swift run -c release elysmoke` passed all 491 golden checks
with no failures or build warnings. Full release gates remain mandatory.

A built, signed isolated debug app was exercised in a new Lost World v3 (seed 902626).
Live subtitles confirmed feeding/call routing, Parasaurolophus injury after a player strike,
and Compsognathus attack against a survival player. These observations establish semantic
routing, not subjective listening acceptance. Test settings were restored afterward.

## Worktree-dependent release gate

The isolated release pipeline stopped at the unchanged ElysiumStorage.o artifact pin.
The normalized original-checkout object is
`43ea474d75be3fc2311f1a95295c94d23329249f505ed0c14878f7318e14b3a8`;
the same source built in the isolated checkout produces
`c72b8e577742fc41b94697f5772614917c89ac82505d894f36d2d6368ae94186`.
Both normalized objects are 991104 bytes, differing at only offsets 142548 and 142549,
consistent with a source-path-length immediate. This existing build-path dependence is
also recorded in docs/ray-traced-worlds/build.md. No unrelated pin was renewed or gate
bypassed. The original checkout must be safely available for final release verification.

Source provenance, subscription usage and listening limitations are recorded in
[the audio authoring README](../../Assets/dinosaur-audio/README.md).
