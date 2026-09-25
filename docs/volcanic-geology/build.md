# Rich Resources and prehistoric geology verification — September 24, 2026

## Scope and measured behavior

Rich Resources restores ordinary cave-noise/carver density beneath its ore-rich
rolling terrain. New v3 prehistoric maps widen caves, increase tunnel/ravine
starts, and add rare small volcanoes. Both expand inland lava-aquifer regions
without lifting their Y=12 level or replacing ocean/groundwater precedence.
Existing dinosaur v1/v2 IDs retain their terrain and simulation contracts.

The focused final run passed **80 tests**. An additional **10 existing exact
terrain and surface-collision tests** passed. Coverage includes old terrain
identity, all 12 save/LAN profile round trips, current creation UI, all four v3
starter huts/groves, Ancient Seas marine habitat, volcano containment and
negative-coordinate chunk clipping, structure conflicts, and bounded stronghold
collision work. Logs: `/tmp/elysium-volcanic-focused-final.log` and
`/tmp/elysium-volcanic-structure-tests.log`.

Measured fixtures, not world-wide guarantees:

| Survey | Legacy dinosaur v2 | Dinosaur v3 | Rich Resources |
| --- | ---: | ---: | ---: |
| Dry underground air, 24 chunks / six regions / two seeds | 52,683 | 65,148 | 53,491 |
| Underground void cells, same sample | 55,433 | 70,068 | 56,921 |
| Lava cells above Y=-48, 24 chunks in six aquifer-transition regions / three seeds | 3,508 | 7,771 | 4,266 |
| Lava-bearing columns, same transition sample | 707 | 1,249 | 894 |

The broad aquifer survey sampled 3,267 separated coordinates across three seeds:
lava-bearing samples increased **287 → 477**, while all 1,571 existing water
samples retained their type and level. The transition-region survey deliberately
selects newly eligible aquifer locations; it demonstrates materialized extra
lava, not a representative map-wide lava percentage. The cave survey uses
independently fixed regions, excludes the bottom lava layer and cells within
eight blocks of the surface, and finds **23.7% more dry cave space** in v3.
Rich Resources also matches Default's complete worm/ravine output on matched
solid-terrain fixtures, replacing its former intentionally suppressed carvers.

The production volcano fixture is Lost World v3, seed `5366106`, origin chunk
`(-20,-37)`, center `(-312,-584)`. Full chunk generation preserves its contained
crater lava through decoration/snow and leaves valid natural-tree provenance.
Two issues found during review were fixed before the final passing run:
the foliage cache now includes the volcano's complete collision domain, and
collision checks enumerate actual stronghold ring origins instead of hundreds
of impossible lattice positions that could purge the shared plan cache.

The first full release run found one terrain-dependent assertion: the unchanged
real Rich Resources village survey now measures None=0, Few=0, Normal=3,
Many=5, Max=7 against a former Max minimum of eight. All other tests passed,
including generated settlement geometry, support, collision, and the separate
historical live-world dungeon/animal/village probe. This is a deliberate terrain
revision, so the reviewed fixture floor is seven and it additionally requires
Max to exceed Many. The seed/envelope and all safety/monotonicity assertions are
retained. We rejected changing village admission, suppressing the requested
caves around this seed, or searching for a replacement seed merely to recover
eight. The precise rejected candidate was not isolated; no claim is made about
its specific support cell or the old generator's actual count. No golden file
was regenerated. The revised density test passed independently in 66.947 seconds
(`/tmp/elysium-volcanic-village-density.log`).

## Release boundary

No storage, text-input, renderer, block/entity registry, or save-codec source
changed. Saved full-block chunks are not rewritten. Unmodified Rich Resources
areas saved only as entity records can regenerate with the revised geology;
v1/v2 dinosaurs retain their original generator even for regenerated chunks.
V3 adds recognized IDs through
the existing strict save/LAN validation path; future v4 IDs remain rejected.
The only release-surface pins requiring renewal are the Core object and its two
linked products. Artifact hashes are computed on disposable copies using
`xcrun strip -S -x`, then `shasum -a 256`; the original build artifacts are never
stripped. No golden changes are intended.

## Native inspection and reviewed pin renewal

The warning-free optimized inspection app passed packaging with executable
SHA-256 `59c5bf421f0ac7a04e1abe169c6ce1bfa4479ab75cece9a1bbc4a148d0a68a07`.
A disposable Lost World v3 was created through the real game, spawned inside
the supplied hut, then streamed the fixture above. After the surrounding chunks
loaded, the actual Metal frame showed a complete grounded cone, exposed
contained crater lava, an unobstructed rock apron, and intact surrounding
forest. The camera at `(-312,108,-552)`, yaw pi, pitch `0.94` shows the entire
landmark. Capture `b8ebb397-9d73-4b6e-8729-543f72287d35` has SHA-256
`5db7da6be7f3cc3e6a2a7cf8489358947cb44dffeb9538aa80cb08ebff199a02`.
This is native renderer inspection, not a claim of human/user visual approval.

The separate ordinary `swift build -c release` completed with no warnings.
Normalized disposable-copy pins from `.build/out/Products/Release`:

| Artifact | Previous SHA-256 | New SHA-256 |
| --- | --- | --- |
| ElysiumCore.o | `6ac3ca7edcfe7cdf4ac0ed5a69e43f32221a27a8c37a1b19b71d422a6b086fbc` | `ea2d96cf2b3075443f8a58e22a1c6e8c8eaa7ab0b227234a016361400ea4a498` |
| Elysium | `db2d0e79e5e5a720920e92311b002aaa478c5f3f2ed32c62f4477a114693de03` | `062c1a14c02349ad589525a620818bbd7159e3891fc1e0deb07e079bc8198093` |
| elysmoke | `450f4f5d43c1ad67dca18615db8f2443670309b1ef6f7f917cffefe32c49d5b1` | `3f5260664269be010db64237b3da923021fcfb0bcfa315126f2f16fb5f7cb1a9` |

ElysiumStorage.o remains
`43ea474d75be3fc2311f1a95295c94d23329249f505ed0c14878f7318e14b3a8`;
ElysiumTextInput.o remains
`0fcd8840b58e2db50fc3556144417b4615d99f1e7bb75344dd259149dd705bf3`.
Every source/API/capability pin remains unchanged. Product changes are confined
to generation/profile code and linked consumers, not storage authority.

## Production closeout

The final production pipeline passed all nine stages on September 24, 2026:
source security, warning-free release build, release-surface/binary verification,
all **2,593 XCTest cases** (counted from individual passing cases across the six
targets), **491 elysmoke checks**, signed packaging, native AppKit text entry,
installation, and installed identity/strict codesign verification. No goldens
changed. Log: `/tmp/elysium-volcanic-pipeline-final.log`.

The installed production executable at `/Applications/Elysium.app` has SHA-256
`d32c9b7e1ad94e764692bc5ac8bfc2ffd17bf3c02284315a847727a37d55ea97`.
The inspection app was not installed as production, and its disposable world
was deleted. This results section is a documentation-only addition after the
pipeline; no product source changed afterward. Commit/push and remote parity
are verified separately at publication rather than inferred from installation.
