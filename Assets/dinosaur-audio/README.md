# Dinosaur audio authoring

The 36 prehistoric species each have grazing/feeding, attack, and injured WAVs in
`packaging/DinosaurSounds`. These are 108 distinct edits of 18 Suno source recordings
(six voice families), not 108 independently generated performances. This keeps the
work inside the subscription allowance: 36 generation credits and 18 downloads used;
2,464 credits and two downloads remained when verified on September 26, 2026.
No credits, downloads, or subscription upgrades were purchased.

`sources.json` preserves exact prompts, observed settings, official source links,
plan evidence, formats, durations, and SHA-256 checksums. `originals/` contains the
unaltered official WAV exports. The runtime manifest records every trim, pitch,
tempo, resonant EQ, peak target, fade, and resulting checksum. Feeding sources also
serve ambient/idle/browse/eat calls; hurt uses injured. Other cues retain their
species-specific synthesis.

Rebuild with `python3 scripts/build-dinosaur-sounds.py` (ffmpeg required only for
authoring). Validate with `python3 scripts/verify-dinosaur-sounds.py`. The validator
also runs during packaging and compares installed assets against the reviewed bank.
Runtime uses mono 24 kHz, 16-bit PCM, predecoded off the audio callback, with bounded
file size/duration and no network access. Asset changes require regenerated hashes
and renewed validation. Original recordings are not copied into the application.

Open [audition.html](audition.html) to play all 108 runtime clips.

Objective acceptance covers format, duration, nonzero signal, peak headroom,
silence at fade endpoints, unique hashes, all 36 species and three actions, actual
PCM mixer output, distance attenuation, and listener movement. Preview controls
were exercised in Suno, but audio perception was unavailable: the assistant did not independently listen for naturalness or unwanted music/voices.
On September 26, 2026 the user approved the T-Rex attack preview, then explicitly
accepted all 108 current clips. Approval is bound to their exact SHA-256 hashes so
regeneration cannot silently transfer approval to changed audio.
These are fictional sound designs, not scientifically reconstructed dinosaur calls.

The paid-plan and official-download observations support provenance under the linked
Suno terms. They do not guarantee copyright protection. No account identifiers or
billing details are retained here.
