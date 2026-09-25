#!/usr/bin/env python3
"""Hermetic selector/runner checks; never build or run real Swift tests."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("test_impact", Path(__file__).with_name("test-impact.py"))
impact = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(impact)
RENDER = "Sources/Elysium/RayTracingExample.swift"
RENDER_CASES = ("RayTracingCloudOcclusionTests", "RayTracingCanopyLightingTests", "RayTracingDenoiserTests",
    "RayTracingMemoryBudgetTests", "RayTracingMemoryPresentationTests", "RayTracingMeshTests",
    "RayTracingItemSceneTests", "RayTracingDynamicSceneTests", "RayTracedWorldRendererTests",
    "WorldRendererIntegrationTests", "AtmosphereShaderTests", "GraphicsModeTests", "WaterMeshPartitionTests")
DISCOVERY = "".join(f"ElysiumResourcePackTests.{name}/testProbe\n" for name in RENDER_CASES)
DISCOVERY += "ElysiumCoreTests.AutomatedReleaseSourceTests/testPipeline\n"


class ImpactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="elysium-impact-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        environment = mock.patch.dict(os.environ, self.env, clear=True)
        environment.start(); self.addCleanup(environment.stop)
        self.git("init", "-q")
        self.git("config", "user.name", "Impact Fixture")
        self.git("config", "user.email", "impact@example.invalid")
        self.write("README.md", "base\n")
        self.commit("README.md")
        self.base = self.git("rev-parse", "HEAD")
        self.git("update-ref", "refs/remotes/origin/main", self.base)

    def git(self, *args):
        return subprocess.check_output(["/usr/bin/git", "-c", "core.hooksPath=/dev/null",
            "-C", str(self.root), *args], env=self.env, stderr=subprocess.PIPE, text=True).strip()

    def write(self, name, content="source\n"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def commit(self, *paths):
        self.git("add", "--", *paths)
        self.git("commit", "-qm", "fixture")

    def test_reviewed_domains_union_and_nonempty_documentation_baseline(self):
        selection = impact.classify([RENDER, "Sources/Elysium/main.swift", "scripts/pipeline.sh"])
        self.assertEqual(selection["mode"], "scoped")
        self.assertEqual(selection["groups"], ["app-shell", "release-workflow", "renderer"])
        self.assertEqual(set(selection["patterns"]),
                         {p for patterns in impact.GROUPS.values() for p in patterns})
        for paths in (["README.md"], ["docs/rendering.md", "AGENTS.md"]):
            docs = impact.classify(paths)
            self.assertEqual(docs["groups"], ["release-workflow"])
            self.assertTrue(docs["patterns"])
        for path in ["Sources/Elysium/Unknown.swift", "Sources/ElysiumCore/Game/GameCore.swift", "Package.swift"]:
            self.assertEqual(impact.classify([RENDER, path])["mode"], "full", path)

    def test_explicit_full_request_overrides_known_scope(self):
        self.write(RENDER)
        selection = impact.plan(self.root, self.base, full=True)
        self.assertEqual(selection["mode"], "full")
        self.assertEqual(selection["patterns"], [])
        self.assertEqual(selection["reason"], "explicit full-suite request")

    def test_dirty_inventory_keeps_staged_then_reverted_and_untracked_paths(self):
        staged, unstaged = RENDER, "Sources/Elysium/RayTracingOther.swift"
        self.write(staged, "base\n"); self.write(unstaged, "base\n")
        self.commit(staged, unstaged)
        base = self.git("rev-parse", "HEAD")
        self.write(staged, "staged\n"); self.git("add", "--", staged)
        self.write(staged, "base\n")  # Worktree matches HEAD; the index does not.
        self.write(unstaged, "unstaged\n")
        untracked = "docs/untracked space\nname.md"
        self.write(untracked)
        self.assertEqual(impact.changed_paths(self.root, base), sorted([staged, unstaged, untracked]))

    def test_rename_and_delete_include_both_old_and_new_names(self):
        old, new, deleted = RENDER, "Sources/Elysium/RayTracingRenamed.swift", "docs/deleted.md"
        self.write(old); self.write(deleted)
        self.commit(old, deleted)
        base = self.git("rev-parse", "HEAD")
        (self.root / old).rename(self.root / new)
        (self.root / deleted).unlink()
        self.git("add", "--", old, new, deleted)
        self.assertEqual(impact.changed_paths(self.root, base), sorted([old, new, deleted]))

    def test_unavailable_invalid_zero_and_nonancestor_bases_widen(self):
        unrelated = self.git("commit-tree", "HEAD^{tree}", "-m", "independent root")
        for base in ["HEAD", "0" * 40, "f" * 40, unrelated]:
            with self.subTest(base=base):
                self.assertEqual(impact.plan(self.root, base)["mode"], "full")
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        self.assertEqual(impact.plan(self.root)["mode"], "full")

    def test_clean_published_head_selects_parent_but_exact_remote_base_is_preserved(self):
        self.write(RENDER); self.commit(RENDER)
        parent = self.git("rev-parse", "HEAD")
        self.write("docs/second.md"); self.commit("docs/second.md")
        head = self.git("rev-parse", "HEAD")
        self.git("update-ref", "refs/remotes/origin/main", head)
        published = impact.plan(self.root)
        self.assertEqual(published["base"], parent)
        self.assertEqual(published["paths"], ["docs/second.md"])
        outgoing = impact.plan(self.root, self.base)
        self.assertEqual(outgoing["mode"], "scoped")
        self.assertEqual(outgoing["base"], self.base)
        self.assertEqual(outgoing["head"], head)
        self.assertEqual(outgoing["paths"], [RENDER, "docs/second.md"])
        self.assertIn("renderer", outgoing["groups"])

    def test_discovery_rejects_zero_cases_and_missing_required_group(self):
        selection = impact.classify([RENDER])
        impact.validate_discovery(selection, DISCOVERY)
        missing_one = DISCOVERY.replace("ElysiumResourcePackTests.RayTracingMeshTests/testProbe\n", "")
        for output in ["", "Build complete!\n", DISCOVERY.splitlines()[0], missing_one]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                impact.validate_discovery(selection, output)

    def test_runner_propagates_failures_rejects_zero_and_keeps_full_unfiltered(self):
        passed = "Test Case '-[Example testOne]' passed (0.001 seconds).\n"
        scoped = impact.classify([RENDER])
        full = impact.classify(["Package.swift"])
        for selection, status, output, raises in [(scoped, 1, passed, True),
                (scoped, 0, "Executed 0 tests\n", True), (scoped, 0, passed, False),
                (full, 0, passed, False)]:
            process = mock.Mock(stdout=io.StringIO(output))
            process.wait.return_value = status
            with self.subTest(mode=selection["mode"], status=status, output=output), \
                    mock.patch.object(impact.subprocess, "run", return_value=mock.Mock(stdout=DISCOVERY)) as run, \
                    mock.patch.object(impact.subprocess, "Popen", return_value=process) as popen, \
                    contextlib.redirect_stdout(io.StringIO()):
                if raises:
                    with self.assertRaises(RuntimeError): impact.run(selection, self.root)
                else:
                    impact.run(selection, self.root)
                self.assertEqual(run.call_count, 2)
                self.assertTrue(all(call.kwargs["check"] for call in run.call_args_list))
                self.assertEqual("--filter" in popen.call_args.args[0], selection["mode"] == "scoped")
        for successful_calls in [0, 1]:  # Selector self-tests and Swift discovery both fail closed.
            effects = [mock.Mock(stdout=DISCOVERY)] * successful_calls + [subprocess.CalledProcessError(1, "fixture")]
            with mock.patch.object(impact.subprocess, "run", side_effect=effects), \
                    mock.patch.object(impact.subprocess, "Popen") as popen, self.assertRaises(subprocess.CalledProcessError):
                impact.run(scoped, self.root)
            popen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
