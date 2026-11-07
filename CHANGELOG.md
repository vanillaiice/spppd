# Changelog

## Unreleased

Driver names need a server from this version on. The official one will be updated
first. Everything else still races 3.0 and 3.1.

### Online

- PROFILE on the ONLINE screen picks a driver name, which the others see in the lobby,
  the race and the results instead of P2. There's no email and no password: the game
  keeps a key on this device and proves it holds it. SHOW RECOVERY CODE gives a code
  that signs another device in as you. Rename once every 30 days, sign a device out, or
  delete the driver. The privacy policy and terms say what the server keeps, and the
  name rules.

### Driving

- Boost carries the car where its nose points. Point it away from trouble and boost
  pulls a slide straight: in a one-second save, the car slides 6.0 m sideways instead
  of 8.4 m on tarmac, and 7.1 m instead of 10.4 m on grass, and keeps its speed. It
  doesn't turn the car any tighter on grip. Grass and gravel drag is halved under boost.

## 3.1.0 (2026-11-07)

3.1 still races 3.0 in rooms by code. Quick match needs 3.1, and a server from 3.1
on: the official one is. On an older one the game says it may not have quick match.

### Online

- QUICK MATCH on the ONLINE screen puts you in a race with whoever else is looking, with
  no room code to share. The server picks a built-in track, laps for about three
  minutes, and the time of day. The race starts by itself 15 seconds after a second
  driver arrives, or 3 seconds after a fourth. Alone, it waits and shows how many are
  online. FIND ANOTHER on the results looks for the next race in one press.
- VOTE OUT in the pause menu of a quick match of three or more removes a driver who
  spoils the race once two others agree. Everyone sees the votes coming, the driver
  they're about too. Whoever is voted out can't look for a race for 2 minutes, longer
  each time that day, and isn't matched with the voters for half an hour.
- Every online race uses each driver's own handling and gearbox, set on the ONLINE
  screen, instead of ARCADE for everyone. The lobby and the results show how each
  driver set up.
- The status page shows how many drivers are looking for a race.

## 3.0.0 (2026-11-07)

3.0 is the version the rest of 3.x builds on. Every 3.x version races every other one
online, so an update never splits you from your friends again. To race someone on 3.0,
you need 3.0 too: 2.x games can't join its rooms.

### Two at one screen

- Two players can race at one screen on a desktop: plug in a pad and set PLAYERS to 2
  in race or freestyle setup. The screen splits side by side, each half with its own
  camera, dash, pace notes and toasts, and the timing tower and map sit on the seam.
  With one pad, P1 drives on the keyboard and P2 on the pad; with two, P1 can also use
  the first. A DRIVER row in setup picks whose car, paint, handling and gearbox the
  rows change. Each driver hears their own car on their own side and feels their own
  rumble, either can pause, and the results say who came home ahead.

### Driving

- Burnouts: hold gas and brake together near a stop. The brakes hold one axle
  and the engine spins the other on the limiter, with smoke and rubber. RWD
  spins its rears and swings its tail round when steered. FWD spins its fronts
  and barely turns. AWD spins all four and creeps forward. Let go of the brake
  to launch. It works at the start lights too, where the car stays put. Online,
  the others see your smoke.

- Phones draw faster. On a Galaxy A04, MIRAGE at midnight under boost went from 54 to
  59 frames a second. The first launch after updating takes a little longer, while the
  game makes its sounds again.

### Time trial

- Every lap counts now. Before, one moment with all four wheels off the road threw the
  lap away, so a driver who slid wide never set a best lap or got a ghost. SETUP >
  RULES picks OPEN, the default, or CLEAN, the old rule, which now says the moment a
  lap is lost and why: off the road, a cut, a reset or a wreck. Each rule keeps its
  own best laps and ghosts, and the ones you already have count as CLEAN.

### Controls

- CONTROLS in the main menu is a screen of its own, with everything that used to be
  in SETTINGS: TOUCH CONTROLS (AUTO, ON or OFF, on phones too), TOUCH STEERING, AUTO
  GAS, GEARBOX, TOUCH SIZE, TOUCH OPACITY, VIBRATION and BUTTON LIST.
- A pad works on a phone. Press anything on it, even just the stick, and the touch
  controls get out of the way; touch the screen to bring them back. If the pad drops
  out mid-race, the race pauses.
- Touch can drive a manual gearbox, with DOWN on the left and UP on the right. With
  buttons steering and AUTO GAS off, GAS and BRAKE sit side by side and one thumb
  slides between them.
- Change your keys and pad buttons on CONTROLS > KEYBOARD and CONTROLS > PAD: pick an
  action, then press its new key or button. The arrows, right Shift and Esc always
  work, the stick always steers and the triggers always give gas and brake, but gas
  and brake can have a pad button too. RESET KEYS and RESET PAD bring the defaults
  back.
- D-pad right now changes the song on a pad, as it always said it would.

### Freestyle

- THE LOT is a playground to drive in: a donut ring round a tyre stack, a slalom of 14
  cones and three gates, a long wall to slide along, and two blocks of containers.
  Knock the cones about; they never wreck the car, and they go back to their spots
  once you drive away.
- Freestyle setup has a TRACK row: THE LOT, the default, or any circuit, with no lap
  calls and no WRONG WAY.
- Change car and paint from the pause menu, without leaving the drive. The new car
  takes the old one's place, standing still. With two at a screen, a DRIVER row picks
  whose car they change.

### Online

- Lose the connection mid-race for a moment, and the game tries to get you back into
  your seat. The race goes on meanwhile, and the others see your car as a ghost until
  you're back. Away for over 30 seconds, you're out of the race, as before.
- Protocol 5. Everyone in a room needs this version, and from now on later 3.x
  versions keep racing it: they add to what's sent without changing it.
- The online server is harder to flood with forged traffic.
- Restarting the online server no longer ends races. Your game gets back in on its
  own, as after a lost connection.
- The online server's database (bans, admin logins and statistics) is backed up, and
  copies are kept for 7 days. [PRIVACY.md](PRIVACY.md) says what's in it and what
  isn't.

### Website

- A server status page, <https://spppd.xyz/status/>: whether the online server is up,
  and how many drivers are on it.
- A [roadmap](https://spppd.xyz/roadmap/) of what's planned next, and what isn't.
- A link to the game's itch.io page, where buying it supports development. It stays
  free here.

## 2.8.0 (2026-11-04)

### Added

- The menus have music. There are three songs, made by the game itself like all its other
  sounds: PIT LANE plays by default, and SETTINGS > SONG switches to NIGHT DRIVE or
  SUNDAY CUP. SETTINGS > MUSIC turns it off. It plays in the menus only and picks up
  where it left off after a race. The very first launch takes a moment to start it.

### Changed

- QUAD TURBO has taller top gears. Its top speed goes from 335 to 381 km/h, the highest
  of any car, and 0-100 and 0-200 km/h are unchanged.
- 4WD MONSTER has a turbo four-cylinder in place of a five, and sounds like one.
- The website has a guide: the controls, every car's numbers including 0-200 km/h, and
  what differs between desktop and phone.

### Online

- Nothing changes online: 2.7 and 2.8 race each other.

## 2.7.2 (2026-11-04)

### Changed

- Nitro is now called boost everywhere: the menus, the controls help and the website.

## 2.7.1 (2026-11-03)

### Changed

- SPPPD moved to <https://spppd.xyz>, the website and the online server both. The
  default server is now `spppd.xyz`. A save that names `spppd.vanillaiice.xyz` still
  reaches the same server, and the old website address redirects to the new one.

## 2.7.0 (2026-11-03)

### Added

- Wrecks look like wrecks. A car that hits a fence hard enough to wreck folds in where
  it hit, its paint scuffs dark around the dent, it pours dark smoke while it waits, and
  bits of it fly back off the wall in its own colour, with black plastic and glass. It
  goes back on the road whole: damage doesn't build up over a race.
- A hard hit that doesn't wreck the car still throws a few bits.

### Online

- Protocol 4. A rival's wreck dents and smokes on every screen, not only its own.
  Everyone in a room needs this version: 2.6.0 and older can't join a 2.7.0 room.

## 2.6.0 (2026-11-03)

### Changed

- The cars are rebalanced. Power now decides who is quickest, and cornering follows the
  car: light, nimble cars corner hardest, and heavy ones make their time back on the
  straights. The gap from the fastest car to the slowest over a lap of every track
  is down from 16% to 9%.
- MUSCLE MONSTER sat on traction control the whole way off the line and lapped like
  TOFU RUNNER. It now has 601 kW instead of 470, sits further back on its rear wheels
  and has the grip to use them: 0-100 km/h takes 3.4 s instead of 4.5, and 0-200 takes
  8.6 s instead of 11.3. It still spins its tyres more than any other car.
- Steady cornering grip on ARCADE, before and after (CYBER, WEDGE, QUAD TURBO and OPEN
  WHEELER are unchanged at 1.52, 1.50, 1.50 and 1.69 g):

  | Car | Before | After | Also |
  | --- | --- | --- | --- |
  | 4WD MONSTER | 1.48 g | 1.62 g | 311 kW, up from 281 |
  | TOFU RUNNER | 1.34 g | 1.62 g | |
  | HOT HATCH | 1.39 g | 1.56 g | |
  | ROCKET | 1.48 g | 1.55 g | |
  | BIG BULL | 1.28 g | 1.50 g | stronger brakes |
  | MUSCLE MONSTER | 1.25 g | 1.48 g | 601 kW, up from 470 |
  | SAMURAI | 1.28 g | 1.46 g | |
  | BAJA BEAST | 1.24 g | 1.45 g | stronger brakes |

- Letting go of a long handbrake drift is smoother in every car: the tail no longer
  snaps as the drift ends, and it swings less past straight.

## 2.5.0 (2026-11-03)

### Added

- TOUCH STEERING in SETTINGS: STICK, as before, or BUTTONS. With buttons, left and
  right arrows steer the way the arrow keys do, and a thumb anywhere on the left half
  steers to its side and can slide across without lifting. BRAKE sits above DRIFT, and
  with AUTO GAS off a GAS button takes the corner.

## 2.4.1 (2026-11-03)

- Minor changes.

## 2.4.0 (2026-11-03)

### Added

- A website at <https://spppd.vanillaiice.xyz>, with the downloads, this changelog and a
  blog.
- PRIVACY & TERMS on the ONLINE screen opens the [privacy policy](PRIVACY.md) on the
  website, which links to the [terms of use](TERMS.md).

### Changed

- LUSAIL is replaced by MIRAGE, a new desert circuit. It is built from smooth corners,
  so its fences no longer fold or kink at the bends, and the road keeps one width. Best
  laps set on LUSAIL don't carry over.
- Saves from before 2.3.0, which name the server by its old address, are no longer
  moved to `spppd.vanillaiice.xyz`. They still reach the same server; to switch, type
  `spppd.vanillaiice.xyz` as the server on the ONLINE screen.

### Relay

- Bans, dashboard users and logins are kept in an SQLite file (`-db`), so a restart
  or deploy no longer clears them.
- The dashboard has real users, each with a name and password, and a login page in
  place of the shared password. Users can be added, removed and changed on the
  dashboard, or with `relay user add|passwd|del|list`. `SPPPD_DASHBOARD_TOKEN` (or
  `SPPPD_ADMIN_PASSWORD`) now makes the first user, `admin`, when there are none.
- Optional statistics with `-analytics`: unique IPs (stored as keyed hashes, deleted
  after `-analytics-days`, 30 by default), rooms, joins, races, drivers, refusals, peak
  players and traffic per day, and a record of each race. The dashboard shows the last
  14 days and exports `daily.csv` and `races.csv`. Off by default.
- `-max-rooms` caps the rooms open at once. Past it, hosting is refused with "The
  server has no free rooms", and joining an open room still works. The dashboard shows
  players and rooms against their limits.
- The official server's log is capped at about 10 MB.

## 2.3.0 (2026-11-02)

### Added

- **Fence crashes.** A hit that costs a car 15 m/s of speed wrecks it. You lose
  control for 1.2 s, then restart stopped on the racing line where you hit, ghosted
  for 2.5 s, and the lap stops counting as clean. Every car has the same limit,
  however heavy it is. Driving flat out and bouncing off the fences no longer pays.

### Changed

- The default online server is now `spppd.vanillaiice.xyz`, with no port to type.
  Saves holding the old address move to it, and a server you chose yourself stays.
- Each car has its own boost sound.

### Online

- Protocol 3. A car that has just been reset is now a ghost on everyone's screen, not
  only its own. Everyone in a room needs this version.

Other cars can't wreck you, even by shoving you into a fence. Glancing off a fence
still only bounces.

## 2.2.0 (2026-11-02)

### Online

- Races for two to four players, through a public relay.
- The host's track is shared with everyone in the room, including custom tracks.
- A rematch button, and host-only race setup.
- Room codes are generated, and six characters long.
- A dashboard for the relay, and protection against abuse.

### Added

- Five cars, for twelve in all: TOFU RUNNER, WEDGE, QUAD TURBO, BAJA BEAST and OPEN
  WHEELER.
- Six tracks, for ten in all.
- MIDNIGHT, a fourth time of day with no floodlights.
- A horn.
- Vibration on pads and phones.
- Sliding fills the boost tank faster.
- The finish shows at the line, with the results three seconds later.

### Changed

- Each car has its own engine sound, and the turbo and supercharger sounds are new.
- Six cars are redrawn from their real shapes.
- The game loads behind the splash, and rendered sounds are saved between launches.
- Phones are locked to landscape and start on high effects.

## 2.1.0 (2026-10-31)

### Added

- A freestyle radio: drop your own music on the window.
- Touch controls for phones.
- Stronger on/off boost with a warp effect, and synthesised sound effects.
- Engine types, and CYBER, modelled on a Model S Plaid.

### Changed

- Arcade handling and a flat, bright arcade look became the default.
- Slipstream, and a settled pad layout.

## 2.0.0 (2026-10-30)

- Overhaul: a new vehicle model, tracks, interface, effects and track editor.
