#!/usr/bin/env python3
"""Conservative, reviewed code-motion scope for release and push XCTest gates.

Unknown impact widens to the full suite; there is no caller-provided test filter.
The enclosing gates bind source/ref snapshots before and after this command.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
RENDERER = (
    r"ElysiumResourcePackTests\.(?:RayTracing[^/]*|RayTracedWorldRendererTests|"
    r"RenderLocalLightingTests|WorldRendererIntegrationTests|AtmosphereShaderTests|GraphicsModeTests|WaterMeshPartitionTests)/"
)
RENDERER_REQUIRED = (
    "RayTracingCloudOcclusionTests", "RayTracingCanopyLightingTests", "RayTracingDenoiserTests",
    "RayTracingMemoryBudgetTests", "RayTracingMemoryPresentationTests", "RayTracingMeshTests",
    "RayTracingItemSceneTests", "RayTracingDynamicSceneTests", "RayTracedWorldRendererTests",
    "WorldRendererIntegrationTests", "AtmosphereShaderTests", "GraphicsModeTests", "WaterMeshPartitionTests",
    "RenderLocalLightingTests",
)
CORE_MESH_REQUIRED = (
    "MeshGenerationTests", "MesherFixtureTests", "MeshLightingMetadataTests",
    "PistonAndAnvilTextureMappingTests", "DoorTextureMappingTests", "SignTextureMappingTests",
    "FenceGateRenderingTests", "StatefulOpenableTextureMappingTests", "DirectionalFunctionalTextureTests",
)
SETTINGS_REQUIRED = (
    "SettingsTests", "LocalSettingsStoreTests", "GameCoreLocalSettingsIntegrationTests",
    "CreatureRespawnSettingsTests",
)
GROUPS = {
    "renderer": [RENDERER],
    "core-mesh": [r"ElysiumCoreTests\." + name + "/" for name in CORE_MESH_REQUIRED],
    "entity-presentation": [r"ElysiumCoreTests\.EntityFacingSourceTests/"],
    "renderer-source": [r"ElysiumCoreTests\.BrandAttributionSourceTests/"],
    "local-settings": [r"ElysiumCoreTests\." + name + "/" for name in SETTINGS_REQUIRED],
    "app-shell": [r"ElysiumResourcePackTests\.", r"ElysiumDebugProtocolTests\.",
                  r"ElysiumCoreTests\.AutomatedReleaseSourceTests/"],
    "release-workflow": [r"ElysiumCoreTests\.AutomatedReleaseSourceTests/"],
    "prehistoric-audio": [r"ElysiumResourcePackTests\.PrehistoricAudioTests/",
                          r"ElysiumResourcePackTests\.PrehistoricAudioRobustnessTests/"],
    "app-packaging": [r"ElysiumCoreTests\.BrandAttributionSourceTests/",
                      r"ElysiumCoreTests\.TextEntrySourceTests/"],
    "version": [r"ElysiumCoreTests\.VersionTests/", r"ElysiumCoreTests\.LANMultiplayerTests/"],
}
WORKFLOW = {
    "scripts/test-impact.py", "scripts/test-test-impact.py", "scripts/pipeline.sh",
    "scripts/security-scan.sh", "scripts/verify-elysium-storage-release-surface.sh",
    ".githooks/pre-push", ".githooks/pre-commit", "Tests/ElysiumCoreTests/AutomatedReleaseSourceTests.swift",
}
RENDER_FILES = {"RayTracedWorldRenderer.swift", "AtmosphereShaders.swift",
                "GraphicsMode.swift", "WaterMeshPartition.swift"}
RENDER_TESTS = {"RayTracedWorldRendererTests.swift", "WorldRendererIntegrationTests.swift",
                "RenderLocalLightingTests.swift", "AtmosphereShaderTests.swift", "GraphicsModeTests.swift", "WaterMeshPartitionTests.swift"}
# Explicit dependency closures: Mesher adds render-only metadata, while the shared raster
# shader/pass graph also feeds entities, sprites and the title. Do not generalize this to
# Core's simulation light engine, block registry, persistence, or arbitrary Render files.
REVIEWED_RENDER_PATHS = {
    "Sources/ElysiumCore/Render/Mesher.swift": {"renderer", "core-mesh"},
    "Sources/Elysium/RenderLocalLighting.swift": {"renderer", "core-mesh"},
    "Sources/Elysium/WorldRenderer.swift": {"renderer", "core-mesh", "entity-presentation", "renderer-source"},
    "Sources/Elysium/Shaders.swift": {"renderer", "core-mesh", "entity-presentation", "renderer-source"},
    "Sources/Elysium/EntityRendererM.swift": {"renderer", "entity-presentation"},
    **{"Tests/ElysiumCoreTests/" + name + ".swift": {"renderer", "core-mesh"}
       for name in CORE_MESH_REQUIRED},
    "Tests/ElysiumCoreTests/EntityFacingSourceTests.swift": {"renderer", "entity-presentation"},
    "Tests/ElysiumCoreTests/BrandAttributionSourceTests.swift": {"renderer-source"},
}
# Graphics-default compatibility spans tolerant decoding, durable publication and the
# renderer's supported-mode fallback. Neighboring Game/storage sources remain unmapped.
REVIEWED_SETTINGS_PATHS = {
    "Sources/ElysiumCore/Game/Settings.swift",
    "Sources/ElysiumCore/Game/LocalSettingsStore.swift",
    *{"Tests/ElysiumCoreTests/" + name + ".swift" for name in SETTINGS_REQUIRED},
}
SHELL_FILES = {"Sources/Elysium/main.swift", "Sources/Elysium/HudM.swift",
               "Sources/Elysium/DebugControlRuntime.swift"}
DOCS = {"README.md", "AGENTS.md", "CONTRIBUTING.md", "ARCHITECTURE.md", "SECURITY.md", "PLAYER_GUIDE.md"}
# Bundled dinosaur recordings: the sample bank, its assets, validator and authoring tools are
# exercised only by the prehistoric audio suites (cue emission itself lives in Core and is
# not mapped here).
AUDIO_PATHS = {"Sources/Elysium/Audio.swift", "scripts/verify-dinosaur-sounds.py",
               "scripts/build-dinosaur-sounds.py",
               "Tests/ElysiumResourcePackTests/PrehistoricAudioTests.swift",
               "Tests/ElysiumResourcePackTests/PrehistoricAudioRobustnessTests.swift"}
AUDIO_PREFIXES = ("packaging/DinosaurSounds/", "Assets/dinosaur-audio/")
# Packaging scripts are read by the release and brand/text-entry source contracts.
PACKAGING_PATHS = {"scripts/package-app.sh", "scripts/package-debug-app.sh"}
# Release-pin manifests are verified by the gate scripts themselves, not by XCTest.
PIN_MANIFESTS = {"scripts/elysium-core-storage-capability-v1.json", "scripts/elysium-storage-api-v1.json"}
VERSION_PLISTS = {"packaging/Info.plist", "packaging/DebugInfo.plist"}
VERSION_SOURCE = "Sources/ElysiumCore/Game/Saves.swift"
VERSION_DECL = re.compile(rb'^public let ELYSIUM_VERSION = "[0-9]+\.[0-9]+\.[0-9]+"$')


def classify(paths, version_only=False):
    """`version_only` is true only when the Saves.swift diff touches nothing but the
    ELYSIUM_VERSION literal; any other Saves.swift change stays unmapped (full suite)."""
    groups, unknown = set(), []
    for path in sorted(set(paths)):
        parent, name = str(Path(path).parent), Path(path).name
        if path in DOCS or (path.startswith("docs/") and path.endswith(".md")):
            continue
        if path in WORKFLOW or path in PIN_MANIFESTS:
            groups.add("release-workflow")
        elif path in AUDIO_PATHS or path.startswith(AUDIO_PREFIXES):
            groups.add("prehistoric-audio")
        elif path in PACKAGING_PATHS:
            groups.update({"release-workflow", "app-packaging"})
        elif path in VERSION_PLISTS or (path == VERSION_SOURCE and version_only):
            groups.add("version")
        elif path in SHELL_FILES:
            groups.add("app-shell")
        elif path in REVIEWED_RENDER_PATHS:
            groups.update(REVIEWED_RENDER_PATHS[path])
        elif path in REVIEWED_SETTINGS_PATHS:
            groups.update({"local-settings", "renderer"})
        elif parent == "Sources/Elysium" and (name in RENDER_FILES or
                (name.startswith("RayTracing") and name.endswith(".swift"))):
            groups.add("renderer")
        elif parent == "Tests/ElysiumResourcePackTests" and (name in RENDER_TESTS or
                (name.startswith("RayTracing") and name.endswith("Tests.swift"))):
            groups.add("renderer")
        else:
            unknown.append(path)
    if unknown:
        return {"mode": "full", "groups": [], "patterns": [], "reason": "unmapped impact", "unknown": unknown}
    if not paths:
        return {"mode": "full", "groups": [], "patterns": [], "reason": "no attributable change"}
    groups.add("release-workflow")  # nonempty contract baseline, including docs-only work
    patterns = sorted({pattern for group in groups for pattern in GROUPS[group]})
    return {"mode": "scoped", "groups": sorted(groups), "patterns": patterns, "reason": "reviewed impact map"}


def git(root, *args):
    return subprocess.check_output(["/usr/bin/git", "-C", str(root), *args], stderr=subprocess.PIPE)


def version_literal_only(root, base):
    """True only when Saves.swift differs from `base` in exactly the one top-level
    ELYSIUM_VERSION literal: same line, nothing else, no carriage returns."""
    old = git(root, "show", "--no-textconv", f"{base}:{VERSION_SOURCE}")
    new = (Path(root) / VERSION_SOURCE).read_bytes()
    if old == new or b"\r" in old or b"\r" in new:
        return False
    old_lines, new_lines = old.split(b"\n"), new.split(b"\n")
    old_at = [i for i, line in enumerate(old_lines) if VERSION_DECL.match(line)]
    new_at = [i for i, line in enumerate(new_lines) if VERSION_DECL.match(line)]
    if len(old_at) != 1 or old_at != new_at:
        return False
    old_lines[old_at[0]] = new_lines[new_at[0]]
    return old_lines == new_lines


def changed_paths(root, base):
    # --no-renames reports both the deleted source and added destination; -z preserves names.
    tracked = git(root, "diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", base, "--")
    staged = git(root, "diff", "--cached", "--no-ext-diff", "--no-renames", "--name-only", "-z", base, "--")
    untracked = git(root, "ls-files", "--others", "--exclude-standard", "-z")
    return sorted({p.decode("utf-8", "strict") for p in (tracked + staged + untracked).split(b"\0") if p})


def plan(root, requested_base=None, full=False):
    try:
        head = git(root, "rev-parse", "--verify", "HEAD^{commit}").decode().strip()
        if requested_base is not None:
            if not re.fullmatch(r"[0-9a-f]{40}", requested_base):
                raise ValueError("invalid push base")
            base = git(root, "rev-parse", "--verify", requested_base + "^{commit}").decode().strip()
            git(root, "merge-base", "--is-ancestor", base, head)
        else:
            base = git(root, "merge-base", head, "refs/remotes/origin/main").decode().strip()
            if base == head and not changed_paths(root, base):
                base = git(root, "rev-parse", "--verify", "HEAD^1^{commit}").decode().strip()
        paths = changed_paths(root, base)
        result = classify(paths, version_only=VERSION_SOURCE in paths and
                          version_literal_only(root, base))
        result.update(base=base, head=head, paths=paths)
    except (subprocess.CalledProcessError, UnicodeError, ValueError):
        result = {"mode": "full", "groups": [], "patterns": [], "reason": "base or change inventory unavailable"}
    if full:
        result.update(mode="full", groups=[], patterns=[], reason="explicit full-suite request")
    return result


def validate_discovery(selection, output):
    tests = [line.strip() for line in output.splitlines() if re.match(r"^\w+\.\w+/\w+", line.strip())]
    if not tests:
        raise ValueError("test discovery returned no XCTest cases")
    required = list(selection["patterns"])
    if "renderer" in selection["groups"]:
        required += [r"ElysiumResourcePackTests\." + name + "/" for name in RENDERER_REQUIRED]
    for pattern in required:
        if not any(re.search(pattern, test) for test in tests):
            raise ValueError("required test group has no discovered cases: " + pattern)


def run(selection, root=ROOT):
    # Verify the selector on every gate, including full/unknown and documentation-only scopes.
    subprocess.run([sys.executable, str(root / "scripts/test-test-impact.py")], cwd=root, check=True)
    discovered = subprocess.run(["swift", "test", "list"], cwd=root, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    validate_discovery(selection, discovered.stdout)
    command = ["swift", "test"]
    if selection["mode"] == "scoped":
        command += ["--filter", "|".join("(?:" + p + ")" for p in selection["patterns"])]
    process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    count = 0
    assert process.stdout is not None
    for line in process.stdout:
        print(line, end="", flush=True)
        if re.search(r"Test Case .* passed \(", line):
            count += 1
    status = process.wait()
    if status != 0:
        raise RuntimeError("selected XCTest command failed: " + str(status))
    if count == 0:
        raise RuntimeError("selected XCTest command executed zero passing cases")
    print(f"IMPACT TESTS PASS tests={count} mode={selection['mode']}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="exact remote commit supplied by pre-push")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--plan", action="store_true")
    action.add_argument("--run", action="store_true")
    args = parser.parse_args()
    selection = plan(ROOT, args.base, os.environ.get("ELYSIUM_FULL_TESTS") == "1")
    print(json.dumps(selection, sort_keys=True), flush=True)
    if args.run:
        run(selection)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print("impact tests failed: " + str(error), file=sys.stderr)
        sys.exit(1)
