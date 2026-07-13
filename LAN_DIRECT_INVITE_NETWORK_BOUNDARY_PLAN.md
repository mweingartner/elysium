# LAN Direct-Invite Network Boundary Plan

Status: Architecture gate for the `LANDirectInviteV6` Network.framework import blocker.

## Gate classification

- **Design Mock: N/A.** This remediation changes no screen, command syntax, copy, focus behavior,
  accessibility behavior, or accepted canonical invite. It restores an implementation boundary
  beneath the already frozen direct-invite contract.
- **Architecture: PASS**, subject to the Conditions for Builder below.
- **Design Review/Revision: N/A.** No human-visible contract is intended to change. Any valid invite
  that changes serialization or acceptance returns the work to Architecture and Design Review.
- **Security (plan): pending independent review.** This is untrusted structured-input and local-
  network boundary work, so Build remains blocked until Security returns PASS.
- **Design Sign-off: N/A.** The focused remediation has no intended visible state. The later complete
  Direct Invite feature still requires its separately planned installed-app design sign-off.

## Evidence and first-principles decision

`scripts/security-scan.sh` currently fails because
`Sources/ElysiumCore/Net/LANDirectInviteV6.swift` imports Network.framework. That is not a false
positive: `ARCHITECTURE.md`, `CONTRIBUTING.md`, `SECURITY.md`, and the package target split reserve
Network.framework, DNS resolution, endpoints, and sockets for `Sources/Elysium/LANTransport.swift`.
`ElysiumCore` owns bounded protocol values and deterministic validation.

The chosen design is a bounded, side-effect-free address parser in `ElysiumCore`: strict pure-Swift
IPv4 validation plus Darwin `inet_pton`/`inet_ntop` IPv6 parsing/canonicalization. It does not resolve
DNS, inspect interfaces, open sockets, or import Network.framework. Darwin is already used by the
headless core for address normalization, and `Package.swift` supports macOS 14 or newer only.

Moving canonicalization behind `LANTransport.swift` is rejected. It would split one untrusted invite
parse across targets, permit a temporarily unvalidated host value, make the headless canonical codec
dependent on an app callback, and create two validation paths between UI/CLI/environment inputs. It
would also make `LANDirectInviteV6` unable to enforce its own encode/decode/encode invariant.

Expanding the scanner allowlist is rejected. Address *syntax* validation is not transport work, and
allowlisting Network.framework in `ElysiumCore` would weaken the machine-enforced guarantee that all
actual network capability stays in the app adapter.

## Frozen behavior and invariants

The builder must preserve all valid behavior in `LAN_RPG_PROTOCOL_V6.md` lines 637-672:

1. Input is `1...1,024` printable ASCII bytes, with `%`, whitespace, controls, and trailing data
   rejected before authority/query work.
2. Host is one byte-canonical dotted IPv4 literal, one bracketed byte-canonical IPv6 literal, or a
   lowercase ASCII DNS name of `1...253` bytes with labels of `1...63` bytes matching the existing
   grammar. DNS validation never resolves a name.
3. Port, query order, IDs, lookup digest, and join code retain their existing exact domains and error
   mapping. Lookup digest verification still precedes any future DNS or TCP work.
4. `parsed.serialized == rawValue` remains mandatory. Constructed invites must also serialize to a
   value that the parser can accept; a scoped IPv6 zone such as `%lo0` is not a valid invite host.
5. No invite, join code, full identity, or raw candidate is logged or interpolated into an error.
6. Address parsing is deterministic, allocation-bounded by the 253-byte host cap, and independent of
   locale, DNS state, interface state, and collection iteration order.

For malformed inputs, public error parity is frozen:

- empty/over-cap/non-printable host or noncanonical address/DNS spelling -> `.invalidHost`;
- malformed bracket/authority delimiter shape -> `.invalidAuthority`;
- invalid or noncanonical port -> `.invalidPort`;
- other invite errors remain exactly as currently declared in `LANDirectInviteV6Error`.

The only intentional tightening is to reject a direct `LANDirectHostV6` construction containing `%`
or another value that could never survive `LANDirectInviteV6(parsing:)`. Such a value is already
outside the frozen invite grammar and currently violates the constructor/serializer round-trip
invariant; it is not an accepted human-visible invite.

## Exact implementation contract

### 1. `Sources/ElysiumCore/Net/LANDirectInviteV6.swift`

1. Remove `import Network`; add `import Darwin` beside Foundation.
2. Add an internal, non-public namespace `LANIPAddressCanonicalizerV6` so `@testable` tests can
   exercise the primitive without widening Elysium's API:

   ```swift
   enum LANIPAddressCanonicalizerV6 {
       static func canonicalIPv4(_ value: String) -> String?
       static func canonicalIPv6(_ value: String) -> String?
       static func isLegacyIPv4Candidate(_ value: String) -> Bool
   }
   ```

3. `canonicalIPv4` is pure Swift, not `inet_aton`:
   - require `1...15` ASCII bytes;
   - split into exactly four nonempty dot-separated components without omitting empties;
   - require each component to contain only ASCII decimal digits, have no leading zero unless it is
     exactly `"0"`, and accumulate with an overflow-safe `value = value * 10 + digit` check capped at
     255;
   - return the original string only after all four components pass. It must not allocate or accept
     legacy one-, two-, or three-part, octal, or hexadecimal IPv4 spellings.
4. `isLegacyIPv4Candidate` exists only to preserve the current Network.framework ambiguity behavior
   before DNS fallback. It must be a bounded ASCII recognizer, not a resolver: recognize the complete
   legacy numeric-address families currently parsed as IPv4 but rejected after reserialization
   (one to four numeric components using decimal, `0`-prefixed, or `0x`/`0X`-prefixed forms), while
   rejecting ordinary DNS labels. The exact reference oracle is the existing
   `IPv4Address(value).map(String.init(describing:))` behavior in the test target. If a proposed pure
   recognizer cannot match that oracle for the fixed and seeded corpus, the builder must stop and
   return to Architecture; it must not silently make an ambiguous numeric spelling a DNS name.
5. `canonicalIPv6`:
   - require `1...253` printable ASCII bytes and reject `%`, brackets, and embedded NUL before C API
     use;
   - call Darwin `inet_pton(AF_INET6, ...)` into a zero-initialized `in6_addr`;
   - explicitly reject only the scoped-address forms for which the supported Network.framework
     reserialization is `"?"` while Darwin would emit a textual literal. The bounded byte predicate
     (after successful `inet_pton`) is `bytes[2] != 0 || bytes[3] != 0` and either: link-local
     `fe80::/10`; multicast with scope nibble `1`; or multicast with scope nibble `2` and flags not
     equal to `0x30`. This preserves ordinary multicast such as `ff02::1` when Network reserializes
     it byte-identically, while rejecting only the proven divergence. It performs no route/interface
     lookup and must be documented in code as compatibility behavior, not a reachability policy.
   - only on return value `1`, call `inet_ntop(AF_INET6, ...)` into a fixed
     `INET6_ADDRSTRLEN` buffer;
   - return `String(cString:)` only when `inet_ntop` succeeds; otherwise return `nil`.
   No errno text or input is exposed. The caller accepts IPv6 only when returned bytes equal the
   supplied bytes, preserving the current Network.framework reserialization rule.
6. At the very start of `LANDirectHostV6.init`, before splitting/copying/parsing, require host UTF-8
   count `1...253`, printable ASCII `0x21...0x7e`, and no `%`; failure is `.invalidHost`.
7. Replace `IPv4Address`/`IPv6Address` calls with the helpers. Order is strict:
   - accept exact `canonicalIPv4` equality as `.ipv4`;
   - if `isLegacyIPv4Candidate` is true, fail `.invalidHost` rather than falling through to DNS;
   - accept exact `canonicalIPv6` equality as `.ipv6`; the bounded Network-incompatible scope forms
     (and any other helper failure) are `.invalidHost`;
   - retain the existing digit-and-dot attempted-IPv4 rejection as defense in depth;
   - finally apply the unchanged DNS grammar as `.dns`.
8. In `parseAuthority`, retain all delimiter and error behavior. For a bracketed authority, validate
   by constructing `LANDirectHostV6`, require `.ipv6`, and do not run a second standalone IPv6 parser.
   This removes duplicated canonicalization and guarantees direct construction and parsing share one
   decision. Unbracketed values containing zero or multiple colons remain `.invalidAuthority`.
9. Do not change the public structs, enum cases, serialized form, query parser, digest validation,
   access levels, or any transport API.

### 2. `Tests/ElysiumCoreTests/LANDirectInviteV6Tests.swift`

Keep all existing cases and add these fixed, deterministic gates:

- IPv4 accept boundaries: `0.0.0.0`, `0.0.0.1`, `127.0.0.1`, `192.168.1.20`, and
  `255.255.255.255`.
- IPv4 reject table: empty components, too many/few components, values 256+, signs, whitespace,
  leading zeros, and legacy spellings including `127.1`, `2130706433`, `0x7f000001`, `0xffffffff`,
  `0177.0.0.1`, and `0300.0250.0001.0024`. Assert these are not reclassified as DNS.
- IPv6 accept boundaries and serializer cases: `::`, `::1`, `1::`, `2001:db8::1`, an equal-length
  zero-run leftmost tie, `::ffff:192.0.2.128`, and
  `64:ff9b::c000:221`.
- IPv6 rejects: uppercase, leading-zero groups, non-minimal/uncompressed forms, wrong zero-run
  compression, too few/many groups, multiple `::`, unbracketed literals, brackets passed directly
  to `LANDirectHostV6`, IPv4-mapped noncanonical hex spelling, `%` zone/scope identifiers, and the
  empirically verified scoped forms matching the compatibility predicate (including link-local
  `fe80:0000:0001::1` and multicast scoped/flag variants). Ordinary multicast boundaries such as
  `ff00::`, `ff02::1`, `ff01::1`, `ff0e::1`, and `ff22::1234` must remain accepted when their
  Network.framework reserialization is byte-identical.
- Constructor/parser equivalence: every accepted `LANDirectHostV6` can build an invite whose
  serialization reparses byte-identically; every parser-accepted host has the same `Kind` and value.
- Oversize direct-host construction at 254 bytes fails before address/DNS parsing. Existing
  1,024/1,025/10,000,000-byte invite tests remain.
- Add a macOS test-only Network.framework oracle (`import Network` is permitted in Tests, never in
  `Sources`): compare pure IPv4 classification and POSIX IPv6 output/acceptance with the pre-change
  `IPv4Address`/`IPv6Address` plus byte-identical reserialization semantics for the complete fixed
  corpus. The oracle must treat `String(describing: IPv6Address(...)) == "?"` as rejected, compare
  the bounded compatibility predicate against that result, and include both accepted ordinary
  multicast and rejected scoped-address values so this exact rule cannot regress.
- Add a fixed-seed, fixed-count property test of at least 10,000 bounded host candidates drawn from
  ASCII address/DNS punctuation. Compare the new `LANDirectHostV6` result to an independent reference
  model that uses Network.framework only for IP recognition and a separately implemented DNS grammar.
  Report the seed and failing candidate as escaped bytes, never as an invite containing secrets.
- Add at least 4,096 generated 16-byte IPv6 values: serialize the Network.framework oracle, require
  the new canonicalizer to produce the same bytes for every oracle value other than `"?"`, and require
  rejection for every oracle `"?"`; then assert host/invite encode-decode-encode idempotence.
  Mutating canonical text by uppercase, redundant leading zero, or nonminimal expansion must either
  remain byte-identical or be rejected; it may never normalize silently.
- Add a separate fixed-seed 100,000-sample raw-16-byte parity property that computes the documented
  second-word/scope/flags predicate and compares it with the test-target Network.framework result
  (`String(describing:) == "?"`). A mismatch is an Architecture failure; do not broaden the reject
  predicate to all multicast or accept a `"?"` result.

Tests must not skip or reduce counts based on environment. A corpus discrepancy blocks Build and
returns to Architecture; it is not resolved by deleting a case or importing Network in production.

## Files explicitly unchanged

- `Sources/Elysium/LANTransport.swift`: remains the sole Network.framework/DNS/socket adapter. No
  canonicalization callback or new public API is added.
- `scripts/security-scan.sh`: no allowlist change. Its existing failure must turn green solely because
  `ElysiumCore` no longer references Network.framework.
- `Package.swift`: no target dependency or linker change.
- `LAN_RPG_PROTOCOL_V6.md`, `ARCHITECTURE.md`, `CONTRIBUTING.md`, `SECURITY.md`: no durable behavior or
  architecture text changes are needed; the implementation is brought back into their existing
  contract. If implementation work discovers a real behavior change, stop and return to Architecture
  and the affected design/security gates before editing these docs.

## Threat model and risk-to-test map

| Threat / failure | Required control | Closing evidence |
|---|---|---|
| Huge untrusted host consumes work/memory | 253-byte guard before split/C conversion | 253/254 host tests; existing 1,024/1,025/10M invite tests |
| Noncanonical address has multiple byte forms | parse then require byte-identical canonical output | fixed IPv4/IPv6 tables; 4,096 IPv6 oracle cases |
| Darwin broadens Network.framework on scoped IPv6 forms | apply bounded link-local/multicast scope predicate; preserve oracle `"?"` rejection | fixed accepted ordinary multicast, rejected scoped forms; generated oracle cases |
| Legacy numeric IPv4 falls through as DNS | bounded legacy-candidate rejection before DNS | legacy table; 10,000-case reference property |
| Zone ID/interface data enters deterministic codec | reject `%` before POSIX call | direct constructor and bracketed parser tests |
| Parser behavior drifts from frozen Network.framework semantics | independent test-target Network oracle | fixed corpus plus seeded property cases |
| Core gains network capability | no Network import/dependency; no resolver/socket calls | unmodified security scanner PASS; source grep |
| Duplicate validation paths diverge | bracketed authority delegates to `LANDirectHostV6` once | constructor/parser equivalence tests |
| Invalid input leaks invite secrets | typed errors without raw-value descriptions | existing redaction tests; review diff for interpolation |
| Platform/locale changes output | ASCII arithmetic for IPv4; Darwin binary parse/fixed output on macOS-only package | release build; oracle tests on supported target |

## Verification gates

Builder evidence, in order:

```bash
git diff --check
bash scripts/security-scan.sh
swift test --filter LANDirectInviteV6Tests
swift build -c release
swift test
swift run -c release elysmoke
```

The release build must be warning-free. `elysmoke` must report the repository's reviewed expected
count (currently 457) unless a separately reviewed change deliberately updates it. After independent
Security (code) PASS and independent Test PASS, the complete branch still requires
`bash scripts/pipeline.sh`, deployment, installed-app verification, and the two-Mac LAN proof before
commit/push under the broader RPG/LAN closeout.

## Conditions for Builder

1. Build starts only after an independent Security (plan) PASS on this exact plan hash.
2. Edit only `Sources/ElysiumCore/Net/LANDirectInviteV6.swift` and
   `Tests/ElysiumCoreTests/LANDirectInviteV6Tests.swift` for this remediation.
3. Preserve all public APIs, typed error cases, valid serialized bytes, redaction, and digest-before-
   network ordering.
4. Do not edit `LANTransport.swift`, `Package.swift`, `scripts/security-scan.sh`, or any scanner
   allowlist; do not add a ElysiumCore dependency on Network.framework.
5. Keep all parsing bounded and synchronous with no DNS, interface, filesystem, clock, randomness, or
   socket access.
6. Treat any reference-oracle mismatch, accepted noncanonical form, changed valid invite, warning,
   skipped test, reduced fixed case count, scanner failure, or golden failure as a blocking defect.
7. Security reviews the actual diff after Build. Any material fix returns to the earliest affected
   gate; Test starts only after Security (code) PASS.
