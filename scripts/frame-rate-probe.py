#!/usr/bin/env python3
"""Measure Elysium's frame rate in a saved world through the debug-control app.

    bash scripts/package-debug-app.sh
    python3 scripts/frame-rate-probe.py --list
    python3 scripts/frame-rate-probe.py --world <id> --mode still --seconds 30 --runs 3
    python3 scripts/frame-rate-probe.py --world <id> --mode fly

It loads a world of the isolated debug profile, freezes the time of day and the weather so runs
compare, and reads the `frameTiming` section of the `renderer` snapshot (docs/DEBUG_CONTROL.md):
average fps, the 1% low, the share of frames over 17.5 ms, and the main-thread and GPU cost of a
frame. It prints every run and the median of the runs nothing disturbed.

What a run needs, and what makes one unusable:
- The debug app draws only while it is the active app, so the probe brings its window to the
  front for the whole run. Do not use the Mac meanwhile. A run during which the app lost focus,
  a screen opened or the frame stream had a gap is reported as disturbed and left out.
- Other work on the machine shows up in the numbers. Anything else on the GPU (a local model, GPU
  tests) inflates GPU time several times; builds and tests raise main-thread times. The probe
  prints the load beside each series. Compare builds by the `p10` figures, which are close to the
  undisturbed cost.
- It never runs while scripts/pipeline.sh is packaging or driving its AppKit stage: that stage
  needs the screen to itself.

The world is changed in the debug profile only: daylight and weather cycles are switched off, the
time and weather set, and for `--mode fly` the game mode becomes creative. To measure a player's
own world, give a scratch copy of the debug build its own profile name and copy the save database
into that profile; never point a probe at the production profile. The name is in three places
("Elysium Debug" in Sources/ElysiumCore/Game/Settings.swift, Sources/Elysium/DebugControlServer.swift
and Sources/elydebug/CLI.swift), the bundle id in packaging/DebugInfo.plist and
scripts/package-debug-app.sh. docs/release-1.5.2-build.md records a run made that way.
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROCESS = "ElysiumDebug"
GPU_USERS = ("ollama", "mlx", "llama", "blender")


class Probe:
    def __init__(self, app):
        self.app = app
        self.helper = os.path.join(app, "Contents", "Helpers", "elydebug")
        if not os.access(self.helper, os.X_OK):
            sys.exit(f"no debug app at {app}: run bash scripts/package-debug-app.sh first")

    def request(self, operation, arguments=None, timeout=120):
        command = [self.helper, "--timeout", str(timeout), "request", operation, json.dumps(arguments or {})]
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout + 30)
        text = done.stdout.strip() or done.stderr.strip()
        try:
            reply = json.loads(text)
        except ValueError:
            raise RuntimeError(f"{operation}: {text[:300]}")
        if reply.get("ok") is False or "result" not in reply:
            raise RuntimeError(f"{operation}: {text[:300]}")
        return reply["result"]

    def snapshot(self, *scopes):
        return self.request("state.snapshot", {"scopes": list(scopes)})["snapshot"]["sections"]

    def action(self, **action):
        return self.request("interaction.action", {"action": action})

    def running(self):
        return subprocess.run(["pgrep", "-x", PROCESS], capture_output=True).returncode == 0

    def launch(self):
        if not self.running():
            subprocess.run(["open", "-na", self.app, "--args", "--debug-control"], check=True)
        deadline = time.time() + 90
        while time.time() < deadline:
            try:
                return self.request("session.status", timeout=5)
            except (RuntimeError, subprocess.TimeoutExpired):
                time.sleep(1.5)
        sys.exit("the debug-control service did not answer within 90 seconds")

    def activate(self):
        subprocess.run(["open", "-a", self.app], check=False)
        time.sleep(1.0)

    def hold_key(self, key, seconds):
        """Held input lasts only as long as its control connection, so hold it over one."""
        stream = subprocess.Popen([self.helper, "stream"], stdin=subprocess.PIPE,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
        stream.stdin.write(json.dumps({"operation": "input.key_down",
                                       "arguments": {"key": key, "command": False}}) + "\n")
        stream.stdin.flush()
        time.sleep(seconds)
        stream.stdin.write(json.dumps({"operation": "input.key_up", "arguments": {"key": key}}) + "\n")
        stream.stdin.close()
        stream.wait(timeout=20)

    def wait_until_streamed(self, timeout=240, quiet=6):
        """Until ray tracing presents and no section is pending for `quiet` seconds in a row."""
        deadline, calm, sections = time.time() + timeout, 0, None
        while time.time() < deadline:
            renderer = self.snapshot("renderer")["renderer"]
            ray = renderer["rayTracing"]
            settled = (not ray["available"] or (ray["ready"] and ray["pendingSections"] == 0
                                                and ray["deferredSections"] == 0))
            calm = calm + 1 if settled and sections == renderer["totalSections"] else 0
            sections = renderer["totalSections"]
            if calm >= quiet:
                return renderer
            time.sleep(1.0)
        print("  note: the scene did not settle; measuring anyway")
        return self.snapshot("renderer")["renderer"]


def frontmost():
    script = 'tell application "System Events" to get name of first process whose frontmost is true'
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.strip()


def machine_load():
    load = subprocess.run(["uptime"], capture_output=True, text=True).stdout.split("load averages:")[-1].strip()
    rows = subprocess.run(["ps", "-Ao", "pcpu=,comm="], capture_output=True, text=True).stdout.splitlines()
    busy, gpu = [], []
    for row in rows:
        parts = row.split(None, 1)
        if len(parts) != 2:
            continue
        percent, name = float(parts[0]), os.path.basename(parts[1])
        if name == PROCESS:
            continue
        if percent > 4 and any(user in name.lower() for user in GPU_USERS):
            gpu.append(f"{name} {percent:.0f}%")
        elif percent > 50:
            busy.append(f"{name} {percent:.0f}%")
    return load, busy, gpu


def release_pipeline_needs_the_screen():
    """True while a scripts/pipeline.sh run is past its build and test stages."""
    rows = subprocess.run(["ps", "-Ao", "pid=,ppid=,command="], capture_output=True, text=True).stdout.splitlines()
    processes = {}
    for row in rows:
        parts = row.split(None, 2)
        if len(parts) == 3:
            processes[int(parts[0])] = (int(parts[1]), parts[2])
    roots = {pid for pid, (_, command) in processes.items() if "scripts/pipeline.sh" in command}
    late = ("elysmoke", "package-app", "appkit-text-entry", "codesign", "ditto")
    for pid, (parent, command) in processes.items():
        ancestor, depth = parent, 0
        while ancestor in processes and ancestor not in roots and depth < 64:
            ancestor, depth = processes[ancestor][0], depth + 1
        if ancestor in roots and any(marker in command for marker in late):
            return True
    return False


def disturbed(timing, front, screen, seconds, gpu_users):
    problems = []
    if front != PROCESS:
        problems.append(f"the app was not in front ({front})")
    if isinstance(screen, dict) and screen.get("open"):
        problems.append("a screen was open (paused)")
    if timing["frames"] < seconds * 15:
        problems.append(f"only {timing['frames']} frames")
    if timing["intervalMilliseconds"]["maximum"] > 1000:
        problems.append("a gap of over a second")
    if gpu_users:
        problems.append("the GPU was shared with " + ", ".join(gpu_users))
    return "; ".join(problems)


def one_run(probe, args, start):
    if release_pipeline_needs_the_screen():
        sys.exit("a release pipeline needs the screen now; run the probe again when it has finished")
    probe.activate()
    if args.mode in ("walk", "fly"):
        lift = 25 if args.mode == "fly" else 0
        probe.request("player.teleport", {"x": start["x"], "y": start["y"] + lift, "z": start["z"]})
        if args.mode == "fly":
            probe.request("player.flying", {"enabled": True})
        probe.request("player.look", {"yaw": start["yaw"], "pitch": 0.2 if args.mode == "fly" else 0.0})
        probe.wait_until_streamed(timeout=60, quiet=3)
        probe.hold_key("KeyW", args.seconds + 1.0)
    else:
        time.sleep(args.seconds + 1.0)
    front = frontmost()
    _, _, gpu_users = machine_load()
    sections = probe.snapshot("renderer", "screen")
    renderer = sections["renderer"]
    timing = renderer["frameTiming"]["trailing30Seconds" if args.seconds >= 30 else "trailing10Seconds"]
    return dict(timing=timing, stages=renderer["rayTracing"].get("gpuStageMedianMilliseconds", {}),
                problem=disturbed(timing, front, sections.get("screen"), args.seconds, gpu_users))


def describe(timing):
    def pair(name):
        return f"{timing[name]['median']:.2f}/{timing[name]['p95']:.2f}"
    return (f"avg {timing['averageFPS']:.1f} fps, 1% low {timing['onePercentLowFPS']:.1f}, "
            f"over 17.5 ms {100 * timing['shareOver60FPSFrame']:.2f}% | main thread {pair('cpuMilliseconds')} ms "
            f"(sim {pair('simulationMilliseconds')}, world {pair('worldMilliseconds')}, "
            f"UI {pair('interfaceMilliseconds')}), wait {pair('drawableWaitMilliseconds')} | "
            f"GPU {pair('gpuMilliseconds')} ms, p10 {timing['gpuMilliseconds']['p10']:.2f}")


def main():
    parser = argparse.ArgumentParser(description="Measure frame rate through the debug-control app.")
    parser.add_argument("--app", default=os.path.join(ROOT, "dist", "Elysium Debug.app"))
    parser.add_argument("--list", action="store_true", help="list the debug profile's worlds and exit")
    parser.add_argument("--world", help="world id from --list")
    parser.add_argument("--mode", choices=("still", "walk", "fly"), default="still")
    parser.add_argument("--seconds", type=float, default=30, help="10 to 30; the snapshot keeps 30 seconds")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--time", type=int, default=6000, help="day time in ticks, frozen for the runs")
    parser.add_argument("--weather", choices=("clear", "rain", "thunder"), default="clear")
    parser.add_argument("--position", type=float, nargs=3, metavar=("X", "Y", "Z"))
    parser.add_argument("--look", type=float, nargs=2, metavar=("YAW", "PITCH"), help="radians")
    parser.add_argument("--quit", action="store_true", help="quit the debug app afterwards")
    args = parser.parse_args()
    if not 10 <= args.seconds <= 30 or args.runs < 1:
        parser.error("--seconds must be 10...30 and --runs at least 1")

    probe = Probe(args.app)
    if release_pipeline_needs_the_screen():
        sys.exit("a release pipeline needs the screen now; run the probe again when it has finished")
    probe.launch()
    if args.list or not args.world:
        for world in probe.request("world.list", {"offset": 0, "limit": 128})["worlds"]:
            print(world.get("id"), "|", world.get("name"), "|", world.get("worldPreset", ""))
        return

    probe.activate()
    try:
        probe.request("simulation.resume")
    except RuntimeError:
        pass
    probe.request("world.load", {"id": args.world}, timeout=180)
    time.sleep(2)
    probe.action(action="set_gamerule", rule="doDaylightCycle", enabled=False)
    probe.action(action="set_gamerule", rule="doWeatherCycle", enabled=False)
    probe.action(action="set_time", ticks=args.time)
    probe.action(action="set_weather", weather=args.weather)
    if args.mode == "fly":
        probe.action(action="set_gamemode", mode="creative")
    player = probe.snapshot("player")["player"]
    start = {key: player[key] for key in ("x", "y", "z", "yaw", "pitch")}
    if args.position:
        start["x"], start["y"], start["z"] = args.position
    if args.look:
        start["yaw"], start["pitch"] = args.look
    probe.request("player.teleport", {"x": start["x"], "y": start["y"], "z": start["z"]})
    probe.request("player.look", {"yaw": start["yaw"], "pitch": start["pitch"]})
    probe.activate()
    renderer = probe.wait_until_streamed()
    ray = renderer["rayTracing"]
    load, busy, gpu_users = machine_load()
    print(f"world {args.world} at ({start['x']:.1f}, {start['y']:.1f}, {start['z']:.1f}), mode {args.mode}, "
          f"{args.seconds:.0f} s x {args.runs}")
    print(f"drawable {renderer['drawableWidth']}x{renderer['drawableHeight']}, "
          f"ray tracing {ray['status']} {ray['outputWidth']}x{ray['outputHeight']}, "
          f"{renderer['totalSections']} sections, {ray['triangles']} triangles")
    print(f"machine load {load}; busy: {', '.join(busy) or 'nothing over 50%'}; "
          f"GPU shared with: {', '.join(gpu_users) or 'nothing seen'}")

    runs = []
    for index in range(args.runs):
        run = one_run(probe, args, start)
        runs.append(run)
        print(f"  run {index + 1}: {describe(run['timing'])}" + (f"  DISTURBED: {run['problem']}" if run["problem"] else ""))
    clean = [run for run in runs if not run["problem"]]
    if not clean:
        print("every run was disturbed; no median")
    else:
        def median(read):
            return statistics.median(read(run["timing"]) for run in clean)
        print(f"median of {len(clean)} undisturbed run(s): avg {median(lambda t: t['averageFPS']):.1f} fps, "
              f"1% low {median(lambda t: t['onePercentLowFPS']):.1f}, "
              f"main thread {median(lambda t: t['cpuMilliseconds']['median']):.2f} ms, "
              f"GPU {median(lambda t: t['gpuMilliseconds']['median']):.2f} ms "
              f"(best p10 {min(run['timing']['gpuMilliseconds']['p10'] for run in clean):.2f})")
        stages = clean[-1]["stages"]
        if stages:
            print("GPU stage medians (ms): " + ", ".join(f"{name} {value:.2f}" for name, value in sorted(stages.items())))
    if args.quit:
        probe.request("app.quit")


if __name__ == "__main__":
    main()
