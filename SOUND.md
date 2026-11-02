# SPPPD Sound

The style guide for the game's sound, then the measurements behind it and what the
2026-11 pass changed.

Every sound is synthesised by `src/audio.lua` on first launch and cached in the save
folder. No audio files ship, and that stays true: a sound's parameters are the source.

**How to read the numbers.** "Measured" means a tool produced the figure from the
rendered samples or from the real `audio.update`. "Inferred" means it's reasoning from
those. By ear, the pass's first version of the speed, slide and nitro sounds failed,
and the numbers had called them fine. What replaced them was picked by ear on the
bench, out of three takes of each, but hasn't been judged in a race. Nothing else here
says a sound is better. [What to listen for](#what-to-listen-for)
lists what only ears can settle.

## Style guide

Every new sound has to meet this.

### Format

44.1 kHz, 16-bit, mono, rendered in Lua. The target feel is a cohesive, believable
arcade car, not samples of a real one.

### Palette

| Ingredient | Used for |
| --- | --- |
| Square waves, plain sfxr | Anything that's the game talking: lights, lap, menus, finish |
| Stepped noise (sfxr's sample-and-hold) | Crunch, grit, anything mechanical breaking |
| White noise through a low-pass and a high-pass, moving | Air and rubber: road, wind, off-road, scrub, nitro |
| Noise ringing in resonators | Pipes, dead metal. Never a clean sine for a mechanical sound |
| Sawtooths a little off each other | Rubber stick-slipping: the squeal |
| Sines | Only things that really whine: turbo, thump under a crash |
| Slides that fall, noise that coarsens as it dies | How things end |

### Rulings from play

These came from the user playing the game. Measurements don't overrule them.

- Metal stays dead. "Sound pans hitting each others. Horrible", and "sounds like a
  clank". No long clean partials: a tail's strongest partial stays within about 18 dB
  of the band around it, and `a crash is dead metal` tests that it doesn't repeat.
- Off-road stays soft. It was "too rough" once. `loose` keeps its smoothness test.
- CYBER doesn't sound like a UFO: no clean partials sliding together.
- SAMURAI was "too distorted". Add top end after the saturation, never by driving it.
- NA engines aim at the startup's flare. Compare octave by octave at the same rpm.
- More cylinders are rougher, against real physics, by choice.
- Braking doesn't make the tyres sound: it would nag every corner.
- Downshifts stay silent, and the startup stays as it is.
- Speed isn't static. "Horrible and static/white noise" was road and wind, which were
  white noise with a gentle slope, pitched up as the car went faster. No steady sound
  is broadband, and speed must not brighten one.
- A slide isn't noise either, and it has to last. It was "horrible, especially when
  higher". A real drift pins `slide` at 1, so the top of the range is what a slide
  sounds like for seconds at a time. Judge it held, not as a moment.
- Nitro is "smooth like a can slowly releasing air, but with pressure", never "too
  strident". Smooth roll-off, a chest under it, a swell in, a slow sigh out.
- The takes picked by ear, each out of three: speed is rumble and air, not mostly air
  and not rumble alone. Slide is a low rubber howl, not a higher squeal and not a
  scuff alone. Nitro is gas with a chest, not a deeper push and not an airier can.

### Who owns which band

Sounds that share a band mask each other, so each thing that has to be heard gets a
place of its own. Inferred from the spectra. The tyres are the exception: their note
was picked by ear and shares the engine's band, so what separates them is being a
different kind of sound.

| Band | Owner |
| --- | --- |
| 60 Hz to 1 kHz | Engine. Crash thumps pass through. Road and wind sit under it, quietly |
| 300 Hz to 1 kHz | The engine's phone presence. Keep this strong. The tyre howl's note sits in it, at about 520 Hz |
| 1 to 2.5 kHz | The howl's harmonics, turbo whistle, menus, the top of the nitro |
| 3 kHz and up | Nothing steady. Only crash edges and other things that are over quickly |

### Levels

Files have rules, but what counts is the level as played, because `audio.update`
scales everything. These are as played, at full VOLUME, from `mix.py`, as full range
then through the assumed phone corner. The VOLUME setting defaults to 0.8, -1.9 dB.

| Category | LUFS |
| --- | --- |
| Whole mix, cruising | -14 ±2, phone -17 ±2 |
| Engine, at cruise | -15 ±2, phone -19 ±3 |
| Engine, idling | -25 ±2, phone -33 to -38. Electric is exempt: it's silent at rest |
| Engine, lift off | At least 3 dB under cruise |
| Tyres in a full drift | -27, phone -27 |
| Grinding along a wall | -22, phone -22 |
| Road | -29 at 40 m/s, -24 at 70 |
| Wind | -28 at 70 m/s, -36 at 40 |
| Off-road | -28, phone -29 |
| Nitro | -20 full, -24 near empty |
| Shift | -23, phone -29 |
| Lights, lap, finish | -14 to -21 |
| Menus | -29 to -33 |

Crashes are measured by how far they lift the loudness over a steady drive, in 400 ms
windows: graze under 1 dB, tap about 1, hit 2 to 4, crash 5 or more. Sizes must not
overlap, and harder must never be quieter.

Car to car, a scene's mix stays within about 4 dB, on either kind of speaker.

### File rules

- Peak at or under -0.5 dBFS. Engine loops stop at `LOOP_PEAK`, -0.9 dBFS.
- DC under 1%. Anything with firing pulses or saturation gets `dcBlock`.
- Nothing reaches `soundData`'s clamp at ±1, which clips in silence. Scaling a clipped
  signal down afterwards hides it from every peak meter, so check the crest factor:
  at least 7 dB for noise, and at least 11 dB for a crash. `atan` tops out at 1.57, so
  scale it.
- First sample near zero, and at least 30 ms of fade at the end of a one-shot.
- **Nothing that plays for seconds is static.** As played, at the highest pitch it
  gets: spectral flatness under 0.35 from 200 Hz to 8 kHz, and at most about 5% of its
  energy above 4 kHz. Look at those two, not only loudness. The old nitro read 0.93 and
  about two thirds, and passing every level target said nothing about that. Read `flat` and `high`
  in `analyze.py`'s spectrum table as faults, not as notes.
- A steady noise moves, by `wander` or `swell`. Fresh noise that doesn't is a fault on
  the line, not a sound.

### Envelopes

| Kind | Attack | Body | End |
| --- | --- | --- | --- |
| Crash | Loudest within 10 ms | Falls away at once, no plateau | Gone by its length, 0.2 to 0.85 s by size |
| Menus and lights | Under 1 ms | Held, sfxr's decay | About 20 ms to 0.6 s |
| Gas and air one-shots | About 15 ms | Falling pitch | Up to 0.6 s |
| Loops | None: faded in `audio.update`. Nitro swells in over 0.1 s and sighs out over 0.3 s | No step at the join. Only what's meant to move may move: wind gusts on purpose | |

### Loops

Whole cycles of whatever repeats, then `crossfade` with how much of the sound is
unrelated noise: 0 for engines and the squeal, 1 for noise, 0.5 for the motor. Getting
that wrong dips or swells at the join once per loop.

### Variation

Repeated one-shots vary in pitch: 6% for crashes (plus a little level), 7% for shifts
and blow-offs, 3% for menus. The start lights and the finish don't: they're signals.

### Cost

First launch renders everything, on phones with no JIT. `love . --sounds new <folder>`
prints the time with the JIT off. It's at 2.14 s now, which is over budget: keep it
within 10% of 1.9 s, which took about 12 s on the Galaxy A04. Anything longer has to pay for itself: shorten a loop, or drop
oversampling somewhere it isn't doing anything.

## Inventory

| Sound | Made by | When | How it plays |
| --- | --- | --- | --- |
| `engine<voice>_1..3` | `engineData` | Always, by car | Loops at rpm / rendered rpm, handing over by rpm, volume by revs and throttle |
| `engine<voice>_idle` | `engineData` | Near idle, throttle shut | Loop, pitch follows rpm |
| `engine<voice>_overrun` | `engineData` | Throttle shut | Loop, pitch follows rpm |
| `engine<voice>_limiter` | `engineData` | `model.limiting` | Loop, fades in at 30 per second |
| `turbo1,2,4` | `turboData` | On power, by car | Loop, pitch and volume from pressure |
| `blower` | `toneData` | Supercharged cars | Loop, pitch and volume from revs |
| `motor` | `motorData` | CYBER, and a rival CYBER | Loop, pitch from revs |
| `scrub` | `bandNoise` | Past the grip limit, off the brakes | Loop, volume from slide, pitch from speed |
| `squeal` | `squealData` | Well past the limit, off the brakes | Loop, volume from slide, pitch from speed and slide |
| `grind` | `grindData` | Touching a barrier or car | Loop, volume from contact and speed |
| `road` | `bandNoise` | Moving | Loop, pitch and volume from speed |
| `wind` | `bandNoise` | Over 18 m/s | Loop, from speed and slipstream |
| `loose` | `bandNoise` | Grass, gravel, kerbs | Loop, from share of wheels and speed |
| `nitro` | `bandNoise` | Nitro burning | Loop, pitch and level sag as the tank empties |
| `horn` | `hornData` | H, B, Circle or the HORN button | Loop, pitch from mass. Rival has its own |
| `impact1,2,3` | `crashData` | Crash, by strength | One-shot, 2 voices each, ±6% pitch, pitch from mass |
| `scrape` | sfxr | A graze, strength under 0.15 | One-shot, 2 voices, ±6% pitch |
| `shift` | model | Upshift | One-shot at 0.55, ±7% pitch |
| `blowoff` | model | Pressure dumped | One-shot, volume from pressure, pitch from turbos, ±7% |
| `beep`, `go` | sfxr | Start lights | One-shot at 0.6 and 0.7 |
| `lap` | sfxr | A lap, except the last | One-shot at 0.5 |
| `finish` | model | Crossing the line | One-shot at 0.6, lower if not first |
| `click`, `select` | sfxr | Menus, and `select` on a respawn | One-shot at 0.3, ±3% (0.5 on a respawn) |
| `startup` | model | The splash | One-shot at 0.8 |

All are static sources. The radio is the only stream. Loops pause at zero volume, and
`audio.play` restarts its source, so a sound can't pile up on itself.

## What the pass found and did

Ranked by how much each should change the feel of the game. That order is judgement.
The numbers in it are measured.

| # | Issue | Measured before | Change | Measured after |
| --- | --- | --- | --- | --- |
| 1 | Crashes sound the same at any strength | Crash strength runs 0.17 to 27, but volume was `min(1, 0.25 + s)`, full by 0.75. Lift +0.8 to +1 dB at every size. One sample, flat for its first 80 ms | Three sizes on a log scale, a graze, a real hit at the start, engine ducks on a big one, pitch by mass | Lift +0.1 graze, +1.4 tap, +2.1 and +4.4 hit, +5.4 and +6.4 crash |
| 2 | A drift can barely be heard | Tyres -33.9 LUFS, 18 dB under the engine and 8 under road noise. 7 to 18 dB under everything else at 1 to 2.5 kHz, by car | A low rubber howl over a duller scrub, once well past the limit. The first version was narrow noise, and failed by ear | Tyres -27.1. From 12 dB under everything else at 1 to 2.5 kHz to 2 dB under, by car, and QUAD TURBO's whistle sits in that band |
| 3 | The engine vanishes on a phone | 80 to 96% of its energy under 200 Hz. Lost 8.8 dB through the phone corner. Blower 3.5 dB over its own engine there | A rasp from each burst, a shelf after the saturation, loops levelled by what's above 300 Hz, blower down 2.5 dB | Same -15.4 on full range, -20.9 on a phone, +3.3 dB. Loses 5.5 dB. Blower 2.3 dB under the engine |
| 4 | Cars vary widely on a phone | Spread 6.3 dB cruising, 10.9 on the limiter | The same levelling | 3.8 and 4.3 dB |
| 5 | Dragging along a wall is silent | `postSolve` drops under 200 N·s, which at 120 Hz is any force under 24 kN. Only BAJA BEAST got through, as a 63 ms blip every 120 ms | A `grind` loop from any contact | -21.6 LUFS while touching, and silent when stopped |
| 6 | Idle is nearly silent | -28 to -32 LUFS. -37 to -50 on a phone. Only pitched-down loops played | A loop of its own for each engine, ticking over | -25, and -33 to -38 on a phone |
| 7 | Revs dip at every crossover | Mean -3.2 dB. Worst sweep dip 4 dB, on OPEN WHEELER | Handover by power, and much narrower | Worst sweep dip 2.3 dB, and brief. See limits |
| 8 | Noise loops breathe | -1.2 to -2.2 dB at the join, 1.6 to 3.1 dB of ripple | `crossfade` by how much is noise | No dip left but the motor's -1.2. What ripple remains is texture put there on purpose |
| 9 | A hard hit could be lost | The gap was shared, so a light contact could swallow the big one straight after it, even in the same step | Only the hardest contact of a step plays, and a bigger hit gets through the gap | Tested in `impactLevel` and by reading. Not exercised in a live crash |
| 10 | Engines sit off centre | DC up to 6.1% | `dcBlock` | 0.23% at most, on any sound |
| 11 | The menus repeat exactly | No variation | ±3% pitch | |

### What listening overturned

The first report said road, wind, off-road, nitro and scrub had "kept their loudness and
spectrum", as if that were a pass. It was the fault. Measured as played, before and
after the rebuild, for the same moment in a race:

| Sound | Centre of energy | Flatness, 1 is white noise | Energy above 2 kHz | LUFS |
| --- | --- | --- | --- | --- |
| Road, 70 m/s | 2455 > 358 Hz | 0.48 > 0.00 | 34% > 0.3% | -24.7 > -23.8 |
| Wind, 70 m/s | 4603 > 725 Hz | 0.80 > 0.02 | 65% > 1.5% | -28.4 > -27.9 |
| Nitro, full tank | 5546 > 1625 Hz | 0.93 > 0.31 | 87% > 32% | -17.4 > -20.3 |
| Scrub, slide 1 | 1395 > 815 Hz | 0.24 > 0.04 | 21% > 4% | -30.6 > -29.7 |
| Squeal, slide 1 | 1457 > 776 Hz | 0.02 > 0.00 | Two thin noise bands > a note and its harmonics, 3% | -25.0 > -29.2 |
| Off-road | 2290 > 449 Hz | 0.43 > 0.01 | 29% > 0.6% | -26.1 > -27.7 |

- **Road and wind** went from white noise with a gentle slope to a dark rumble and low,
  gusting air. Speed used to nearly double their pitch, which is what made them hiss
  more the faster you went. Now it moves pitch far less, road keeps getting louder up
  to 70 m/s where it used to stop at 31, and the road's texture is what speeds up.
- **The squeal** was noise through two thin bands, and a real drift holds it at its
  loudest. It's now a note at about 520 Hz with its harmonics, 4 dB quieter. It's
  still 5 to 6 dB over the original at 1 to 2.5 kHz. Against the first version of the
  squeal, that band is 4 to 6 dB lower.
- **Nitro** was the loudest noise in the game and 87% over 2 kHz. It now has a -12 dB per
  octave roll-off from 2.4 kHz, a chest under 320 Hz, a 0.1 s swell in, a 0.3 s sigh out,
  and loses up to 30% of its level as the tank empties.
- **Engine.** The rasp raised the noise above 1 kHz by 6 to 7 dB at the top of the revs,
  and making the rasp repeat with the engine cycle barely helped, because most of that
  noise was the bursts' own, run together and lifted by the shelf. So the bursts use the
  same repeating grain up high, and low revs keep their roughness. At the V8's top
  loop the noise fell from -10.1 dB of the whole sound to -15.5, against -11.0 originally.
  Above 1 kHz it's -21.6, against -16.4 at first and -23.2 originally.
- **Off-road** was the same fault, though nobody had complained. Left as it was, it
  would have become the one hiss left, so it went with the rest and got softer, which
  is what its ruling asks for.

### Left alone

Measured identical, so not touched by accident: `beep`, `go`, `click`, `select`, `lap`,
`finish`, `horn`, `turbo1,2,4`, `blower`, `blowoff`, `startup`. These already fit the
family, and the user had played most of them.

Nitro and scrub stopped being sfxr presets: at their settings sfxr's noise is plain
white, so eightfold oversampling did nothing measurable and took 22% of the first
launch. They use sfxr's filters directly, for about a fifth of the cost.

### Not done

- The rival isn't panned and has no Doppler.
- Kerbs have no rumble of their own, only a little of `loose`.
- The pause menu still cuts the loops off with `audio.silence`. OpenAL Soft fades a
  stopped source, from memory of its code, so this probably doesn't click. Not tested.

## Before and after

### One file at a time

| | Before | After |
| --- | --- | --- |
| Sounds | 57 | 68 |
| Sample rate, depth, channels | 44.1 kHz, 16-bit, mono | Same |
| Largest DC offset | 6.10% | 0.23% |
| Clamped samples | 0 | 0 |
| Highest peak | -0.7 dBFS | -0.5 dBFS |
| Engine speed loops, LUFS | -16.6 to -9.0 | -13.4 to -9.2 |
| Worst dip at a noise loop's join | -2.2 dB | -1.2 dB |
| Worst unplanned ripple in a noise loop | 3.1 dB | 2.6 dB, the road's texture. Wind's 6.9 dB is its gusts |

| New sound | Peak | LUFS | Phone | Crest | Attack | Length |
| --- | --- | --- | --- | --- | --- | --- |
| `impact1` | -1.5 | -18.3 | -19.8 | 14.8 dB | 2 ms | 0.20 s |
| `impact2` | -1.1 | -14.7 | -17.3 | 13.0 dB | 4 ms | 0.40 s |
| `impact3` | -0.5 | -11.2 | -12.2 | 11.4 dB | 6 ms | 0.85 s |
| `squeal` | -3.1 | -15.3 | -15.4 | 12.0 dB | Loop | 1.5 s |
| `grind` | -3.1 | -11.2 | -11.9 | 7.8 dB | Loop | 1.2 s |

### The mix, all twelve cars

Median, as played. Spread is loudest car against quietest.

| Scene | Phone LUFS | Full LUFS | Spread, phone |
| --- | --- | --- | --- |
| Idle | -46.7 > -34.4 | -29.9 > -25.1 | 12.7 > 14.7 (only because CYBER stays silent) |
| Cruise | -18.3 > -18.1 | -14.4 > -14.6 | 6.3 > 4.6 |
| Drift | -18.2 > -17.5 | -14.3 > -14.2 | 7.0 > 3.9 |
| Off-road | -17.7 > -17.7 | -14.0 > -14.3 | 6.2 > 4.1 |
| Lift off | -22.0 > -22.6 | -19.5 > -19.0 | 3.4 > 3.2 |
| Limiter | -16.8 > -16.8 | -12.7 > -14.2 | 10.9 > 4.3 |
| Rev sweep | -20.2 > -19.2 | -15.9 > -15.0 | 6.5 > 4.1 |
| Everything at once | -14.1 > -14.4 | -11.9 > -12.2 | 3.8 > 2.7 |

Car-to-car spread is a little worse than the first version of the pass at cruise, at
4.6 dB against 3.8. Road and wind no longer put the same bright layer under every car,
so the differences between engines show more. That's slightly over the 4 dB target.

The V8 against the startup's flare, at 6600 rpm, each aligned on its own loudest band:

| Octave from | 63 | 125 | 250 | 500 | 1k | 2k | 4k |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Flare | -3.6 | 0 | -7.8 | -9.5 | -14.5 | -21.3 | -27.4 |
| V8 before | -7.0 | 0 | -6.1 | -12.2 | -17.6 | -27.7 | -36.1 |
| V8 after | -10.8 | 0 | -5.8 | -7.1 | -12.2 | -18.9 | -24.6 |

So the top end now sits about 2.5 dB over the flare where it was 3 to 9 dB under, and
the deep bass is 3.8 dB lighter than it was. That's the trade made for a phone.

## Limits

- **The phone figures assume a speaker.** They use a 300 Hz high-pass, not a
  measurement of the Galaxy A04 or any other phone.
- **`mix.py` is arithmetic, not a recording.** It sums the samples at the volumes and
  pitches the real `audio.update` asked for. It isn't OpenAL, and the scenes are
  scripted, not driven.
- **Crossovers can still cancel.** Two loops at one speed share every harmonic, and how
  they line up depends on when each started. At the middle of a crossover that moved
  the level by 6 to 10 dB across random starts, and no gain law fixes it. The handover
  is now narrower, so a pull passes through instead of living there. Locking the phase
  would need OpenAL's pitch steps to agree exactly, and they drift apart within a
  minute (inferred from its fixed-point stepping).
- **The largest crash peaks over full scale at full VOLUME.** 1.21 at most, on QUAD
  TURBO, for a few milliseconds, and 0.97 at the default 0.8. OpenAL Soft limits its
  output by default, so it shouldn't clip, but that's from its documentation. Steady
  scenes peak at 1.02 at worst, up from 0.97.
- **Not run on a phone.** The A04's first launch was about 14.5 s in total. With the
  JIT off here, rendering takes 2.14 s against 1.87 s, 14% longer and over the 10% this
  guide allows. At the ratio seen before, that's about 1.7 s more on the A04.
- **Road almost disappears on a phone.** Its energy is mostly under the assumed 300 Hz
  corner. Wind, at about 700 Hz, is what's left there to say how fast you're going.

## What to listen for

`make listen`, or `love . --visual listen`. TAB swaps old and new at any moment, on
the same car at the same rpm. `[` and `]` change car.

1. **Speed, slide and nitro in a race.** These were picked on the bench, away from a
   real lap. Does a long drift wear? `SQUEAL_MAX` sets it. Does the howl get lost under a
   loud engine, now that it shares the engine's band? Does nitro still feel like a
   reward over a flat-out engine? `NITRO_LEVEL` sets it.
2. **Crashes:** keys 1 to 6, on SAMURAI then TOFU RUNNER. Can you tell a tap from a hit
   from a crash with your eyes shut? Does anything ring like a pan? `CRASHES` and
   `IMPACT_TIERS` in `src/audio.lua` hold all of it.
3. **The V8:** `X`, then TAB back and forth on SAMURAI, and again at full REVS. It should
   stay a V8, closer to the splash, and less hissy up top. High up its noise now repeats
   with the engine cycle, which could read as buzzy. `fresh` in `engineData` sets that.
4. **Idle:** `Z` on several cars. Is the tick-over believable, or too present? Does it
   hand over cleanly as you drag REVS up from 0? `IDLE_LEVEL` sets it.
5. **Rev sweep:** `A`, on BAJA BEAST and SAMURAI, which show the deepest dip, around 60%
   of the revs. Does a hole or a change of tone show as it passes? `BLEND_WIDTH` trades
   the two: wider is a longer overlap and a smoother change of tone.
6. **Off-road and wall:** `G` and `B`. Off-road changed without being asked, to stay
   with the road. The wall is quite noisy on purpose. `GRIND_MAX` sets it.
7. **In a race:** the bench can't show how these sit against a real lap, so drive one
   and put a car into a wall. Hear whether crashes startle more than they should.

## Measuring again

    pip install -r tests/sound/requirements.txt
    make sound-report

`love . --sounds new <folder>` writes every sound the real `audio.load` renders, with
render times, then replays `tests/sound/scenes.lua` through the real `audio.update`
and logs each frame. `analyze.py` measures the files. `mix.py` adds up the logs.
`analyze.py` works at each file's own pitch, so judge a loop that gets pitched up, as
road and wind do, at the pitch `audio.update` gives it.

`tests/sound/audio_original.lua` is the module before this pass, byte for byte as it
was in commit `c88f172`. It's the backup, it's what `old` means in those commands, and
it's what `make listen` compares with. It lives under `tests/` because `assets/` goes
into every build, and because the originals were always code rather than files.
