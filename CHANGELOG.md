# Changelog

## Unreleased

### Added

- A website at <https://spppd.vanillaiice.xyz>, with the downloads, this changelog and a
  blog.
- PRIVACY & TERMS on the ONLINE screen opens the [privacy policy](PRIVACY.md) on the
  website, which links to the [terms of use](TERMS.md).

### Changed

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
- Each car has its own nitro sound.

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
- Sliding fills the nitro tank faster.
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
- Stronger on/off nitro with a warp effect, and synthesised sound effects.
- Engine types, and CYBER, modelled on a Model S Plaid.

### Changed

- Arcade handling and a flat, bright arcade look became the default.
- Slipstream, and a settled pad layout.

## 2.0.0 (2026-10-30)

- Overhaul: a new vehicle model, tracks, interface, effects and track editor.
