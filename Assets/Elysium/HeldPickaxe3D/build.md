# Model-rendered pickaxe release-pin renewal

This change modifies only the Elysium application target: it embeds seven reviewed CC0
pickaxe renders, selects them ahead of the retired flat fallback, and removes nonuniform
held-item animation scaling. It does not modify ElysiumCore, ElysiumStorage, Saves,
GameCore, Player, ElysiumTextInput, or either storage capability manifest.

The first release-pipeline run on 2026-08-26 passed source security and the warning-free
release build, then stopped at the expected Elysium product-hash boundary. The reviewed
pin was renewed narrowly:

- `EXPECTED_ELYSIUM_PRODUCT_SHA256`
  - old: `bf67591da69f4974fd6c37c3cfa90cf8ebdab7256194e929bb234fccab922f8a`
  - new: `b46cda7a0cc807b04c61a555ed64ad5588bfe4a25b33c9d4acf9fd97953869bf`
- `EXPECTED_SMOKE_PRODUCT_SHA256` remains
  `71fc4a0089a74e7b71f6bbc02b47ac1c7dc652c15dac4cce02e689a972a638e1`.

Both candidate hashes were computed from disposable copies of the warning-free release
artifacts after `xcrun strip -S -x`, exactly matching
`scripts/verify-elysium-storage-release-surface.sh`. The unchanged `elysmoke` hash confirms
that the Core-linked smoke product did not move. All storage, Core, and text-input pins
remain untouched.
