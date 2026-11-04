#!/usr/bin/env python3
"""Measures the sounds tests/sound/dump.lua wrote out.

    pip install -r tests/sound/requirements.txt
    love . --sounds new dist/sfx/new
    python tests/sound/analyze.py dist/sfx/new --json dist/sfx/new.json
    python tests/sound/analyze.py dist/sfx/new --compare dist/sfx/old.json

Everything here is a measurement of a file. It says nothing about how a sound
feels, and only tests/sound/mix.py accounts for the volume the game plays it at.

Loudness is ITU-R BS.1770 (pyloudnorm). That standard's 400 ms blocks need a loop
tiled and a one-shot padded with silence first, so a short one-shot reads lower
than a held sound of the same level: it's the loudness of the event, not the
level inside it. Compare shots with shots and loops with loops.

"phone" is the same loudness after a 300 Hz high-pass, standing in for a small
speaker. The corner is an assumption, not a measurement of any handset.
"""
import argparse
import json
import math
from pathlib import Path

import numpy as np
import pyloudnorm
import soundfile
from scipy import signal

SILENCE_DB = -60.0     # below this counts as silence
CLIP_LEVEL = 0.999     # full scale, near enough, for a 16-bit file
PHONE_CORNER = 300.0   # Hz, the assumed bottom of a phone speaker
TILE_SECONDS = 4.0     # a loop is repeated to at least this before measuring
PAD_SECONDS = 0.5      # silence put either side of a one-shot
BANDS = [("sub", 0, 200), ("low", 200, 1000), ("mid", 1000, 4000), ("high", 4000, 22050)]


def db(value):
    return 20.0 * math.log10(max(float(value), 1e-12))


def rms(x):
    return float(np.sqrt(np.mean(np.square(x)))) if len(x) else 0.0


def prepared(x, rate, looped):
    """Long enough for BS.1770's blocks, and with no edge if it loops."""
    if looped:
        return np.tile(x, int(np.ceil(TILE_SECONDS * rate / len(x))))
    pad = np.zeros(int(PAD_SECONDS * rate))
    return np.concatenate([pad, x, pad])


def loudness(x, rate, looped):
    return float(pyloudnorm.Meter(rate).integrated_loudness(prepared(x, rate, looped)))


def phone_loudness(x, rate, looped):
    highpass = signal.butter(4, PHONE_CORNER, "highpass", fs=rate, output="sos")
    return float(pyloudnorm.Meter(rate).integrated_loudness(signal.sosfilt(highpass, prepared(x, rate, looped))))


def spectrum(x, rate):
    size = min(8192, len(x))
    freqs, power = signal.welch(x, rate, window="hann", nperseg=size)
    total = float(power.sum()) or 1e-20
    voiced = (freqs >= 40) & (freqs <= 16000)
    flatness = np.exp(np.mean(np.log(power[voiced] + 1e-20))) / (np.mean(power[voiced]) + 1e-20)
    bands = {name: float(power[(freqs >= lo) & (freqs < hi)].sum() / total) for name, lo, hi in BANDS}
    return {
        "centroid_hz": float((freqs * power).sum() / total),
        "dominant_hz": float(freqs[int(np.argmax(power))]),
        "flatness": float(flatness),  # 0 is pure tone, 1 is white noise
        "bands": bands,
    }


def fundamental(x, rate):
    """(hz, strength) from the loudest 300 ms, or (None, strength) if it isn't periodic."""
    size = min(len(x), int(0.3 * rate))
    if size < 256:
        return None, 0.0
    hop = max(1, size // 4)
    energy = [rms(x[i:i + size]) for i in range(0, len(x) - size + 1, hop)]
    start = int(np.argmax(energy)) * hop
    chunk = x[start:start + size] - np.mean(x[start:start + size])
    spec = np.fft.rfft(chunk, 2 * size)
    corr = np.fft.irfft(spec * np.conj(spec))[:size]
    if corr[0] <= 0:
        return None, 0.0
    corr = corr / corr[0]
    lo, hi = int(rate / 2500), min(size - 1, int(rate / 30))
    if hi <= lo:
        return None, 0.0
    peaks, _ = signal.find_peaks(corr[lo:hi])
    if len(peaks) == 0:
        return None, 0.0
    best = peaks[np.argmax(corr[lo:hi][peaks])]
    strength = float(corr[lo + best])
    # Take the first lag nearly as strong: the best is often a multiple of the period.
    for peak in peaks:
        if corr[lo + peak] > strength * 0.92:
            best = peak
            break
    lag = lo + best
    return (float(rate / lag), strength) if strength > 0.5 else (None, strength)


def envelope(x, rate):
    hop = max(1, int(0.001 * rate))
    size = int(0.003 * rate)
    env = np.array([rms(x[i:i + size]) for i in range(0, max(1, len(x) - size), hop)])
    peak_at = int(np.argmax(env))
    peak = float(env[peak_at]) or 1e-12
    relative = env / peak

    def first_below(level):
        later = np.nonzero(relative[peak_at:] < level)[0]
        # Stays below: the last time it was above, not a dip between firing pulses.
        above = np.nonzero(relative[peak_at:] >= level)[0]
        if len(above) == 0 or len(later) == 0:
            return None
        return float(above[-1] + 1)

    onset = np.nonzero(relative >= 0.01)[0]
    arrived = np.nonzero(relative >= 0.7)[0]  # a held tone has no single peak to time
    middle = relative[len(relative) // 3:2 * len(relative) // 3]
    return {
        "attack_ms": float(arrived[0] - onset[0]) if len(onset) else 0.0,
        "peak_ms": float(peak_at),
        "to_-20db_ms": first_below(0.1),
        "to_-40db_ms": first_below(0.01),
        "middle_db": db(np.median(middle)) if len(middle) else None,
    }


def silence(x, rate):
    audible = np.nonzero(np.abs(x) > 10 ** (SILENCE_DB / 20))[0]
    if len(audible) == 0:
        return len(x) / rate * 1000, len(x) / rate * 1000
    return float(audible[0] / rate * 1000), float((len(x) - 1 - audible[-1]) / rate * 1000)


def clipped(x):
    hot = np.abs(x) >= CLIP_LEVEL
    return int(np.sum(hot[1:] & hot[:-1]))  # runs, because one full-scale sample isn't clipping


def loop_join(x, rate):
    """What repeating it does: the step across the join and any swell in level."""
    steps = np.abs(np.diff(x))
    usual = float(np.percentile(steps, 99)) or 1e-9
    step = abs(float(x[0] - x[-1]))
    # Level in 100 ms windows round the loop. The spread is breathing: a crossfade
    # that dips in level, repeating every pass.
    size, hop = int(0.1 * rate), int(0.01 * rate)
    tiled = np.tile(x, 3)
    levels = [db(rms(tiled[i:i + size])) for i in range(len(x), 2 * len(x), hop)]
    return {
        "join_step": step,
        "join_ratio": step / usual,  # over 1 is a bigger step than the wave normally makes
        "ripple_db": float(np.percentile(levels, 97) - np.percentile(levels, 3)) if levels else 0.0,
        "level_at_join_db": float(levels[0] - np.median(levels)) if levels else 0.0,
    }


def measure(path, kind):
    x, rate = soundfile.read(path, always_2d=True)
    info = soundfile.info(path)
    x = x.mean(axis=1)
    looped = kind == "loop"
    lead, trail = silence(x, rate)
    f0, strength = fundamental(x, rate)
    result = {
        "name": path.stem, "kind": kind, "rate": rate, "format": info.subtype, "channels": info.channels,
        "seconds": len(x) / rate,
        "peak_db": db(np.max(np.abs(x))), "rms_db": db(rms(x)),
        "lufs": loudness(x, rate, looped), "phone_lufs": phone_loudness(x, rate, looped),
        "dc": float(np.mean(x)), "clipped": clipped(x),
        "lead_ms": lead, "trail_ms": trail,
        "f0_hz": f0, "f0_strength": strength,
    }
    result.update(spectrum(x, rate))
    result["envelope"] = envelope(x, rate)
    if looped:
        result["loop"] = loop_join(x, rate)
    return result


def kinds(folder):
    table = {}
    render = folder / "_render.tsv"
    if render.exists():
        for line in render.read_text().splitlines()[1:]:
            name, kind, _, took = line.split("\t")
            table[name] = (kind, float(took))
    return table


def show(value, form):
    return "-" if value is None else format(value, form)


def table(rows, columns):
    cells = [[title for title, _ in columns]]
    for row in rows:
        cells.append([fn(row) for _, fn in columns])
    widths = [max(len(line[i]) for line in cells) for i in range(len(columns))]
    for number, line in enumerate(cells):
        print("  ".join(cell.ljust(w) if i == 0 else cell.rjust(w) for i, (cell, w) in enumerate(zip(line, widths))))
        if number == 0:
            print("  ".join("-" * w for w in widths))


def report(rows):
    print("\nLEVEL (dBFS, LUFS)")
    table(rows, [
        ("sound", lambda r: r["name"]), ("kind", lambda r: r["kind"]), ("sec", lambda r: f'{r["seconds"]:.3f}'),
        ("peak", lambda r: f'{r["peak_db"]:.1f}'), ("rms", lambda r: f'{r["rms_db"]:.1f}'),
        ("LUFS", lambda r: f'{r["lufs"]:.1f}'), ("phone", lambda r: f'{r["phone_lufs"]:.1f}'),
        ("lost", lambda r: f'{r["lufs"] - r["phone_lufs"]:.1f}'),
        ("crest", lambda r: f'{r["peak_db"] - r["rms_db"]:.1f}'),
        ("dc%", lambda r: f'{r["dc"] * 100:.2f}'), ("clip", lambda r: str(r["clipped"])),
        ("lead", lambda r: f'{r["lead_ms"]:.0f}'), ("trail", lambda r: f'{r["trail_ms"]:.0f}'),
    ])
    print("\nSPECTRUM (share of energy by band: sub <200, low 200-1k, mid 1-4k, high >4k)")
    table(rows, [
        ("sound", lambda r: r["name"]), ("centroid", lambda r: f'{r["centroid_hz"]:.0f}'),
        ("dominant", lambda r: f'{r["dominant_hz"]:.0f}'), ("f0", lambda r: show(r["f0_hz"], ".0f")),
        ("flat", lambda r: f'{r["flatness"]:.3f}'),
        *[(name, (lambda n: lambda r: f'{r["bands"][n] * 100:.0f}%')(name)) for name, _, _ in BANDS],
    ])
    shots = [r for r in rows if r["kind"] != "loop"]
    if shots:
        print("\nONE-SHOT ENVELOPES (ms)")
        table(shots, [
            ("sound", lambda r: r["name"]), ("attack", lambda r: f'{r["envelope"]["attack_ms"]:.0f}'),
            ("peak at", lambda r: f'{r["envelope"]["peak_ms"]:.0f}'),
            ("to -20dB", lambda r: show(r["envelope"]["to_-20db_ms"], ".0f")),
            ("to -40dB", lambda r: show(r["envelope"]["to_-40db_ms"], ".0f")),
            ("length", lambda r: f'{r["seconds"] * 1000:.0f}'),
        ])
    loops = [r for r in rows if r["kind"] == "loop"]
    if loops:
        print("\nLOOPS (join = step across the seam against the wave's usual step; ripple = level swing round the loop)")
        table(loops, [
            ("sound", lambda r: r["name"]), ("sec", lambda r: f'{r["seconds"]:.3f}'),
            ("join x", lambda r: f'{r["loop"]["join_ratio"]:.2f}'),
            ("ripple dB", lambda r: f'{r["loop"]["ripple_db"]:.1f}'),
            ("at join dB", lambda r: f'{r["loop"]["level_at_join_db"]:+.1f}'),
        ])


def compare(rows, older):
    print("\nBEFORE -> AFTER")
    # Nitro was renamed boost, and its sound with it.
    renamed = {"nitro": "boostgas"}
    known = {renamed.get(r["name"], r["name"]): r for r in older}

    def change(key):
        def cell(row):
            before = known.get(row["name"])
            return f'{before[key]:.1f}>{row[key]:.1f}' if before else f'new {row[key]:.1f}'
        return cell

    def join(row):
        before = known.get(row["name"])
        if row["kind"] != "loop":
            return "-"
        if not before or "loop" not in before:
            return f'new {row["loop"]["ripple_db"]:.1f}'
        return f'{before["loop"]["ripple_db"]:.1f}>{row["loop"]["ripple_db"]:.1f}'

    table(rows, [
        ("sound", lambda r: r["name"]), ("LUFS", change("lufs")), ("phone", change("phone_lufs")),
        ("peak", change("peak_db")), ("centroid", change("centroid_hz")), ("ripple", join),
    ])
    gone = sorted(set(known) - {r["name"] for r in rows})
    if gone:
        print("\nno longer rendered:", ", ".join(gone))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--json", type=Path, help="write the measurements here")
    parser.add_argument("--compare", type=Path, help="an earlier --json to compare with")
    parser.add_argument("--only", help="only sounds whose name contains this")
    args = parser.parse_args()

    known = kinds(args.folder)
    rows = []
    for path in sorted(args.folder.glob("*.wav")):
        if args.only and args.only not in path.stem:
            continue
        kind, took = known.get(path.stem, ("shot", None))
        row = measure(path, kind)
        row["render_ms"] = took
        rows.append(row)

    if args.json:
        args.json.write_text(json.dumps(rows, indent=1))
    if args.compare:
        compare(rows, json.loads(args.compare.read_text()))
    else:
        report(rows)


if __name__ == "__main__":
    main()
