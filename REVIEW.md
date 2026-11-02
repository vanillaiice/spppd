# SPPPD Review

This is the review of the code described in `ARCHITECTURE.md`: what falls short, what
each roadmap item will have to change, and the rules worth keeping.

Severity is my judgement. "Confirmed" means I ran it. "From the code" means I traced
it by reading and didn't run it.

Issues 1 and 2 and the cleanup list were fixed on the `cleanup` branch. The numbers
below stay as they were, so references to them still hold.

## Online design limits

All from the code. These matter most for rematch and ranked play.

**3. Races don't start together.** Each client starts its countdown when its own
`rm.start` returns, and nothing lines the two up. How far apart they land depends on
the handshake:

- If one side's `seen=1` arrives before the other's next 0.25 s resend, which is usual
  on a quick link, that side loads straight away and sends its own `seen=1` only when
  `rm.start` returns. The other client's lights then go out at least one load time
  later (222 to 326 ms on this desktop with the JIT off, more on a phone).
- At best both load together, and the gap is up to 0.25 s plus latency plus the
  difference in load times.

**4. Each player can see a different result.** Both clients decide laps and finishes
locally, and the rival's progress comes from a smoothed copy of its position. Finish
times aren't exchanged, and `race.time` starts at a different moment on each side, so
both can see YOU WIN.

**5. A version mismatch fails silently.** There's no protocol version. Adding `horn`
made sync packets one field longer. An older client ignores the extra field, but a new
client rejects the shorter packet. So between an old and a new client, the new one
sees the rival sit on the grid while the old one sees a normal race. The link still
looks healthy, because any packet refreshes `lastHeard`.

**6. Tracks are matched by name only.** A saved track of the same name but a different
shape races on two different roads, with no warning.

**7. Sync has no sequence number.** A late packet can replace a newer one, moving the
rival backwards briefly. It's cheap to fix.

**8. An online pause leaves the car driving.** The race keeps running, as intended,
but keyboard and pad input still reach the car behind the menu, while touch input is
reset. The up and down keys work the throttle and brake while also moving the menu
focus.

**9. Some errors read as the rival leaving.** Once racing, any `event|error` sets
`peerGone`, so a dashboard close or a ban shows YOUR RIVAL LEFT THE RACE.

**10. Smaller gaps in connecting:**

- `pairing` has no timeout, so a lost error packet leaves the player on "Driver
  found" until CANCEL.
- A joiner missing the host's track calls `network.fail`, which closes the socket
  without sending `leave`. The host then races alone for about 5 s before the relay's
  sweep reports it.
- `menu.startOnline` overwrites `settings.track`, `laps` and `time` before checking
  the track exists.
- `handleEvent` handles a `joined` event the relay never sends.

**11. The dashboard's Host check isn't access control.** Bound to `:9090`, as it was
on 2026-11-01, a browser on the LAN gets a 403. But anyone can send `Host: localhost`
with curl and reach `/ban` and `/close`, since requests without an `Origin` pass.
Keep it on `127.0.0.1`, as the README says.

## What the roadmap will touch

**Sharing tracks online.**

- Don't send track files as Lua. `setfenv` stops a file reaching anything, but it
  doesn't stop a loop that never ends, and LuaJIT will load precompiled bytecode, which
  isn't safe to run from an untrusted source. Today those files are the player's own.
  Once they come from a stranger they need a plain data format and a parser, with
  limits on node count and values.
- Packets stop at 2048 bytes on the relay, and a large track doesn't fit. ARDENNES is
  about 15 kB as source. That needs chunks and acknowledgements, on a protocol that has
  neither. The relay forwards opaque packets, so only clients change.
- It also resolves issue 6.

**Rematch.** Needs a fix for issue 3 first, or every rematch inherits the skew.
`quitRace` disconnects and `rm.restart` is hidden online, so the connection has to
outlive a race. The relay doesn't need changing, because a pair stays paired.

**3-4 players.** A real rewrite of the pairing model.

| Assumes two players | Where |
| --- | --- |
| `Client.Partner` is one pointer, and forwarding has one target | `server/main.go` |
| `rooms` holds a host until the first join removes it | `server/main.go` |
| Packets carry no sender id | `network_manager.lua` |
| One `peerState`, `peerHello` and `session.peerCar` | `network_manager.lua` |
| `self.cars[2]`, `peerSlot`, `Race:peerLeft` | `sim/race.lua` |
| `seen` is one flag, so a three-way start needs a real ready check | `network_manager.lua` |

**Ranked play and profiles.** The current design can't support them without a
referee. Clients are authoritative over their own cars and results (issues 3 and 4),
and the relay reads nothing it forwards. Trustworthy results need the server to at
least agree a start time and collect finish times, plus authentication and abuse
protection. That's a real server, not a change to the relay.

**Elimination and sprint races.** Elimination fits the current rules. Sprint needs
open-ended tracks, and `Track` assumes a closed loop everywhere: `wrap`, lap distance,
barriers and the racing line.

## Rules worth keeping in view

These aren't enforced by anything except tests and review:

- `src/sim/dynamics.lua`, `src/sim/track.lua` and `src/config.lua` stay free of LÖVE.
- Sliding is the only way to earn nitro.
- New cars go on the end of `garage`. New paints go on the end of `PAINTS`, which is
  part of the wire protocol.
- Online races use ARCADE, because tiers change grip.
- Default towards fun over realism, and keep realism behind SPORT and SIM.
- Lengthening the sync packet stops new clients reading old ones (issue 5).
- Pad changes are pad only. The keyboard stays as it is.

## Test results

Results on the `cleanup` branch. The relay didn't change, so its row is from `c88f172`:

| Run | Result |
| --- | --- |
| `love . --test` | 511 passed, 0 failed. Per-car and per-track tests expand the 199 `it` blocks |
| `go vet`, `go test -race` | Clean, 33 passed |
| `love . --test network` against a live relay | 9 passed, including the two tests that skip without one |
| `make test-visual` | Passed, 83 checks, on GL and on GLES |
