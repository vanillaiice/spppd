package main

// Quick match: rooms the relay makes itself, for drivers who don't share a code.
// The relay picks the race and seats whoever is looking, and the leader's game
// starts it when the room stops filling. Drivers in one can vote another out.

import (
	"crypto/rand"
	"fmt"
	mrand "math/rand/v2"
	"net"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	quickKind     = "quick"
	matchCodeLen  = 8 // the game makes 6, so the two never clash
	codeAlphabet  = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	fullFill      = 3 * time.Second  // a full grid still sees itself before the lights
	unstartedLife = 60 * time.Second // past FillBy, a room that hasn't started is closed
	votesNeeded   = 2
	voteCooldown  = 2 * time.Minute
	maxCooldown   = time.Hour
	keptApart     = 30 * time.Minute
	notStarted    = "The race didn't start"
	votedOut      = "The other drivers voted you out"
)

// MatchRace is the race the relay picked for a room it made.
type MatchRace struct {
	Track string
	Laps  int
	Time  string
}

// The built-in tracks, in the game's order, with laps for about three minutes
// of racing. Measured from the AI's lap times on ARCADE.
var matchTracks = []struct {
	ID   string
	Laps int
}{
	{"mirage", 3}, {"highlands", 3}, {"harbour", 4}, {"boat", 5}, {"speedway", 5},
	{"temple", 3}, {"riviera", 4}, {"ardennes", 2}, {"touge", 2}, {"oasis", 2},
}

var matchTimes = []string{"day", "dusk", "night", "midnight"}

// coolDown keeps someone voted out from queueing again for a while. It doubles
// with each vote-out in a UTC day.
type coolDown struct {
	Until time.Time
	Day   string
	Count int
}

// pairKey is two IPs kept apart, the lower first.
type pairKey struct{ A, B string }

func pairOf(a, b string) pairKey {
	if b < a {
		a, b = b, a
	}
	return pairKey{a, b}
}

// field is one field of a request, or "" when it's missing or only padding. Games
// pad requests with dots, so an older game's padding lands where a newer one's
// fields go.
func field(parts []string, i int) string {
	if i >= len(parts) || strings.Trim(parts[i], ".") == "" {
		return ""
	}
	return parts[i]
}

// featuresOf reads FEATURES, the seventh field of a request from protocol 5 on.
func featuresOf(parts []string) int {
	n, err := strconv.Atoi(field(parts, 6))
	if err != nil || n < 0 {
		return 0
	}
	return min(n, 999)
}

// features is the lowest FEATURES of the drivers in a room.
func (room *Room) features() int {
	level := -1
	for _, member := range room.members() {
		if level < 0 || member.Features < level {
			level = member.Features
		}
	}
	return max(level, 0)
}

func (r *Relay) pickRace() MatchRace {
	var choices []int
	for i, track := range matchTracks {
		recent := false
		for _, id := range r.recent {
			recent = recent || id == track.ID
		}
		if !recent {
			choices = append(choices, i)
		}
	}
	track := matchTracks[choices[mrand.IntN(len(choices))]]
	r.recent = append(r.recent, track.ID)
	if len(r.recent) > 2 {
		r.recent = r.recent[1:]
	}
	return MatchRace{Track: track.ID, Laps: track.Laps, Time: matchTimes[mrand.IntN(len(matchTimes))]}
}

func newMatchCode() string {
	raw := make([]byte, matchCodeLen)
	if _, err := rand.Read(raw); err != nil {
		panic(err)
	}
	for i, b := range raw {
		raw[i] = codeAlphabet[int(b)%len(codeAlphabet)]
	}
	return string(raw)
}

// fill puts a room on the list of those taking drivers, and unfill takes it off.
func (r *Relay) fill(room *Room) {
	for _, other := range r.filling[room.Kind] {
		if other == room {
			return
		}
	}
	r.filling[room.Kind] = append(r.filling[room.Kind], room)
}

func (r *Relay) unfill(room *Room) {
	list := r.filling[room.Kind]
	for i, other := range list {
		if other == room {
			r.filling[room.Kind] = append(list[:i:i], list[i+1:]...)
			return
		}
	}
}

// avoids says whether two IPs are being kept apart after a vote.
func (r *Relay) avoids(a, b string) bool {
	until, found := r.avoid[pairOf(a, b)]
	return found && r.now().Before(until)
}

// findRoom is the oldest room of a kind that has a seat for ip. A room with
// someone gone quiet is passed over: a game looking for a race talks four times
// a second, so they've most likely gone.
func (r *Relay) findRoom(kind, proto, ip string) *Room {
	now := r.now()
	for _, room := range r.filling[kind] {
		if room.Locked || room.Proto != proto || (!room.FillBy.IsZero() && !now.Before(room.FillBy)) {
			continue
		}
		members := room.members()
		fits := len(members) < maxRoomPlayers
		for _, member := range members {
			if now.Sub(member.LastSeen) > announceWindow || r.avoids(ip, member.Addr.IP.String()) {
				fits = false
			}
		}
		if fits {
			return room
		}
	}
	return nil
}

// coolingDown is how long ip must wait before it may queue again.
func (r *Relay) coolingDown(ip string) time.Duration {
	c, found := r.cooldown[ip]
	if !found {
		return 0
	}
	return max(c.Until.Sub(r.now()), 0)
}

// queue seats a driver looking for a race, in a room that's filling or a new one.
// The checks every seat goes through have already passed. Callers hold the lock.
func (r *Relay) queue(mode string, features int, proto string, addr *net.UDPAddr, token string) {
	if mode != quickKind {
		r.refuse("This server doesn't have that kind of race", addr)
		return
	}
	if features < 1 {
		r.refuse(outOfDate, addr)
		return
	}
	ip := addr.IP.String()
	if wait := r.coolingDown(ip); wait > 0 {
		minutes := int((wait + time.Minute - 1) / time.Minute)
		unit := "minutes"
		if minutes == 1 {
			unit = "minute"
		}
		r.refuse(fmt.Sprintf("You can look for a race again in %d %s", minutes, unit), addr)
		return
	}
	room := r.findRoom(mode, proto, ip)
	if room == nil {
		if r.maxRooms > 0 && len(r.rooms) >= r.maxRooms {
			r.refuse("The server has no free rooms. Try again soon", addr)
			return
		}
		code := newMatchCode()
		for r.rooms[code] != nil {
			code = newMatchCode()
		}
		room = &Room{Code: code, Proto: proto, Since: r.now(), Kind: mode, Race: r.pickRace()}
		r.rooms[code] = room
		r.fill(room)
		if r.tally != nil {
			r.tally.Rooms++
		}
	} else if r.tally != nil {
		r.tally.Joins++
	}
	slot := 1
	for room.Seats[slot-1] != nil {
		slot++
	}
	client := r.seat(room, slot, addr, token)
	client.Features = features
	now := r.now()
	switch count := len(room.members()); {
	case count == maxRoomPlayers && (room.FillBy.IsZero() || now.Add(fullFill).Before(room.FillBy)):
		room.FillBy = now.Add(fullFill)
	case count >= 2 && room.FillBy.IsZero():
		room.FillBy = now.Add(r.fillTime)
	}
	r.event("[QUICK] %v joined room %q in seat %d", addr, room.Code, slot)
	r.announce(room)
}

// matchEvent is what a driver in a relay-made room hears after each room event:
// the race, the seconds until it stops filling (-1 while alone), how many are on
// the relay, and the votes against each seat.
func (r *Relay) matchEvent(room *Room) string {
	startIn := -1
	if !room.FillBy.IsZero() {
		startIn = max(int((room.FillBy.Sub(r.now())+time.Second-1)/time.Second), 0)
	}
	seats := make([]int, 0, len(room.Votes))
	for seat, voters := range room.Votes {
		if len(voters) > 0 {
			seats = append(seats, seat)
		}
	}
	sort.Ints(seats)
	votes := make([]string, len(seats))
	for i, seat := range seats {
		votes[i] = fmt.Sprintf("%d:%d", seat, len(room.Votes[seat]))
	}
	return fmt.Sprintf("event|match|%s|%s|%d|%s|%d|%d|%s", room.Kind, room.Race.Track, room.Race.Laps,
		room.Race.Time, startIn, len(r.clients), strings.Join(votes, ","))
}

// dropVotes forgets the votes by and against a seat that has gone.
func (room *Room) dropVotes(slot int) {
	delete(room.Votes, slot)
	for target, voters := range room.Votes {
		delete(voters, slot)
		if len(voters) == 0 {
			delete(room.Votes, target)
		}
	}
}

// vote counts one driver's vote to remove another from a relay-made room. Two
// votes remove them, so in a room of two there's no vote: one person can't
// remove another. Callers hold the lock.
func (r *Relay) vote(voter *Client, parts []string) {
	room := voter.Room
	if room.Kind == "" || len(parts) < 3 {
		return
	}
	seat, err := strconv.Atoi(parts[2])
	if err != nil || seat < 1 || seat > maxRoomPlayers || seat == voter.Slot {
		return
	}
	target := room.Seats[seat-1]
	if target == nil || len(room.members()) < votesNeeded+1 {
		return
	}
	if room.Votes == nil {
		room.Votes = make(map[int]map[int]bool)
	}
	if room.Votes[seat] == nil {
		room.Votes[seat] = make(map[int]bool)
	}
	if room.Votes[seat][voter.Slot] {
		return
	}
	room.Votes[seat][voter.Slot] = true
	if len(room.Votes[seat]) < votesNeeded {
		r.announce(room)
		return
	}

	targetIP := target.Addr.IP.String()
	until := r.now().Add(keptApart)
	for slot := range room.Votes[seat] {
		other := room.Seats[slot-1]
		// Two on one address can't be kept apart without keeping that address
		// from every room it's in.
		if other == nil || other.Addr.IP.String() == targetIP {
			continue
		}
		key := pairOf(other.Addr.IP.String(), targetIP)
		if _, found := r.avoid[key]; !found && len(r.avoid) >= maxRateEntries {
			for k := range r.avoid {
				delete(r.avoid, k)
				break
			}
		}
		r.avoid[key] = until
	}
	r.coolDown(targetIP)
	r.event("[VOTED OUT] %v from room %q (%d votes)", target.Addr, room.Code, len(room.Votes[seat]))
	r.send([]byte("event|closed|"+votedOut), target.Addr)
	r.remove(target)
}

// coolDown keeps ip from queueing for 2 minutes, doubled for each time it was
// voted out that day, up to an hour.
func (r *Relay) coolDown(ip string) {
	now := r.now()
	c, found := r.cooldown[ip]
	if !found && len(r.cooldown) >= maxRateEntries {
		for k := range r.cooldown {
			delete(r.cooldown, k)
			break
		}
	}
	if c.Day != dayOf(now) {
		c = coolDown{Day: dayOf(now)}
	}
	c.Count++
	wait := maxCooldown
	if c.Count <= 6 {
		wait = min(voteCooldown<<(c.Count-1), maxCooldown)
	}
	c.Until = now.Add(wait)
	r.cooldown[ip] = c
}

// sweepMatches runs with the sweep. Rooms past their fill time stop taking
// drivers, and one that still hasn't started a minute later is closed: its
// leader isn't going to. Old cooldowns and pairs kept apart are forgotten.
// Callers hold the lock.
func (r *Relay) sweepMatches() {
	now := r.now()
	var filled, stuck []*Room
	for _, list := range r.filling {
		for _, room := range list {
			if !room.FillBy.IsZero() && !now.Before(room.FillBy) {
				filled = append(filled, room)
			}
		}
	}
	for _, room := range filled {
		r.unfill(room)
	}
	for _, room := range r.rooms {
		if room.Kind != "" && !room.Locked && !room.FillBy.IsZero() && now.Sub(room.FillBy) > unstartedLife {
			stuck = append(stuck, room)
		}
	}
	for _, room := range stuck {
		r.event("[CLOSE] room %q never started", room.Code)
		r.closeRoom(room, notStarted)
	}
	for key, until := range r.avoid {
		if !now.Before(until) {
			delete(r.avoid, key)
		}
	}
	today := dayOf(now)
	for ip, c := range r.cooldown {
		if c.Day != today && !now.Before(c.Until) {
			delete(r.cooldown, ip)
		}
	}
}
