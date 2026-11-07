# Privacy policy

Last updated 2026-11-07. The rules for using the server are in [TERMS.md](TERMS.md).

This covers the official SPPPD online server at `spppd.xyz`, and the
website at the same address, both run by vanillaiice. If you play through a server
someone else runs, they decide what it keeps, and this policy doesn't apply to it.

Questions, or a request to see or delete what's held about you:
**vanillaiice1@proton.me**

## In short

- Racing offline sends nothing anywhere. Your settings, records and tracks stay on
  your device.
- Online, the server sees your IP address, because it can't send you anything without
  it. Other drivers never see it.
- A driver name is optional. Pick one and the server keeps the name, a key for each
  device you race on and a recovery key, and nothing else: no email, password, device
  ID or IP address with it. There are no ads or third-party trackers.
- The server counts players for statistics, but stores a keyed hash of each IP
  address, never the address itself, and deletes the hashes after 30 days.
- The website counts visits and downloads with Umami, on the operator's own server.
  It sets no cookies and can't follow you to other sites.

## What the server handles

| What | Why | Kept |
| --- | --- | --- |
| Your IP address and port | To pass your packets to the others in your room, and theirs to you | While you're connected. Rooms of games that can get back into a race are also written to the server's disk every 2 seconds, so a server restart doesn't end your race, and are read back only within 35 seconds |
| Game packets: your car, paint, position, inputs, and the track if you host | To pass them to the others in your room | Not at all. The server passes them on without reading them |
| The room code | To put you in the right room | Until the room empties, kept like your address |
| A random token for your seat, which only your game is told | To let you back into your seat if your connection drops, or the server restarts | Until you leave the room, kept like your address |
| A cookie worked out from your IP address and port, which only your game is told | To check that packets asking for a seat really come from your address | Not at all. It's worked out again when it's checked |
| Log lines: host, join, quick match, leave, away, back, voted out and time-out events, with IP address, port and room code. A new driver, and a driver signing in on another device, with the name, number, IP address and port | To run the server, fix problems and deal with abuse | In the server's log, about 10 MB of it, until newer lines overwrite them or the server is updated, whichever comes first |
| Recent activity on the admin dashboard: the same events, plus refused connections | Same as the log | The last 200 events, on the server's disk so they outlast a restart, and none older than 7 days |
| An IP address voted out of a quick match, and the addresses of the drivers who voted | To stop that address looking for a race for a while, and to keep it out of the voters' races | In memory only, never on disk: up to an hour for the wait, 30 minutes for keeping you apart, and the count of times that day until the day (UTC) is over. A restart forgets them |
| A banned IP address, when it was banned, and which admin banned it | To keep out someone who abused the server | Until the ban is lifted |
| If you pick one: your driver name and number, the day you made it, the day you last raced with it, when you last renamed it, and whether it's banned | To show your name to the others in every room you race in | Until you delete the driver |
| For each device signed in as that driver: a random key your game made, the kind of device it said it was ("Android", "Linux"), and the days it was added and last used | To check it's really you when you take a seat. Your game proves it holds the key without sending it again | Until you sign that device out, delete the driver, or sign in on more than 10 devices, when the one used least recently is dropped |
| Your driver's recovery key | To sign another device in when you type the recovery code | Until you delete the driver |

### Drivers

Your IP address is never stored with your driver. The server knows which address
holds which seat only while you're connected, as it does without a driver, and only
the sign-up and sign-in lines in the log put a name next to an address.

Each key crosses the network once, when your game makes it. The server has to keep
the keys to check your game's proofs, so if its database or a backup leaked, someone
could race under your name. Nothing else is in it: no email, no password you use
anywhere else.

DELETE DRIVER on the PROFILE screen deletes your driver and all its keys from the
server at once, and frees the name. The backups lose it within 7 days. SIGN OUT OF
THIS DEVICE deletes only that device's key.

The status page shows how many drivers are online and races running. Those are
counts, and say nothing about anyone.

Only the operator can see the log and the dashboard. The dashboard isn't reachable
from the internet, and it needs an admin login.

The server's database (bans, drivers and their keys, admin logins and the statistics
below) is backed up
to rented storage, so it survives the server failing. The backup holds copies from
the last 7 days, so anything deleted from the server is gone from the backup 7 days
later. The key that IP hashes are made with isn't backed up, and nor are the rooms
and the dashboard's recent activity.

## Statistics

The official server runs with statistics turned on. It keeps:

- **Unique players:** for each day (UTC), a keyed hash (HMAC-SHA-256) of every IP
  address that hosted or joined a room. The key is random, made on the server, and
  never leaves it, so a hash can't be turned back into an address by trying every
  address. Hashes are deleted after 30 days. What stays is how many different
  addresses played that day.
- **Daily totals:** rooms hosted, joins, races started, drivers in them, refused
  connections, seats taken back after a lost connection, quick match races, new
  drivers, the most players at once, and traffic in and out.
- **Races:** when each room started racing and when it emptied, how many drivers it
  had, the game's protocol version, and whether it was a quick match. No addresses,
  room codes or names.

The totals are kept with no time limit, because nothing in them points to anyone.
They're used only to see how much the game is played and to plan the server. They're
not sold or shared, and not combined with anything else.

Anyone running their own server has statistics off unless they turn them on with
`-analytics`.

## The website

The website sets no cookies, and loads nothing from anyone else's servers.

Visits are counted with [Umami](https://umami.is), running on the operator's own
server at `stats.hblabs.xyz`. For each page you open and each download you start, it
records the page, the site that sent you, your browser, operating system, device type,
screen size, language and country. It works out the country from your IP address and
doesn't store the address. It groups one visit's pages under an ID made from a hash of
your IP address and browser that changes every month, so it can't follow you from one
month to the next, or to other sites. The counts are kept with no time limit, and used
only to see how much the game is looked at and downloaded.

The proxy in front of the website, which also serves the operator's other sites, logs
each request with your IP address, the page and your browser, to run the server and
deal with abuse. That log stays on the server.

The downloads come from the game's releases on GitHub, so GitHub sees your IP address
when you download, under the [GitHub Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).

## Why this is allowed

Under the GDPR, the server relies on legitimate interests: running an online game
needs your IP address, and keeping it safe needs logs and bans. The statistics are
kept as small as they can be and hashed, for the same interest in keeping the service
running. The website's visit counts rely on the same interest: knowing whether anyone
uses the game, without cookies or tracking you elsewhere.

A driver is different: it's kept because you asked for one, to give you what you
asked for, a name the others see. You can delete it whenever you like.

## Your rights

You can ask what's held about you, and ask for it to be corrected or deleted. For
your driver, give its name or number, or delete it yourself on the PROFILE screen.
For anything else, include your IP address and roughly when you played, so it can be
found, because nothing else ties it to you. A hash can only be matched by computing it again from your address on
the server. You can also complain to your data protection authority.

## Where it's stored

On one server rented from a hosting provider, which stores it for the operator and
does nothing else with it. It's never sent anywhere else.

## Changes

Changes are made in this file, with the date at the top. Big changes are also noted in
the game's [changelog](CHANGELOG.md).
