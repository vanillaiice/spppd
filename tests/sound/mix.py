#!/usr/bin/env python3
"""Works out what the game's mix adds up to, from the logs tests/sound/dump.lua writes.

    python tests/sound/mix.py dist/sfx/old
    python tests/sound/mix.py dist/sfx/new --compare dist/sfx/old

The volumes and pitches come from the real audio.update, driven through the scripted
moments in tests/sound/scenes.lua. The samples come from the dump. This adds them up
the simple way, at the code's own levels and before the VOLUME setting (0.8 by
default, -1.9 dB). It isn't OpenAL and isn't a recording of the game, so read it for
levels and balance. It can't say how anything sounds.
"""
import argparse
import re
from collections import defaultdict
from pathlib import Path

import numpy as np
import pyloudnorm
import soundfile
from scipy import signal

RATE = 44100
FRAME = 1 / 60
SAMPLES = int(RATE * FRAME)
PHONE_CORNER = 300.0
LAYERS = [("engine", r"^engine"), ("turbo", r"^turbo"), ("blower", r"^blower"), ("motor", r"^motor"),
          ("road", r"^road"), ("wind", r"^wind"), ("tyres", r"^(scrub|squeal)"), ("loose", r"^loose"),
          ("boost", r"^(boostgas|nitro)"), ("grind", r"^grind"), ("shots", r"")]


def layer_of(name):
    for layer, pattern in LAYERS:
        if re.search(pattern, name):
            return layer
    return "shots"


class Bank:
    def __init__(self, folder):
        self.folder = folder
        self.samples = {}
        self.looped = {}
        for line in (folder / "_render.tsv").read_text().splitlines()[1:]:
            name, kind, _, _ = line.split("\t")
            self.looped[name] = kind == "loop"

    def get(self, name):
        if name not in self.samples:
            x, _ = soundfile.read(self.folder / f"{name}.wav")
            self.samples[name] = x
        return self.samples[name]


def read_trace(path):
    frames = defaultdict(list)
    for line in path.read_text().splitlines()[1:]:
        frame, name, volume, pitch, at, *_ = line.split("\t")
        frames[name].append((int(frame), float(volume), float(pitch), float(at)))
    return frames


def render_source(x, looped, rows, total):
    """One source through its frames: gain ramps across a frame, as OpenAL's does."""
    out = np.zeros(total)
    length = len(x)
    held = {frame: (volume, pitch, at) for frame, volume, pitch, at in rows}
    for frame, volume, pitch, at in rows:
        start = frame * SAMPLES
        if start + SAMPLES > total:
            break
        previous = held.get(frame - 1, (0.0, pitch, at))[0]
        read = at * RATE + np.arange(SAMPLES) * pitch
        if looped:
            read = np.mod(read, length)
        else:
            keep = read < length - 1
            read = np.where(keep, read, 0)
        whole = read.astype(int)
        part = read - whole
        following = np.mod(whole + 1, length)
        wave = x[whole] * (1 - part) + x[following] * part
        if not looped:
            wave = wave * keep
        out[start:start + SAMPLES] += wave * np.linspace(previous, volume, SAMPLES, endpoint=False)
    return out


def scene_mix(bank, path, seconds):
    frames = read_trace(path)
    total = int(seconds / FRAME) * SAMPLES
    layers = defaultdict(lambda: np.zeros(total))
    for name, rows in frames.items():
        layers[layer_of(name)] += render_source(bank.get(name), bank.looped.get(name, False), rows, total)
    mix = np.zeros(total)
    for wave in layers.values():
        mix += wave
    return mix, layers


def lufs(x):
    if np.max(np.abs(x)) < 1e-6 or len(x) < RATE * 0.5:
        return float("-inf")
    return float(pyloudnorm.Meter(RATE).integrated_loudness(x))


def phone(x):
    return signal.sosfilt(signal.butter(4, PHONE_CORNER, "highpass", fs=RATE, output="sos"), x)


def momentary(x):
    """Loudness over 400 ms windows every 100 ms, as dB: K-weighted."""
    meter = pyloudnorm.Meter(RATE)
    weighted = x
    for stage in meter._filters.values():
        weighted = stage.apply_filter(weighted)
    size, hop = int(0.4 * RATE), int(0.1 * RATE)
    power = np.convolve(weighted ** 2, np.ones(size) / size, mode="valid")[::hop]
    return -0.691 + 10 * np.log10(power + 1e-12)


def fmt(value):
    return "  off" if value == float("-inf") else f"{value:5.1f}"


def scenes_in(folder):
    rows = []
    for line in (folder / "_trace.tsv").read_text().splitlines()[1:]:
        scene, car, seconds, events = (line.split("\t") + [""])[:4]
        rows.append((scene, car, float(seconds), events))
    return rows


def analyse(folder, only=None):
    bank = Bank(folder)
    table = {}
    for scene, car, seconds, events in scenes_in(folder):
        if only and car not in only:
            continue
        mix, layers = scene_mix(bank, folder / "_trace" / f"{scene}-{car}.tsv", seconds)
        settle = int(0.3 * RATE)
        body = mix[settle:]
        table[(scene, car)] = {
            "lufs": lufs(body), "phone": lufs(phone(body)), "peak": float(np.max(np.abs(body))),
            "over": int(np.sum(np.abs(body) > 1.0)),
            "layers": {k: lufs(v[settle:]) for k, v in layers.items()},
            "phone_layers": {k: lufs(phone(v[settle:])) for k, v in layers.items()},
            "mix": mix, "events": events,
        }
    return table


def by_scene(table):
    print("\nEVERY CAR, LUFS OF THE WHOLE MIX (full range / through the assumed phone corner)")
    scenes = sorted({scene for scene, _ in table})
    cars = sorted({car for _, car in table})
    print(f'{"car":16}' + "".join(f"{s[:11]:>14}" for s in scenes))
    for car in cars:
        cells = "".join(f'{table[(s, car)]["lufs"]:7.1f}/{table[(s, car)]["phone"]:6.1f}' for s in scenes)
        print(f"{car:16}{cells}")
    print(f'{"spread":16}' + "".join(
        f'{max(table[(s, c)]["lufs"] for c in cars) - min(table[(s, c)]["lufs"] for c in cars):7.1f}/'
        f'{max(table[(s, c)]["phone"] for c in cars) - min(table[(s, c)]["phone"] for c in cars):6.1f}'
        for s in scenes))


def headroom(table):
    print("\nHEADROOM: loudest sample of each scene, worst car (1.0 is full scale)")
    for scene in sorted({s for s, _ in table}):
        rows = [(v["peak"], car, v["over"]) for (s, car), v in table.items() if s == scene]
        peak, car, over = max(rows)
        print(f"{scene:10} {peak:5.2f}  {car:16} {over} samples over")


def layers_of(table, car):
    print(f"\nLAYERS AS PLAYED on {car}: LUFS full range, then through the phone corner")
    scenes = sorted({s for s, c in table if c == car})
    names = [name for name, _ in LAYERS]
    print(f'{"scene":10}' + "".join(f"{n:>13}" for n in names))
    for scene in scenes:
        row = table[(scene, car)]
        print(f"{scene:10}" + "".join(
            f'{fmt(row["layers"].get(n, float("-inf")))}/{fmt(row["phone_layers"].get(n, float("-inf")))} ' for n in names))


def sweep(table, cars):
    print("\nSWEEP: mix loudness against revs, full throttle, 0 to 100% of the rev range")
    points = np.linspace(0, 100, 17)
    print(f'{"car":16}' + "".join(f"{int(p):>6}" for p in points) + "  dip")
    for car in cars:
        curve = momentary(table[("sweep", car)]["mix"])
        picks = np.interp(points / 100, np.linspace(0, 1, len(curve)), curve)
        worst = max(0.0, float(np.max(np.maximum.accumulate(curve[3:]) - curve[3:])))
        print(f"{car:16}" + "".join(f"{v:6.1f}" for v in picks) + f"  {worst:4.1f}")


def crashes(table, car):
    row = table[("crashes", car)]
    curve = momentary(row["mix"])
    print(f"\nCRASHES over a steady drive on {car}: how far each lifts the loudness")
    bed = float(np.median(curve))
    print(f"steady drive reads {bed:.1f}")
    for event in row["events"].split(","):
        if not event:
            continue
        at, label = event.split("=")
        start = int(float(at) * 10)
        print(f"  {label:10} +{float(np.max(curve[start:start + 8])) - bed:4.1f} dB")


def shifts(table, car):
    row = table[("shifts", car)]
    print(f"\nSHIFT on {car}: level of the 100 ms after each one against the 100 ms before, whole mix")
    for version, x in (("full", row["mix"]), ("phone", phone(row["mix"]))):
        size = int(0.1 * RATE)
        change = []
        for start in (0.5, 1.5, 2.5):
            at = int(start * RATE)
            change.append(20 * np.log10(np.sqrt(np.mean(x[at:at + size] ** 2)) / np.sqrt(np.mean(x[at - size:at] ** 2))))
        print(f"  {version:6}" + "".join(f"{value:+6.1f}" for value in change) + " dB")


def compare(new, old):
    print("\nBEFORE > AFTER, whole mix, LUFS through the phone corner, median of all cars")
    scenes = sorted({s for s, _ in new})
    for scene in scenes:
        before = np.median([v["phone"] for (s, _), v in old.items() if s == scene])
        after = np.median([v["phone"] for (s, _), v in new.items() if s == scene])
        full_before = np.median([v["lufs"] for (s, _), v in old.items() if s == scene])
        full_after = np.median([v["lufs"] for (s, _), v in new.items() if s == scene])
        spread_before = np.ptp([v["phone"] for (s, _), v in old.items() if s == scene])
        spread_after = np.ptp([v["phone"] for (s, _), v in new.items() if s == scene])
        print(f"{scene:10} phone {before:6.1f} > {after:6.1f}   full {full_before:6.1f} > {full_after:6.1f}"
              f"   spread between cars {spread_before:4.1f} > {spread_after:4.1f}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--compare", type=Path)
    parser.add_argument("--car", default="muscle_monster", help="the car to break into layers")
    parser.add_argument("--cars", help="only these cars, comma separated")
    args = parser.parse_args()

    only = args.cars.split(",") if args.cars else None
    table = analyse(args.folder, only)
    cars = sorted({car for _, car in table})
    by_scene(table)
    headroom(table)
    layers_of(table, args.car)
    sweep(table, cars)
    crashes(table, args.car)
    shifts(table, args.car)
    if args.compare:
        compare(table, analyse(args.compare, only))


if __name__ == "__main__":
    main()
