# SPPPD Review

This is the review of the code described in `ARCHITECTURE.md`: what falls short, what
each roadmap item will have to change, and the rules worth keeping.

Severity is my judgement. "Confirmed" means I ran it. "From the code" means I traced
it by reading and didn't run it.

Issues 1 and 2 and the cleanup list were fixed on the `cleanup` branch. Issues 3 to 11
were fixed on `online-deploy`, along with shared tracks, rematch and 3-4 players, and the
abuse protection a public relay needs. The numbers stay as they were, so references to
them still hold.

## Fixed online issues

Each of these has a test. `ARCHITECTURE.md` section 16 describes how they work now.

| Issue | Was | Now |
| --- | --- | --- |
| 3 | Clients started apart by up to a load time | Everyone counts down on the leader's clock. Within 30 ms on loopback with a 1234.5 s clock difference |
| 4 | Both could see YOU WIN | Each client sends its own finish time on the shared clock, and nobody estimates another car's laps |
| 5 | Version mismatches failed silently | The relay compares protocol numbers and refuses with a message, including clients from before this |
| 6 | Tracks matched by name | Tracks match by a hash of their shape |
| 7 | Late packets moved the rival backwards | Sync carries a sequence number and a round |
| 8 | Keys reached the car behind the pause menu | The car coasts while paused online |
| 9 | Any error read as the rival leaving | `event\|error` and `event\|closed` are separate, and the toast gives the real reason |
| 10 | Gaps in connecting | No `pairing` state to get stuck in. `fail` always sends `leave`. Online doesn't touch saved settings. `joined` is gone |
| 11 | The dashboard's Host check could be forged | It checks the connection itself, or a password |

Other problems fixed along the way, none of them in the review:

- A car unknown to this version of the game crashed `menu.startOnline`, and `paint` and
  `time` weren't checked. All of it came straight from another player.
- A rival who quit mid-race left their car on the road as a wall.
- The relay read packets into a 2048-byte buffer, so a longer one was cut and forwarded.
- A driver who stopped sending kept their last velocity for 5 s.
- FINISHED P2 read as a driver's name. It's now FINISHED 2ND.
- Closing the game sent no `leave`, so the others waited for the relay's sweep.
- A new leader had no copy of the track's text, so a `need` packet would have crashed it.

## Online limits that remain

The ONLINE screen warns players about the ones they can run into (`menu.ONLINE_NOTES`).

**Clients are still trusted.** Each one is the authority on its own car, laps and
finish time, so a modified client can cheat. That's fine between friends with a room
code, and it's why ranked play needs what's described below.

**Getting back in has a limit.** Since protocol 5 a game that loses the relay, through
a network change, lost signal or a trip to the background, takes its seat back from
a new address (`ARCHITECTURE.md` section 16, Getting back in). Away for over 35 s,
it's out, and finishes the race alone. Its own car stood still while it was in the
background, so it's well behind. This has been tested on loopback, not on a phone
switching from Wi-Fi to mobile data.

**The clock assumes a symmetric link.** Half a ping is a guess at one way's delay. If
one direction is much slower than the other, starts differ by half that difference.
Nothing here has been measured over the real internet or a phone network: everything
under Test results ran on loopback or a LAN.

**Everyone goes through one relay.** Two players next to each other but far from the
server still see each other late. Extrapolation covers at most 0.25 s, so collisions
at high ping will look wrong.

**A blocking load.** `rm.start` stops the loop. Since protocol 5 a phone that takes
over 5 s to load is only away, and back as soon as it sends again, unless the load
takes over 35 s. The A04 hasn't been measured since the world got heavier.

**A hostile track is bounded, not cheap.** The limits stop a hang, but a 20 km track
still takes seconds to build on a phone. Only someone you've shared a room code with
can send you one.

## What the roadmap will touch

**Ranked play and profiles.** The current design can't support them without a
referee. Clients are authoritative over their own cars and results, and the relay reads
nothing it forwards. Trustworthy results need a server that checks them, plus accounts.
That's a real server, not a change to the relay. The shared start and shared results
are a start on what it would need.

**Elimination and sprint races.** Elimination fits the current rules. Sprint needs
open-ended tracks, and `Track` assumes a closed loop everywhere: `wrap`, lap distance,
barriers and the racing line.

## Rules worth keeping in view

These aren't enforced by anything except tests and review:

- `src/sim/dynamics.lua`, `src/sim/track.lua` and `src/config.lua` stay free of LÖVE.
- Sliding is the only way to earn boost.
- New cars go on the end of `garage`. New paints go on the end of `PAINTS`, which is
  part of the wire protocol.
- Nothing that comes from another player runs as code or is trusted as a number.
- Online races use ARCADE, because tiers change grip.
- Default towards fun over realism, and keep realism behind SPORT and SIM.
- Changing any packet between clients needs a new `network.PROTOCOL`.
- Pad changes are pad only. The keyboard stays as it is.

## Test results

Results on the `online-deploy` branch, 2026-11-02:

| Run | Result |
| --- | --- |
| `love . --test` | 561 passed, 0 failed |
| `go vet`, `go test -race` | Clean, 51 passed |
| `love . --test network` against a live relay | 29 passed |
| The same, through the production container | 28 passed, before the warning's test was added: `alpine:3.20`, `nobody`, read-only root, no capabilities |
| `make test-visual` | Passed, 84 checks, on GL and on GLES |
| `make test-online-visual` | Passed, 46 checks, on GL and on GLES, with the screens checked by eye |

No real phone, no second machine and no real network were part of these runs, and
the relay hasn't been deployed.
