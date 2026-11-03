# Privacy policy

Last updated 2026-11-03. The rules for using the server are in [TERMS.md](TERMS.md).

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
- There are no player accounts, names, emails, device IDs, ads or third-party
  trackers.
- The server counts players for statistics, but stores a keyed hash of each IP
  address, never the address itself, and deletes the hashes after 30 days.
- The website counts visits and downloads with Umami, on the operator's own server.
  It sets no cookies and can't follow you to other sites.

## What the server handles

| What | Why | Kept |
| --- | --- | --- |
| Your IP address and port | To pass your packets to the others in your room, and theirs to you | In memory while you're connected |
| Game packets: your car, paint, position, inputs, and the track if you host | To pass them to the others in your room | Not at all. The server passes them on without reading them |
| The room code | To put you in the right room | In memory until the room empties |
| Log lines: host, join, leave and time-out events, with IP address, port and room code | To run the server, fix problems and deal with abuse | In the server's log, about 10 MB of it, until newer lines overwrite them or the server is updated, whichever comes first |
| Recent activity on the admin dashboard: the same events, plus refused connections | Same as the log | The last 200 events, in memory, until the server restarts |
| A banned IP address, when it was banned, and which admin banned it | To keep out someone who abused the server | Until the ban is lifted |

Only the operator can see the log and the dashboard. The dashboard isn't reachable
from the internet, and it needs an admin login.

## Statistics

The official server runs with statistics turned on. It keeps:

- **Unique players:** for each day (UTC), a keyed hash (HMAC-SHA-256) of every IP
  address that hosted or joined a room. The key is random, made on the server, and
  never leaves it, so a hash can't be turned back into an address by trying every
  address. Hashes are deleted after 30 days. What stays is how many different
  addresses played that day.
- **Daily totals:** rooms hosted, joins, races started, drivers in them, refused
  connections, the most players at once, and traffic in and out.
- **Races:** when each room started racing and when it emptied, how many drivers it
  had, and the game's protocol version. No addresses, room codes or names.

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

## Why this is allowed

Under the GDPR, the server relies on legitimate interests: running an online game
needs your IP address, and keeping it safe needs logs and bans. The statistics are
kept as small as they can be and hashed, for the same interest in keeping the service
running. The website's visit counts rely on the same interest: knowing whether anyone
uses the game, without cookies or tracking you elsewhere.

## Your rights

You can ask what's held about you, and ask for it to be corrected or deleted. Because
the server keeps no names, include your IP address and roughly when you played, so it
can be found. A hash can only be matched by computing it again from your address on
the server. You can also complain to your data protection authority.

## Where it's stored

On one server rented from a hosting provider, which stores it for the operator and
does nothing else with it. It's never sent anywhere else.

## Changes

Changes are made in this file, with the date at the top. Big changes are also noted in
the game's [changelog](CHANGELOG.md).
