# Plan: quick match, drivers, ranked races, email sign-in

Written 2026-11-07 against `master` at `ac18fd1`, then revised the same day with the
decisions in §1. This is a plan only. Nothing here is built.

It covers the two `ROADMAP.md` items about strangers:

- **Quick match online:** one button puts you in a race with other players, with no room
  code to share, plus a way to vote out a driver who spoils it.
- **Ranked races and profiles:** a driver name, a rating, a leaderboard and a record that
  follows you. These need the server to check race results, which it doesn't do today.

## 0. Where we start

What exists today, and how it limits the design:

| Fact | Consequence for this plan |
| --- | --- |
| The relay is dumb. It seats players in rooms and forwards packets it never reads | Quick match fits it well. Ranked can't: the relay has to start reading packets from ranked rooms (the referee, §5.4) |
| Each game is the only authority over its own car. There's no shared simulation | The server can't replay a race. It can only check that what a car reports is physically possible |
| The sim is Lua and Box2D, and floating point differs between phones and PCs | Re-running replays on the server isn't an option. Ruled out |
| `PROTOCOL` stays 5 for all of 3.x. Packets only grow at the end, unknown packets and events are ignored, and `FEATURES` gates new behaviour | Everything here is new events plus fields appended to existing packets. No protocol break |
| LÖVE 11.5 has no HTTPS, and the relay speaks plain UDP | The game never handles a password. Email and password live on spppd.xyz, over HTTPS (§6) |
| Online races force ARCADE handling (`src/sim/race.lua:86`) | Changes in phase 1: everyone drives their own setup (§3.6) |
| One relay on one VPS, `relay.db` in SQLite, backed up by Litestream | Drivers and ratings go in `relay.db`, so they're backed up. Nothing touches the disk while the relay holds `mu` |
| The website is static Astro behind Caddy. Caddy already passes `/api/status` to the relay | The board, profiles and the account page are static pages fetching JSON from the relay through Caddy |
| Few players online at once | Matching has to take anyone rather than wait for a perfect match. Nothing should split a small crowd more than it needs to |
| The relay always deploys before the game | Same here: each phase ships relay first, then the game, then the site |

## 1. Decisions

| Question | Decision | From |
| --- | --- | --- |
| Cars in ranked | Each driver picks their own car **and setup**: paint, handling (ARCADE, SPORT, SIM) and gearbox (AUTO, MANUAL). In every online race, not just ranked | The user |
| Sign-in | A key on the device for now (phase 2). Email and password added later, optional (phase 4) | The user |
| Leaving a ranked race | Counts as last | The user |
| Rematch in ranked | None. RACE AGAIN queues again. With few people online, that often brings back the same drivers anyway, but through the rating window and the pair limit (§5.5) | My call (the user said "idk") |
| Leaderboard on spppd.xyz | Yes, with ranked (phase 3) | The user ("yes") |
| Names in rooms by code | Yes, for anyone signed in | My recommendation, kept |
| Nobody else looking | Wait, showing how many are online. No AI fill | My recommendation, kept |
| Rating shown as | A number and a rank | My recommendation, kept |

## 2. Phases

Each phase ships on its own, on its own branch, and is worth having without the next.

| Phase | What players get | `FEATURES` |
| --- | --- | --- |
| **1. Quick match** | QUICK MATCH: a race with whoever's looking, on a track the server picks. Vote out a driver. Every online race uses each driver's own handling and gearbox | 0 → 1 |
| **2. Drivers** | A driver name everyone sees, PROFILE, a recovery code to move to another device | unchanged |
| **3. Ranked** | RANKED queue, a rating, a top-10 board in game, a race history; rankings and driver pages on spppd.xyz | 1 → 2 |
| **4. Email and password** | Optional: sign in on any device through spppd.xyz, and get a lost driver back by email | unchanged |
| Later, maybe | Lap leaderboards per track, seasons, AI fill (§7) | |

Phase 1 needs no accounts, so it can ship first and show whether enough people turn up
to make ranked worth it.

---

## 3. Phase 1: quick match

### 3.1 What the player sees

```
ONLINE
  SERVER        spppd.xyz
  CAR           TOFU RUNNER
  PAINT         ...
  HANDLING      SIM            <- new here: the driver's own, used online now
  GEARBOX       MANUAL         <- new here
  QUICK MATCH                  <- new
  HOST A ROOM
  ROOM CODE
  JOIN A ROOM
  PRIVACY & TERMS
  BACK
```

1. QUICK MATCH. The status reads `LOOKING FOR DRIVERS · 0:07 · 12 ONLINE`. The online
   count matters: with nobody around, the player sees that, and isn't left wondering.
2. Someone else is looking: `OASIS · 3 LAPS · DUSK · STARTS IN 0:15`, with the
   drivers listed. More can join until the timer runs out or the grid is full (4).
3. At zero, the race starts by itself. Nobody presses START RACE.
4. Results: REMATCH (same drivers, as today), FIND ANOTHER (leave and queue again in
   one press), and QUIT.
5. In the pause menu, a matched race with three or more drivers has VOTE OUT, which
   lists the other drivers.

CANCEL leaves the queue at any point before the start.

### 3.2 Packets

All seat requests keep today's layout, `event|INTENT|PROTO|CODE|COOKIE|TOKEN|`, and gain
fields on the end. The padding stays last, and a field made only of `.` reads as empty,
so the new relay reads an old game's padding as "no value".

| Packet | Direction | Purpose |
| --- | --- | --- |
| `event\|queue\|5\|\|COOKIE\|\|FEATURES\|ACCOUNT\|PROOF\|MODE\|DATA\|padding` | Client to relay | Find me a race. `MODE` is `quick` (`ranked` in phase 3). `CODE` is empty. `ACCOUNT` and `PROOF` are empty until phase 2, `DATA` until phase 3. Padded to 64 bytes like the others, and answered with a cookie first, like the others |
| `event\|host\|…` / `join` / `back` | Client to relay | Unchanged, plus `FEATURES\|ACCOUNT\|PROOF` on the end |
| `event\|match\|KIND\|TRACK\|LAPS\|TIME\|STARTIN\|ONLINE\|VOTES` | Relay to client | Sent right after each `room` event in a relay-made room, so the sweep repeats it every second too. `TRACK` is a built-in track's id. `STARTIN` is whole seconds to the start, or `-1` while alone. `ONLINE` is players on the relay. `VOTES` is `seat:count,…` |
| `event\|kick\|SEAT\|` | Client to relay | My vote to remove the driver in `SEAT` |
| `event\|closed\|The other drivers voted you out` | Relay to client | The existing `closed` event, with a new reason |
| `hello\|car\|paint\|have\|ready\|vote\|features\|handling\|gearbox` | Everyone | `handling` and `gearbox` appended (§3.6). Older readers take the first seven fields |

`event|room|SEAT|CODE|…` already carries the room's code after the seat. The game
ignores it today. A game that queued adopts it, so that `back` works for a relay-made
room as it does for any other.

### 3.3 Relay changes (`server/main.go`, a new `server/match.go`)

New fields on `Room`:

```go
Kind     string    // "" for a room someone hosted, "quick" or "ranked"
Features int       // the lowest FEATURES of the drivers in it
FillBy   time.Time // when it stops taking drivers; zero while there's only one
Race     MatchRace // track, laps, time of day
Votes    map[int]map[int]bool // target seat -> the seats voting it out
```

And on `Relay`:

```go
filling  map[string][]*Room    // by Kind, oldest first: relay-made rooms still taking drivers
cooldown map[string]coolDown   // IP (driver in ranked) -> when it may queue again, after a vote-out
avoid    map[pairKey]time.Time // two IPs (drivers in ranked) kept apart for 30 min after a vote
```

**`register`, intent `queue`.** It goes through the same checks as `host` and `join`:
the cookie, `-min-proto`, connections per IP, `-max-players`. Then:

1. If `MODE` isn't one the relay knows, refuse with "This server doesn't have that kind
   of race". If `FEATURES` is below 1, refuse with the out-of-date message. If the
   address is cooling down, refuse with "You can look for a race again in 2 minutes".
2. Look through `filling["quick"]`, oldest first, for a room with a free seat whose
   drivers don't avoid this address. Seat the driver in the lowest free seat.
3. If there's none, make a room: an 8-character code from the game's alphabet. The game
   makes 6-character codes, so the two never clash, and the code is checked as taken
   anyway. Pick the track, laps and time of day (§3.5).
4. If this is the second driver, set `FillBy = now + 15 s`. A full grid of four sets it
   to `now + 3 s`, so everyone sees the grid before the lights.
5. `announce(room)`, which now sends `match` after `room` to each member.

**Joining by code.** `join` with the code of a relay-made room is refused with "That
room is for quick match". Sharing the code doesn't let anyone in.

**Leaving.** Today the host leaving a lobby closes it, because the race is the host's to
set. In a relay-made room the race is the relay's, so `remove` closes it only when
`Kind == ""`. Otherwise the next seat is the leader, as it already is mid-race. If the
room drops back to one driver while filling, `FillBy` goes back to zero.

**Locking.** `lock` takes the room out of `filling`. At `FillBy` the room also leaves
`filling`, so nobody is seated in the second before the leader starts.

**Safety net.** A relay-made room still unlocked 60 s after `FillBy` is closed with "The
race didn't start". The game queues again by itself after that reason. This catches a
leader who never starts, for example one who keeps losing their connection.

**Votes.** `event|kick|SEAT|` counts only in relay-made rooms, and only from a seated
driver against another one. A target goes when **two** others have voted, which in a
room of three is both of them. In a room of two there's no vote, because one person
could remove the other; the game offers FIND ANOTHER instead. The relay then:

- sends the target `event|closed|The other drivers voted you out` and removes them.
  Mid-race, they show as LEFT THE RACE, as today.
- puts the target on a queue cooldown: 2 minutes, doubled for each vote-out that day, up
  to an hour. The map is capped like the rate buckets, evicting at random.
- keeps each voter and the target apart in matching for 30 minutes.
- writes a dashboard line: `[VOTED OUT] 1.2.3.4:5 from room "Q7KX3MPA" (2 votes)`.

**Sweep.** No change to the timeouts. A queued game sends `hello` four times a second, so
it isn't silent while it waits alone. The repeat now sends `match` with `room`.

**Restart.** Relay-made rooms are saved in the temporary store like any other. The JSON
gains `kind`, `race`, `fillBy` and `features`. Votes and cooldowns aren't kept.

**Status, analytics, dashboard.**

- `/api/status` gains `looking`: drivers in relay-made rooms that haven't started.
- `races` gains a `kind` column, which `migrate` adds, and `daily` gains `quick_races`.
- The dashboard shows a QUICK badge on relay-made rooms, and `filling 0:12` until they
  start.

### 3.4 Game changes for quick match

`src/network_manager.lua`:

- `network.FEATURES = 1`.
- `network.queue(host, port, me, mode)`: like `connect` with role `queue`, code `""`, and
  `register` sending the new fields.
- `onRoom`: adopt the room code from the event when the role is `queue`.
- `onMatch(fields)`: keeps `network.match = { kind, track, laps, time, startIn, online,
  votes }`, converts `startIn` to a local deadline once, as `startAt` is today, and turns
  changes in `votes` into notices (§3.7).
- The leader of a relay-made room builds `network.setup` from the built-in track named in
  the match, through `catalog.builtin()`, with the match's laps and time, then publishes
  it. Every game already holds the built-in tracks, so nobody downloads one. If two
  versions of the game differ in a track, the hashes differ and the joiner fetches the
  leader's copy, as it would a shared track. Nothing new is needed for that.
- Auto-start: in `tick`, the leader calls `network.startRace()` once the deadline has
  passed and `canStart()` is true. The rules about nobody being away still hold.
- Any game ignores a `setup` in a relay-made room whose track hash isn't the match's
  track's, so a leader can't swap the track.
- `network.voteOut(seat)` sends `event|kick|SEAT|` four times a second until the vote
  shows in `votes` or the room changes.
- `network.findAnother()` is `leave` followed by `queue` with the same car and setup.

`src/menu.lua`:

- QUICK MATCH, HANDLING and GEARBOX rows on the ONLINE screen. HANDLING and GEARBOX are
  the same settings as SETUP's (`settings.assists`, `settings.gearbox`), shown here
  because they now count online.
- Status text while queued, using `network.match.online` and the countdown.
- FIND ANOTHER on the results of a relay-made room.
- VOTE OUT in the pause menu, opening a list of the others.

When the server doesn't answer `queue` at all, which is what a relay from before this
phase does, the game says "This server doesn't have quick match yet" after the usual
6 s, not "Can't reach the server".

### 3.5 What the relay picks

- **Track:** a random built-in track from a list compiled into the relay
  (`mirage … oasis`), skipping the last two it picked so the same one doesn't come up
  three times running.
- **Laps:** from a small table by track, aiming at about three minutes a race. In phase 3
  the table comes from the exported game data (§5.3). Until then it's written by hand.
- **Time of day:** random from day, dusk, night and midnight.
- **Car and setup:** never. Each driver brings their own (§3.6).

### 3.6 Everyone's own setup online

Today `Race.new` gives every car in an online race ARCADE, because "tiers change how much
grip a car has, so an online race has to share one". With the decision in §1, each driver
uses their own handling and gearbox online, in quick match, ranked and rooms by code
alike. One rule for all of online is simpler than three.

- `src/sim/race.lua`: online uses `opts.assist` like any other race. `menu.startOnline`
  passes `settings.assists`. The gearbox already comes from `settings.gearbox`.
- Another driver's car runs no tyre model on my screen (`RemoteDriver` places it), so
  their handling changes nothing for me. Slipstream `tow` is applied by the car being
  pulled, so it follows that driver's own handling, which is right.
- `hello` carries `handling` and `gearbox`, so the standings and results can show them:
  `ALICE · TOFU RUNNER · SIM · MANUAL`. A 3.0 game sends neither and still drives
  ARCADE itself, which is shown as unknown.
- `menu.ONLINE_NOTES`: "Everyone drives with their own handling. ARCADE grips the most."
- `ARCHITECTURE.md` §6, "Handling tiers": drop "Online races always use ARCADE".

### 3.7 Telling the others about votes

When a target's count goes up, every game shows a toast: `P3 MAY BE VOTED OUT (1/2)`.
With names from phase 2 it's `ALICE MAY BE VOTED OUT (1/2)`. The target sees the same
toast, so a vote is never a surprise.

### 3.8 Compatibility

| Situation | What happens |
| --- | --- |
| New game, old relay | `queue` is an unknown intent, so the old relay drops it. The game says the server has no quick match. Rooms by code work as today |
| Old 3.0 game, new relay | It never sends `queue`. It can't join a relay-made room by code. Everything else is unchanged |
| 3.0 and a newer game in a room by code | The newer one drives its own setup, the older one ARCADE. Each car is its own game's, so nothing breaks |
| Two versions of 3.x in one quick match | Both have `FEATURES ≥ 1`. The room's `Features` is the lowest, and the leader offers only what that allows, as `roomFeatures` does now |

### 3.9 Tests

Go (`server/match_test.go`, with the fake sender and clock the relay tests already use):

- Two queuers share one room. The second sets `FillBy`, the fourth shortens it, and a
  fifth gets a new room.
- One leaving while filling clears `FillBy`. The host leaving keeps the room open.
- `lock` and `FillBy` both take the room out of `filling`.
- `join` by a relay-made code is refused.
- A forged source gets one cookie and no seat. No answer before the cookie is bigger than
  its request.
- Votes: two votes remove the target, none count in a room of two, a vote from outside
  the room or against yourself does nothing, and the cooldown doubles.
- `avoid` keeps two addresses apart, and only for 30 minutes.
- The 60 s safety net closes a room that never starts.
- A relay-made room survives a restart through the temporary store.

Lua (`tests/`):

- Parsing `match`, including fields appended after it.
- `hello` with and without `handling` and `gearbox`.
- An online `Race.new` with SIM handling gives the player's car SIM.
- The leader builds the setup from the match and starts at the deadline, and not while
  anyone is away.
- A `setup` with the wrong hash is ignored.
- `make test-online` gains a quick-match run: three headless games queue against a local
  relay, get one room, start by themselves and finish. A vote-out run with three games
  too.

---

## 4. Phase 2: drivers

### 4.1 What a driver is

A **driver** is a name, with a key on each device it's signed in on. No email and no
password in this phase:

- The first time the player picks a name, the game makes two random 16-byte keys: a
  **device key** and a **recovery key**. Both are kept in `account.lua` in the save
  folder, with the name and the driver's number.
- Each key is sent to the server once, when it's made. After that, the game proves it
  holds them without sending them again (§4.2).
- **Moving to another device:** PROFILE shows a **recovery code**, the driver number and
  the recovery key in base32: `1042-K7Q2M-9XJ4T-…`, about 30 characters. Typing it into
  PROFILE on another device signs that one in, with a device key of its own.
- Up to 10 devices per driver. Past that, the one seen least recently is dropped.
- Lose every device and the code, and the driver is gone, until phase 4 adds email. The
  game says so when it shows the code.

Why this way: there's nothing to phish, no password reused from elsewhere to leak, and no
email to store yet. A device key of its own per device means one can be removed later
(phase 4's account page) without touching the others.

The weak spots, both acceptable for a game rating:

- Each key crosses the network once, in plain UDP, when it's made. Someone watching that
  exact moment on the player's network could copy it.
- The server has to keep the keys to check a proof (§4.2), so a leak of `relay.db`, or
  its backup, would let someone race as any driver. It holds nothing else of value: no
  email (until phase 4), no password reused elsewhere. `PRIVACY.md` says exactly that.

Public-key signatures (Ed25519) or a key exchange would close both, but there's no
tested pure-Lua version fast enough for an A04.

### 4.2 Proving it's you

The relay's cookie is already a challenge: it's bound to the address and a 30 s window,
and only that address sees it. So:

```
proof = base64url(HMAC-SHA-256(deviceKey, intent .. "|" .. cookie))[1..22]
```

The game sends `ACCOUNT` (the driver number) and `PROOF` in each `host`, `join`, `back`
and `queue`. The relay tries the driver's device keys (10 at most, so 10 HMACs at worst).
A proof can't be replayed from another address, or after a minute. In Lua, HMAC is built
from `love.data.hash("sha256", …)` and `bit.bxor`, with a test vector shared by the Go
and Lua tests so the two can't drift apart.

A bad or missing proof still gets a seat in a room by code or quick match. It just races
without a name. Ranked refuses it: "Couldn't sign in. Check PROFILE".

The recovery key works the same way, but only for `recover`, and its proof covers the
new device's key too, so it can't be used to add a different one:
`HMAC-SHA-256(recoveryKey, "recover|" .. cookie .. "|" .. newDeviceKey)`.

### 4.3 Packets

| Packet | Direction | Purpose |
| --- | --- | --- |
| `event\|signup\|5\|COOKIE\|NAME\|KEY\|RECOVERY\|LABEL\|padding` | Client to relay | Make a driver. `KEY` and `RECOVERY` are the two keys in base64, the only time they're sent. `LABEL` is `love.system.getOS()`, to tell devices apart later. Repeated until answered |
| `event\|driver\|ID\|NAME` | Relay to client | You are driver `ID`. Also the answer to a repeated sign-up with the same name and keys, so a lost answer is safe to ask for again |
| `event\|recover\|5\|COOKIE\|ID\|KEY\|LABEL\|PROOF\|padding` | Client to relay | Add this device, proven with the recovery code. Answered with `driver` |
| `event\|signout\|5\|COOKIE\|ID\|PROOF\|padding` | Client to relay | Remove this device's key |
| `event\|rename\|5\|COOKIE\|ID\|PROOF\|NAME\|padding` | Client to relay | New name. Once every 30 days |
| `event\|forget\|5\|COOKIE\|ID\|PROOF\|padding` | Client to relay | Delete my driver (§4.7) |
| `event\|profile\|5\|COOKIE\|ID\|PROOF\|padding` | Client to relay | My profile |
| `event\|profile\|NAME\|SINCE\|DEVICES\|…` | Relay to client | The answer. Phase 3 adds the rating fields on the end |
| `event\|room\|…\|away\|NAMES` | Relay to client | The existing room event, plus `seat:NAME,…` for seats that signed in, in every room including rooms by code. Old games ignore it |

These answers can be bigger than 64 bytes. That's safe, because the cookie has already
shown the address is real, and the rate limit still applies.

### 4.4 Names

- 3 to 12 characters, `A–Z`, `0–9`, `-` and `_`, shown in capitals. The font has them
  all, and none of them is `|`, `,` or `:`.
- Unique ignoring case. The relay keeps a lower-case `name_key` with a unique index.
- Refused: a short reserved list (`ADMIN`, `SPPPD`, `SERVER`, `MOD`, `DELETED`…) and a
  blocklist embedded in the binary, matched as substrings after folding look-alikes
  (`0→O, 1→I, 3→E, 4→A, 5→S, 7→T`).
- The dashboard can rename a driver to `DRIVER1042`. The game finds out from the next
  room or profile event and shows "Your name was changed by the server".
- The same rules in Lua and Go, checked by the same list of cases in both test suites.

### 4.5 Server (`server/drivers.go`)

```sql
CREATE TABLE IF NOT EXISTS drivers (
  id       INTEGER PRIMARY KEY,
  name     TEXT    NOT NULL,
  name_key TEXT    NOT NULL UNIQUE,
  recovery BLOB    NOT NULL,           -- the recovery key (§4.2)
  created  INTEGER NOT NULL,
  seen     INTEGER NOT NULL,           -- day of the last sign-in, not the time
  renamed  INTEGER NOT NULL DEFAULT 0,
  hidden   INTEGER NOT NULL DEFAULT 0, -- off the boards (phase 3)
  banned   INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS driver_keys (
  id     INTEGER PRIMARY KEY,
  driver INTEGER NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
  key    BLOB    NOT NULL,             -- the device key (§4.2)
  label  TEXT    NOT NULL,             -- "Android", "Linux"…
  added  INTEGER NOT NULL,
  seen   INTEGER NOT NULL              -- a day, not a time
);
```

- **Whole tables in memory.** At start, `AttachStore` loads every driver and key into
  `r.drivers map[int]*Driver` and `r.names map[string]int`. At ~200 bytes a driver,
  100,000 drivers is 20 MB, inside the container's 256 MB. Checking a proof is then a map
  lookup and a few HMACs, with no disk on the packet path. If the game ever grows past
  that, the cache can keep only drivers seen in the last 30 days.
- **Writes off the lock.** Sign-up, recover, sign-out, rename, `seen` and delete are
  checked and applied to the maps under `mu`, then handed to a `driverWriter` goroutine
  on a buffered channel, as `persist` does for the temporary store. A full channel drops
  the request without an answer, and the game asks again a quarter-second later.
- **Limits.** Sign-ups: 3 per IP an hour. Recover attempts: 10 per IP an hour and 10 per
  driver an hour, so a recovery code can't be guessed (it's 128 bits anyway). Both kept
  in capped in-memory maps that evict at random.
- **Bans by driver.** A banned driver's proof is refused in every queue with "This driver
  is banned". IP bans stay as they are.
- **Dashboard.** A Drivers section: search by name, see devices (label and dates only),
  rename, hide, ban, unban. Each action writes an activity line.
- **Analytics.** `daily` gains `signups`.

### 4.6 Game

- `src/account.lua`: load and save `account.lua`, `hmac`, `proof(intent, cookie)`, base32
  for the recovery code, and the name rules.
- PROFILE on the ONLINE screen. Without a driver: PICK A NAME, I HAVE A RECOVERY CODE,
  BACK. With one: the name, RENAME, SHOW RECOVERY CODE, SIGN OUT OF THIS DEVICE, DELETE
  DRIVER, BACK. Typing uses `ui.startEditing`, as the room code does.
- Names replace `P2`…`P4` on the cars' labels, the standings and the results, wherever
  `event|room` carries one. A driver who didn't sign in stays `P3`.
- `account.lua` is written only on sign-up, recovery, rename, sign-out and delete. It's
  tiny, and never written during a race.

### 4.7 Privacy and terms

Update `PRIVACY.md` and the site's privacy page:

- New rows: driver name; each device's key, label ("Android"), and the days it was added
  and last seen; the recovery key. Kept until the driver or device is removed. Backed up
  for 7 days.
- What a leaked database would allow (racing as someone), and what it can't (nothing
  else is stored).
- No IP address is ever stored with a driver. The relay knows which address holds which
  seat only while it's connected, as today.
- DELETE DRIVER removes the driver and its keys at once. Ranked results stay for the
  other drivers in those races, with the name shown as `DELETED`. Backups age out within
  7 days.

`TERMS.md` gains the name rules and says the server may rename or remove a driver.

### 4.8 Tests

- Go: sign-up, a repeated sign-up, a taken name, a reserved and a blocked name, the rate
  limits, proof accepted, proof refused (wrong key, other address, old window), recover
  adds a device and drops the oldest past 10, sign-out, rename limit, delete, banned
  driver, drivers reloaded after a restart, the writer channel full.
- Lua: the HMAC test vector, base32 round trip, the name cases, `account.lua` saved and
  loaded, names showing on the results.
- `make test-online`: two games sign up and see each other's names. A third recovers the
  first's driver from its code.

---

## 5. Phase 3: ranked

### 5.1 The rules of a ranked race

- 2 to 4 signed-in drivers, matched by rating (§5.6).
- A built-in track picked by the relay, with laps for about three minutes, and a random
  time of day.
- **Each driver's own car, paint, handling and gearbox** (§1). The car is the one in the
  seat's `hello` when the room locks.
- Collisions on, as in every online race.
- **No rematch.** RACE AGAIN on the results queues again.
- **Leaving counts as last.** So does staying away until the seat goes. Quitting doesn't
  save a rating.
- A race the relay itself breaks (a restart mid-race, or every driver away at once) is
  **void**: nobody's rating moves.

Every result keeps the driver's car, handling and gearbox. The board and profiles show
what people drive with them, and if one car ever takes over the top of the board, a board
per car or a car allowance in the rating can be added later from that history.

### 5.2 What the game sends in ranked

- `queue` with `MODE` `ranked`, a good `PROOF`, and `DATA` (§5.3).
- `sync` gains a last field, `clock`: the shared race clock when it was sent
  (`network.startIn()`, negative once racing). The referee needs it (§5.4). That's why
  ranked needs `FEATURES 2`. Older readers ignore it.

### 5.3 Game data for the server

The referee needs facts only the game knows. A new run mode, `love . --export-server-data`,
writes `server/gamedata.json`, which is committed and embedded in the relay with
`//go:embed`:

```json
{
  "a1b2c3d4": {
    "tracks": {
      "oasis": { "hash": "…", "length": 3120.5, "laps": 3, "samples": [[x, y, s, halfWidth], …] }
    },
    "cars": { "tofu_runner": { "vmax": 71.3 } }
  }
}
```

- The top-level key is `data`: a short hash of everything under it. The game works out
  the same value at start and sends it when it queues for ranked.
- `hash` is `catalog.fingerprint` of the track. `samples` are the points `Track.new`
  builds, thinned to every 5 m, with the half-width including runoff.
- `vmax` is the most the car reaches in a headless bench run, taking the highest over
  every handling and gearbox: boost held on the longest straight with a car ahead to tow
  it. A driver's claimed handling can't raise the limit, so the referee doesn't need to
  trust it. The referee adds a margin on top.
- `laps` comes from the AI's lap time with a mid car, aiming at about three minutes,
  between 2 and 5.

`make server-data` regenerates the file. A Lua test checks the committed file still
matches the game, so a change to a track or car can't ship without it.

The relay keeps every `data` it has been built with, so two game versions can both play
ranked while players update. Ranked only matches games with the same `data`, and refuses
one it doesn't know with "Ranked needs the latest version of the game".

### 5.4 The referee (`server/referee.go`)

In a ranked room, the relay reads what it forwards. That's a deliberate change to "the
relay reads nothing it forwards", for ranked rooms only, and `ARCHITECTURE.md` has to say
so. Everywhere else the relay stays as it is.

**What it reads:**

- `hello` from each seat: the car at lock must be one `data` knows. A car that changes
  after lock is flagged.
- `setup` from the leader: the track hash and laps must be the race's. A wrong one is
  dropped, not forwarded, and the leader is flagged.
- `sync` from each seat, about 20 a second, with the server's receive time.

**What it checks.** Every check uses the server's receive times, which a game can't fake.
Each takes constant time per packet: the nearest-sample search starts from where the car
was last time.

| Check | Rule | Catches |
| --- | --- | --- |
| Speed over ground | Over any window of 1 s or more, distance travelled ≤ `vmax × 1.1 × Δt + 15 m`. A jump to a point *behind* on the track is allowed, because wrecks and resets put a car back | Teleports, speed hacks past the car's limit |
| Progress | Over the same windows, `distance` grows no faster than the speed rule allows | Claiming laps you didn't drive |
| Position matches progress | `distance mod length` is within 40 m of the nearest sample's `s`, and the car is within that sample's half-width plus 20 m of the line | A `distance` field that doesn't match where the car is |
| No false start | Before `clock` reaches 0, the car stays within 3 m of where it started | Leaving before the lights |
| Clock runs true | Over each 10 s, `Δclock / Δreceive` is between 0.97 and 1.03 | A game running fast or slow |
| Finish agrees | The time the server sees `distance` reach `laps × length`, interpolated between packets and moved onto the shared clock with that seat's offset, is within 0.4 s of the `finish` it reports | A made-up finish time |

The seat's offset is the smallest `receive time − clock` seen in the race: the relay's
clock against the shared one, plus the quickest that seat's packets ever arrived.

**Result of each seat:**

- `ok`: finished, every check passed. Placed by reported `finish`. That's the shared
  clock, which is fair to slow connections, and "finish agrees" stops it being invented.
- `dnf`: left, timed out, voted out, or still driving 90 s after the winner. Placed after
  every `ok`, by distance covered.
- `flagged`: failed a check. Placed last, the same as leaving. The reason is kept
  (`seat 2: 180 m in 1.0 s on lap 2`) for the dashboard.

The race is decided when every seat is `ok`, `dnf` or `flagged`. It counts if at least
two drivers were on the grid and at least one is `ok`.

**False alarms are the real risk.** An honest driver flagged by mistake is worse than a
cheat missed, so the margins start generous, and §5.11 tests the referee against
hundreds of honest races before it ever runs live. Flags only *hide*, they never ban:
three flags in 30 days takes a driver off the boards until someone looks at it on the
dashboard.

**What it can't catch.** A changed game that drives within the car's limits, a bot, or
slightly better grip all pass. The notes say so plainly: "Ranked catches impossible
driving, not every cheat."

### 5.5 Rating

Pairwise Elo, which is simple to explain and to recompute:

```
For each driver i in a counted race of N drivers:
  for each other driver j:
    E = 1 / (1 + 10 ^ ((R_j - R_i) / 400))
    S = 1 if i placed ahead of j, 0 if behind, 0.5 if both dnf
    sum += S - E
  ΔR_i = K_i / (N - 1) × sum
K = 40 for a driver's first 10 ranked races, 24 after
```

- Everyone starts at 1000. The rating never goes below 100.
- **Pair limit:** the same two drivers in more than 3 counted races within 24 hours, and
  their pair's term counts a quarter. That limits friends trading wins through RACE AGAIN.
- On the boards after 5 counted races. Until then, PROFILE shows `PLACEMENT 3/5`.
- On the boards only while active: a counted race in the last 30 days. An inactive
  driver keeps their rating and comes back on their next race.
- Every result keeps the rating before and after and the places, so switching to
  Glicko-2 or OpenSkill later is a matter of replaying history, not losing it.

### 5.6 Matching by rating

`register`, intent `queue`, mode `ranked`:

1. Refused without a good proof, without `FEATURES ≥ 2`, with an unknown `data`, for a
   banned driver, or during a cooldown.
2. A filling ranked room fits if it has the same `data`, a free seat, nobody this driver
   avoids, and every driver in it within the window of this one's rating.
3. The window is ±150, growing by 10 a second of waiting, and open to anyone after 60 s.
   With few people online, a race against someone far off is better than no race, and
   Elo moves less when the result was expected.
4. Otherwise a new ranked room: the track, laps and time of day as in quick match.
5. `FillBy` is 20 s from the second driver.

In ranked, cooldowns and `avoid` are by driver, not IP.

### 5.7 Telling the drivers

| Packet | Direction | Purpose |
| --- | --- | --- |
| `sync\|…\|finish\|clock` | Everyone | `clock` appended (§5.2) |
| `event\|rated\|ROUND\|seat:place:rating:delta:outcome,…` | Relay to client | The decided race. Sent with each `room` event until the room empties |
| `event\|top\|5\|COOKIE\|ID\|PROOF\|padding` | Client to relay | The board |
| `event\|top\|rank:NAME:RATING,… (top 10)\|MYRANK\|MYRATING\|DRIVERS` | Relay to client | The answer, under 600 bytes |
| `event\|profile\|…` | Relay to client | Phase 2's answer, plus rating, rank, wins, podiums, the car raced most, and the last 5 results |

The board is kept in memory, sorted, and updated when a race is decided. Asking for it
never touches the disk.

### 5.8 Storage

```sql
ALTER TABLE drivers ADD COLUMN rating  REAL    NOT NULL DEFAULT 1000;
ALTER TABLE drivers ADD COLUMN ranked  INTEGER NOT NULL DEFAULT 0;  -- counted races
ALTER TABLE drivers ADD COLUMN wins    INTEGER NOT NULL DEFAULT 0;
ALTER TABLE drivers ADD COLUMN podiums INTEGER NOT NULL DEFAULT 0;
ALTER TABLE drivers ADD COLUMN flags   INTEGER NOT NULL DEFAULT 0;  -- in the last 30 days
ALTER TABLE drivers ADD COLUMN last    INTEGER NOT NULL DEFAULT 0;  -- day of the last counted race

CREATE TABLE IF NOT EXISTS ranked_races (
  id      INTEGER PRIMARY KEY,
  started INTEGER NOT NULL,
  ended   INTEGER NOT NULL,
  track   TEXT    NOT NULL,
  laps    INTEGER NOT NULL,
  time    TEXT    NOT NULL,
  data    TEXT    NOT NULL,
  void    TEXT                -- why it didn't count, or NULL
);
CREATE TABLE IF NOT EXISTS ranked_results (
  race     INTEGER NOT NULL REFERENCES ranked_races(id),
  seat     INTEGER NOT NULL,
  driver   INTEGER,           -- NULL once the driver is deleted
  car      TEXT    NOT NULL,
  handling TEXT,              -- arcade | sport | sim, as the game said
  gearbox  TEXT,              -- auto | manual, as the game said
  place    INTEGER NOT NULL,
  outcome  TEXT    NOT NULL,  -- ok | dnf | flagged
  finish   INTEGER,           -- ms, ok only
  before   REAL    NOT NULL,
  after    REAL    NOT NULL,
  reason   TEXT,              -- flagged only
  PRIMARY KEY (race, seat)
);
CREATE INDEX IF NOT EXISTS ranked_results_driver ON ranked_results(driver, race);
```

`migrate` adds the columns to an existing database, as it added `backs`. Ratings change
in memory under `mu` when a race is decided. The whole race then goes to the writer
goroutine and is written in one transaction. About 120 bytes a result, so 100,000 races
is about 40 MB.

### 5.9 Game

- `network.FEATURES = 2`, and `clock` on `sync`.
- RANKED under QUICK MATCH. Without a driver it goes to PROFILE first.
- The results panel of a ranked race shows each name with car and setup, the outcome,
  and your new rating with its change: `1032 (+18)`. A flagged or void race says so, with
  the reason in plain words.
- RANKINGS on the ONLINE screen: the top 10 and your place, plus "More at spppd.xyz/rankings".
- PROFILE gains rating, rank, races, wins, podiums, the car raced most, the last 5
  results, and VIEW ON THE WEB, which opens the driver's page (§5.10).
- `menu.ONLINE_NOTES`: "Ranked catches impossible driving, not every cheat."

### 5.10 The board on spppd.xyz

**Relay.** The public HTTP server that answers `/api/status` today (`-status`, on the
kamal network only) gains, read-only and served from memory:

| Route | Answer |
| --- | --- |
| `GET /api/rankings?page=N` | 50 drivers a page: rank, name, rating, races, wins, podiums, the car raced most. Up to page 200 |
| `GET /api/drivers/NAME` | One driver: rating, rank, since, races, wins, podiums, cars raced with counts, and the last 20 results (date, track, laps, place of N, car, handling, gearbox, rating change, the other drivers' names) |

- `Cache-Control: public, max-age=30`. The board in memory is rebuilt at most once every
  5 s, so a burst of requests costs nothing.
- Hidden, banned and inactive drivers aren't listed. Their pages answer 404. A deleted
  driver shows as `DELETED` in others' results.
- 30 requests a second per client IP. Behind kamal-proxy and Caddy every request comes
  from Caddy, so the relay trusts `X-Forwarded-For` only from Caddy's address on the
  kamal network.

**Caddy.** The route for `/api/status` becomes `/api/*` to `spppd-relay:8081`. In
`make site-dev`, Vite proxies `/api` the same way.

**Site.** Two static Astro pages with a small script each, in the site's style:

- `/rankings/`: the table, paged, with a search box that goes to a driver's page.
- `/driver/?name=ALICE`: the profile. Shareable, which is the point of having it on the
  web.

The footer gets a Rankings link. The pages fetch from the same origin, so the CSP needs
no new source.

### 5.11 Dashboard

- Ranked races running, with each seat's referee state live.
- Flagged results with their reasons. Clear a flag, hide a driver, ban a driver.
- `daily` gains `ranked_races` and `ranked_drivers`.

### 5.12 Tests

The most important test is that **honest races are never flagged**:

- `make test-referee` runs headless AI races through a local relay, across every track,
  car and handling, with the loss and jitter the online tests already use, records every
  `sync`, and runs the referee over them. It must flag none. These recordings become
  `server/testdata/` fixtures, so `go test` runs them too.
- The same recordings, edited: a 200 m teleport, `distance` jumped a lap, a fake
  `finish`, speed ×1.3, a start 0.5 s early, a clock running 5% fast, a car changed after
  lock, the wrong track. Each must be flagged with the right reason.
- Rating: hand-worked examples for 2, 3 and 4 drivers, `dnf` ties, the floor, the
  first-10 K, the pair limit, and void races.
- Matching: the window, widening with time, `data` and features mismatches.
- Restart mid-race: the race is void, and nobody's rating moves.
- HTTP: the two routes, paging, hidden and deleted drivers, the cache header, the rate
  limit, and `X-Forwarded-For` ignored from anyone but Caddy.
- Lua: `clock` appended to `sync` and ignored by an old reader, the ranked results panel,
  and the board's parsing.
- Site: the two pages against a relay with test data in `make site-dev`.

---

## 6. Phase 4: email and password (optional)

### 6.1 What it adds

A driver can add an email address and a password. Then they can:

- sign in on any device without the recovery code, and
- get their driver back by email if they lose every device.

A driver without email works exactly as in phase 2. Nobody is asked for an email to play.

### 6.2 Why it's on the website

LÖVE 11.5 has no HTTPS, and the game speaks plain UDP, so a password typed in the game
would cross the network in the clear. So the game never sees one. Everything with a
password happens on `spppd.xyz/account/`, over HTTPS, and the game only opens that page
with `love.system.openURL` and waits.

### 6.3 Flows

**Add email** (from a signed-in game):

1. PROFILE > ADD EMAIL. The game asks the relay for a link code
   (`event|linkcode|5|COOKIE|ID|PROOF|padding` → `event|linkcode|CODE`): 8 characters,
   one use, 10 minutes.
2. The game opens `https://spppd.xyz/account/#link=CODE`, and shows the code too, for
   someone who'd rather type it on another screen. The code is in the fragment, so it
   never reaches a server log.
3. The page asks for an email and a password (twice). The relay checks the code, stores
   the email as unverified with the password hash, and sends a verification email.
4. The link in the email (`/account/#verify=TOKEN`, 24 hours, one use) verifies it. Until
   then the email can't be used to sign in.

**Sign in on a new device:**

1. PROFILE (no driver) > SIGN IN WITH EMAIL. The game makes a device key and asks the
   relay to pair it (`event|pair|5|COOKIE|KEY|LABEL|padding` → `event|pair|CODE`): 8
   characters, 10 minutes.
2. The game opens `https://spppd.xyz/account/#pair=CODE` and shows the code.
3. On the page, the player logs in with email and password and sees "Sign in SPPPD on
   Android? Only say yes to a code your own game is showing." YES adds the key to the
   driver.
4. The game repeats `pair` once a second and, once approved, gets `event|driver|ID|NAME`.
   It saves `account.lua` as after a sign-up, but without the recovery key, which stayed
   on the other device. PROFILE offers NEW RECOVERY CODE, which makes a new recovery key
   and sends it (`event|recovery|5|COOKIE|ID|PROOF|RECOVERY|padding`), replacing the
   old one.
5. The driver gets an email: "SPPPD signed in on Android. Not you? Remove it at
   spppd.xyz/account".

**Forgot password:** the page takes an email and always answers "If that address has a
driver, we've sent a link", so it can't be used to find out who plays. The link
(`#reset=TOKEN`, 1 hour, one use) sets a new password and ends every web login.

**The account page** (logged in): the driver's name and devices (label, added, last seen,
REMOVE), CHANGE EMAIL (verified at the new address, with a notice to the old one),
CHANGE PASSWORD (ends other web logins), REMOVE EMAIL, DELETE DRIVER, LOG OUT.

### 6.4 HTTP routes

All on the relay's public HTTP server behind Caddy's `/api/*`, JSON in and out:

| Route | Method | Action |
| --- | --- | --- |
| `/api/account/link` | POST | Code, email, password: add email to the code's driver |
| `/api/account/verify` | POST | Token: verify the email |
| `/api/account/login` | POST | Email, password: start a web login |
| `/api/account/logout` | POST | End this web login |
| `/api/account/pair` | GET, POST | Code: show which device asks (GET), approve it (POST). Logged in |
| `/api/account/me` | GET | Name, email (shown only here), devices. Logged in |
| `/api/account/devices/ID` | DELETE | Remove a device key. Logged in |
| `/api/account/email` | POST | Change email (sends verification). Logged in, password again |
| `/api/account/password` | POST | Change password. Logged in, old password again |
| `/api/account/forgot` | POST | Email: send a reset link if it has a driver |
| `/api/account/reset` | POST | Token, new password |
| `/api/account/delete` | POST | Delete the driver. Logged in, password again |

### 6.5 Storage

```sql
ALTER TABLE drivers ADD COLUMN email    TEXT;    -- lower case; NULL if none
ALTER TABLE drivers ADD COLUMN verified INTEGER NOT NULL DEFAULT 0;
ALTER TABLE drivers ADD COLUMN password TEXT;    -- bcrypt
CREATE UNIQUE INDEX IF NOT EXISTS drivers_email ON drivers(email) WHERE email IS NOT NULL;

CREATE TABLE IF NOT EXISTS web_sessions (
  hash    BLOB    PRIMARY KEY,   -- SHA-256 of the cookie's token
  driver  INTEGER NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
  expires INTEGER NOT NULL       -- 30 days
);
CREATE TABLE IF NOT EXISTS mail_tokens (
  hash    BLOB    PRIMARY KEY,   -- SHA-256 of the token in the link
  driver  INTEGER NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
  kind    TEXT    NOT NULL,      -- verify | reset
  email   TEXT    NOT NULL,      -- the address it was sent to
  expires INTEGER NOT NULL
);
```

Link and pairing codes live in memory only. A restart loses them, and the player asks
for a new one.

The email address is stored as written, because it's needed to send mail. It's in the
backups like the rest of `relay.db`, in the private bucket. Encrypting the column with a
key kept outside the database is possible, but then losing that key loses every
address, so it isn't worth it yet.

### 6.6 Sending mail (`server/mail.go`)

- A small `Mailer` interface with one implementation for an email provider's HTTPS API.
  Mail goes out from a goroutine with a queue, never from a request or under `mu`.
  Failures are written to the dashboard's activity.
- Which provider is a decision for the user. Cloudflare's email sending service fits,
  since the backups are already on Cloudflare; any transactional provider works the same
  way. Its key and the sender address come from `.env` (`SPPPD_MAIL_*`) as Kamal secrets.
- The sending domain needs SPF, DKIM and DMARC records, or the mail lands in spam.
- Four plain-text emails: verify, reset, new device, email changed.
- Limits: 5 emails per address a day, 100 an hour in all. Past them, the page says to try
  later.
- With no mail settings, `linkcode` answers "Email isn't set up on this server", and the
  account page says the same. Phase 4 can be deployed before the mail is ready.

### 6.7 Web security

- HTTPS is kamal-proxy's, as for the rest of the site.
- The login cookie: a random token, `Secure; HttpOnly; SameSite=Strict; Path=/api/account`,
  with only its hash stored, as the dashboard does.
- Go's `http.CrossOriginProtection` on every non-GET, as on the dashboard.
- Passwords: 10 to 72 bytes (bcrypt's limit), bcrypt cost 12. At most 4 hashes at once,
  so a flood of logins can't take the relay's CPU from the races.
- Lockouts: 10 wrong passwords for one email locks it for 15 minutes. 30 a minute from
  one IP (trusted `X-Forwarded-For`, §5.10) locks that IP for 15 minutes.
- The same answer whether an email exists or not, on login, forgot and link.
- Tokens are 32 random bytes, stored hashed, one use.
- Bodies over 16 kB are cut off, and the server's timeouts stay as they are.

### 6.8 Privacy and terms

- `PRIVACY.md` and the site's privacy page: the email address (optional), what it's used
  for (verification, password reset, new-device and changed-email notices, and nothing
  else, ever), the password stored only as a bcrypt hash, the mail provider named as who
  delivers it, kept until removed or the driver is deleted, 7 days in backups.
- The dashboard never shows a whole address: `a***@g***.com`.

### 6.9 Game

- PROFILE gains ADD EMAIL (signed in) and SIGN IN WITH EMAIL (not signed in), each
  showing its code and a line telling the player to finish on the page that opened.
- The game knows nothing else about email. A device removed on the website finds out at
  its next proof, which fails, and PROFILE says "This device was signed out".

### 6.10 Tests

- Go: every route, the happy path and refusals: wrong password, lockouts, expired and
  reused tokens and codes, unverified email can't sign in, the same answer for unknown
  emails, change and reset end other logins, delete cascades, `CrossOriginProtection`,
  the bcrypt limit of 4. A fake `Mailer` records what would be sent.
- Lua: the two PROFILE flows against a local relay with the fake mailer, approving the
  pairing through the HTTP route in the test.
- Site: the account page against that relay in `make site-dev`.

---

## 7. Later, if wanted

Each of these is a sentence now, to decide on after phase 3 has had real use:

- **Lap leaderboards per track and car:** clean laps uploaded with their ghost (already
  recorded at 15 Hz), checked with the same geometry the referee uses.
- **Seasons:** a soft reset of ratings every few months. Only worth it with a crowd.
- **AI to fill an empty grid** in quick match. It needs the leader to drive AI cars for
  everyone, which online doesn't do today.
- **A board per car, or a car allowance in the rating,** if one car takes over the board.
  The results already keep the car (§5.1).

## 8. Shipping each phase

1. Branch from `master`, build, test (`make test`, `make test-server`, `make test-online`,
   and `make test-referee` from phase 3).
2. Deploy the relay first (`make deploy-relay`, then `make check-relay`). Old games keep
   working against it.
3. Release the game.
4. Deploy the site when its pages changed (phases 3 and 4), with Caddy's `/api/*` route.
   Phase 4 also needs the mail settings in `.env` and the DNS records.
5. Update `ARCHITECTURE.md` §16 (packets, the relay's state, the store's tables, and for
   phase 3 the end of "reads nothing it forwards") and §6 (handling online),
   `menu.ONLINE_NOTES`, `PRIVACY.md`, `TERMS.md`, the site's privacy and guide pages,
   `ROADMAP.md` and `CHANGELOG.md`.

## 9. New limits, all in one place

| Limit | Value | Why |
| --- | --- | --- |
| Quick match fill | 15 s from the second driver, 3 s once full | Short enough to keep people, long enough to gather a third |
| Ranked fill | 20 s from the second driver | |
| Unstarted relay-made room | Closed 60 s after `FillBy` | A stuck leader can't hold drivers |
| Vote-out | 2 votes, not in a room of 2 | One person can't remove another |
| Cooldown after a vote-out | 2 min, doubling each time that day, up to 1 h | |
| Kept apart after a vote | 30 min | |
| Sign-ups | 3 per IP an hour | |
| Recovery attempts | 10 per IP and 10 per driver an hour | |
| Devices per driver | 10, dropping the least recently seen | |
| Renames | 1 per 30 days | |
| Name | 3 to 12 of `A–Z 0–9 - _` | The font, and the packets' separators |
| Ranked window | ±150, +10 a second, open after 60 s | |
| Pair limit | Over 3 counted races in 24 h, the pair counts a quarter | No farming through RACE AGAIN |
| Flags before hiding | 3 in 30 days | Never an automatic ban |
| Board and profile HTTP | 30 requests a second per IP, cached 30 s | |
| Link and pairing codes | 8 characters, 10 min, one use | |
| Email tokens | Verify 24 h, reset 1 h, one use | |
| Wrong passwords | 10 per email, then 15 min locked; 30 a minute per IP | |
| Bcrypt at once | 4 | The races come first |
| Emails | 5 per address a day, 100 an hour in all | |
| In-memory maps (cooldowns, avoid, sign-ups, recovery tries, lockouts) | Capped at 65536, evicting at random | Same as the rate buckets |
