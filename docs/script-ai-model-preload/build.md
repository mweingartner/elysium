# Script AI saved-model preload release-pin receipt

This change modifies only the Elysium application target. Showing the Script AI panel now refreshes
the installed local-model list and preloads the exact persisted local model through Ollama's empty,
non-streaming `/api/generate` operation. The request carries no script source, prompt, world data,
or generation tools. Off mode remains a no-contact boundary, and failed preloads remain retryable.

The release pipeline passed source security and its warning-free optimized build on 2026-08-28,
then stopped at the expected Elysium product-hash boundary. The pin was renewed narrowly:

- `EXPECTED_ELYSIUM_PRODUCT_SHA256`
  - old: `78a1d49fc33e00b0382f42ba9b837e04134f66cb2bdc11c5850ce9b810565de5`
  - new: `5fece49d480bd5e9b6b84ef5a37ba1ea8fa60d20760ff9297e37854986e7d075`

The candidate hashes came from the same warning-free release artifacts. Each was copied to a
disposable directory, made writable, normalized with the `xcrun --find strip` result using
`strip -S -x`, and hashed with `shasum -a 256`, exactly as
`scripts/verify-elysium-storage-release-surface.sh` does.

The following reviewed artifact pins were recomputed and remained byte-identical:

- `EXPECTED_STORAGE_OBJECT_SHA256`:
  `33fb1578d8262a4044ba42ccb1fc7b67e8dfac2589133ab2ff415b5a5d71326b`
- `EXPECTED_CORE_OBJECT_SHA256`:
  `6f2c08d5d9f5b1371fcaa08eaa588b18bb7c311e7943f66f31e57753bf4eb809`
- `EXPECTED_TEXT_INPUT_OBJECT_SHA256`:
  `ca500f11c671c45b6a0648962bed37881a9adff2a6491632e7d655a50ed80efc`
- `EXPECTED_SMOKE_PRODUCT_SHA256`:
  `71680aec7314a60713b192f253b3e7cf6b379f265221826a6838354a6e88f3e8`

All reviewed storage/Core/text-input source and capability-manifest pins also remain untouched.
Focused final-tree verification before renewal was four `ScriptEditorAIPanelTests`, all passing.
