# Elysium three-Mac LAN test lab

The controller Mac builds one signed app and deploys those exact bytes to Neo and Air. SSH owns
machine lifecycle and artifact transfer. Elysium's ordinary LAN socket owns multiplayer traffic.
Any richer debug-control service must remain bound to `127.0.0.1` and be invoked by a helper on the
same node through SSH; its session token must never be copied to the controller.

Protocol 6 is not active. Its parsers, state machines, admission accounting, and persistence
foundations are useful, but its current frames and credentials are plaintext and the production
transport has no v6 coordinator. The installed lab therefore tests hardened protocol 5 only on a
trusted private LAN. It is not a hostile-network security boundary.

## One-time node bootstrap

On each client Mac:

1. Sign in to the dedicated GUI test account and keep the session unlocked.
2. Enable **System Settings > General > Sharing > Remote Login** for that account only.
3. Read the host fingerprint locally:

   ```bash
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
   ```

On the controller, create a unique key and pin the matching fingerprint:

```bash
scripts/setup-lan-test-node.sh --node neo --host neo.localdomain \
  --user "$USER" --fingerprint SHA256:VALUE_FROM_NEO --accept-full-shell
scripts/setup-lan-test-node.sh --node air --host michaels-air.localdomain \
  --user "$USER" --fingerprint SHA256:VALUE_FROM_AIR --accept-full-shell
```

`--accept-full-shell` is an explicit trust decision: autonomous build deployment, process
lifecycle, evidence collection, and node-local `elydebug` invocation require arbitrary
noninteractive commands as that GUI user. Use a dedicated non-admin test account. The printed
`restrict,from=...` key is source-IP restricted and cannot allocate a PTY or use agent/X11/TCP
forwarding, but OpenSSH `restrict` is not a command allowlist. Protect the controller private key
accordingly. Install the exact printed line in the matching account, with `~/.ssh` mode `0700` and
`authorized_keys` mode `0600`.

The setup command refuses a hostname that scans to more than one distinct Ed25519 host key; use a
specific address or correct node DNS instead of pinning an unverified extra key.

Check each node without changing its app:

```bash
ELYSIUM_LAN_CLIENT_HOST=neo.localdomain \
ELYSIUM_LAN_CLIENT_IDENTITY="$HOME/.ssh/elysium_neo_ed25519" \
scripts/deploy-lan-client.sh --check

ELYSIUM_LAN_CLIENT_HOST=michaels-air.localdomain \
ELYSIUM_LAN_CLIENT_IDENTITY="$HOME/.ssh/elysium_air_ed25519" \
scripts/deploy-lan-client.sh --check
```

macOS records Local Network permission per user and app identity. Launch the installed app once on
each node and approve its Local Network prompt before expecting unattended Bonjour or direct LAN
traffic.

## Deployment guarantees

`deploy-lan-client.sh` fails closed unless the dedicated identity and pre-pinned `known_hosts` file
exist. It deploys only to `~/Applications/Elysium.app`. Before activation it verifies archive
SHA-256, executable SHA-256, bundle identifier, the production debug-control isolation scan, and
`codesign --verify --deep --strict` remotely.
The old bundle is moved to a run-specific backup and restored automatically if activation,
attestation, or exact-path launch fails.

Protocol 5 binds durable guest state to a host-issued 256-bit reconnect capability. A bare
caller-chosen UUID cannot inherit a disconnected player's position, inventory, RPG state, or
permissions, and legacy rows without a capability are not restored. The capability is still sent
over plaintext protocol 5 and stored in each node's user defaults, so a hostile LAN observer or a
compromised account can steal it. Protocol-v6 authenticated encryption and Keychain ownership are
still required before treating this as an adversarial-network identity boundary.

## Map streaming and render budget

Initial map transfer sends bounded RLE-compressed chunk sections; subsequent world edits use
replication deltas. Admission validates the compressed runs without materializing a cell array;
world application decodes once and reuses that buffer for all 4,096 cells, eliminating the former
per-cell re-decode. Visible-band
requests retain priority: background full-column completion runs at 10
requests per second, below the host's shared 30-request-per-second bucket. A request can force at
most one synchronous missing-chunk generation on the host main actor; remaining nearby chunks are
filled by ordinary asynchronous host streaming around replicated guest positions.

The renderer rejects empty sections, sections outside render distance, and section AABBs outside
the camera frustum before issuing layer draws. It reuses one visible-section array across opaque,
cutout, and translucent passes. The shadow pass now applies a light-frustum AABB test in addition
to its cheap range bound. Authenticated debug snapshots expose culling counts and draw calls so any
future HZB/occlusion work can be justified with measurements and conservative invalidation rules.

## Required three-node receipt

A complete run must record the exact executable hash on all nodes, the host plus exactly two
accepted peers, distinct Neo/Air identities, independent client intent convergence, container and
inventory conservation, one-client reconnect while the sibling remains live, structured logs and
captures from all nodes, and clean termination of every app and `caffeinate` process.
