package main

import (
	"database/sql"
	"fmt"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// queueAsk sends a quick match request as a 3.1 game does, padded to the size the
// relay asks for.
func queueAsk(relay *Relay, mode string, features int, cookie string, from *net.UDPAddr) {
	text := fmt.Sprintf("event|queue|5||%s||%d|||%s||", cookie, features, mode)
	if len(text) < minRegisterBytes {
		text += strings.Repeat(".", minRegisterBytes-len(text))
	}
	relay.Handle([]byte(text), from)
}

// queueIn does what the game does to find a race: ask, take the cookie, ask again.
// It returns the last thing the relay said to it.
func queueIn(t *testing.T, relay *Relay, sent *[]packet, from *net.UDPAddr) string {
	t.Helper()
	queueAsk(relay, "quick", 1, "", from)
	cookie, found := strings.CutPrefix(lastTo(sent, from), "event|cookie|")
	if !found {
		t.Fatalf("expected a cookie, got %q", lastTo(sent, from))
	}
	queueAsk(relay, "quick", 1, cookie, from)
	return lastTo(sent, from)
}

// lastMatch is the newest match event one address received, split into fields:
// event, match, KIND, TRACK, LAPS, TIME, STARTIN, ONLINE, VOTES.
func lastMatch(sent *[]packet, to *net.UDPAddr) []string {
	for i := len(*sent) - 1; i >= 0; i-- {
		if p := (*sent)[i]; p.to == to.String() && strings.HasPrefix(p.data, "event|match|") {
			return strings.Split(p.data, "|")
		}
	}
	return nil
}

func driverAt(n int) *net.UDPAddr {
	return addrAt(fmt.Sprintf("198.51.100.%d", n), 4000+n)
}

// talk has each address send something, as a game does four times a second.
func talk(relay *Relay, from ...*net.UDPAddr) {
	for _, a := range from {
		relay.Handle([]byte("hello|tofu_runner|1|1|0|0|1"), a)
	}
}

func roomOf(relay *Relay, a *net.UDPAddr) *Room {
	if client := relay.clients[a.String()]; client != nil {
		return client.Room
	}
	return nil
}

func filling(relay *Relay, room *Room) bool {
	for _, other := range relay.filling[quickKind] {
		if other == room {
			return true
		}
	}
	return false
}

func TestQueuersShareARoomUntilItIsFull(t *testing.T) {
	relay, sent, now := setup()
	first := driverAt(1)
	queueIn(t, relay, sent, first)
	room := lastRoom(sent, first)
	if room == nil || room[2] != "1" || len(room[3]) != matchCodeLen {
		t.Fatalf("first queuer's room %v", room)
	}
	match := lastMatch(sent, first)
	if match == nil || match[2] != "quick" || match[6] != "-1" || match[7] != "1" {
		t.Fatalf("first queuer's match %v", match)
	}
	known := false
	for _, track := range matchTracks {
		known = known || (track.ID == match[3] && fmt.Sprint(track.Laps) == match[4])
	}
	if !known {
		t.Fatalf("the relay picked %v", match)
	}

	queueIn(t, relay, sent, driverAt(2))
	if got := lastMatch(sent, first); got[6] != "15" {
		t.Fatalf("the second driver should start the clock: %v", got)
	}
	*now = now.Add(5 * time.Second)
	talk(relay, driverAt(1), driverAt(2))
	queueIn(t, relay, sent, driverAt(3))
	if got := lastMatch(sent, first); got[6] != "10" {
		t.Fatalf("a third driver doesn't move the clock: %v", got)
	}
	queueIn(t, relay, sent, driverAt(4))
	if got := lastRoom(sent, first); got[4] != "1,2,3,4" {
		t.Fatalf("seats %v", got)
	}
	if got := lastMatch(sent, first); got[6] != "3" {
		t.Fatalf("a full grid should start soon: %v", got)
	}
	queueIn(t, relay, sent, driverAt(5))
	if other := lastRoom(sent, driverAt(5)); other[3] == room[3] || other[2] != "1" {
		t.Fatalf("a fifth driver should get a room of their own: %v", other)
	}
	if relay.Status().Looking != 5 {
		t.Fatalf("looking %+v", relay.Status())
	}
}

func TestTheMatchIsRepeatedWithTheRoom(t *testing.T) {
	relay, sent, _ := setup()
	queueIn(t, relay, sent, driverAt(1))
	*sent = nil
	relay.Sweep(5*time.Second, 60*time.Second)
	got := sentToAddr(sent, driverAt(1))
	if len(got) != 2 || !strings.HasPrefix(got[0], "event|room|") || !strings.HasPrefix(got[1], "event|match|") {
		t.Fatalf("the sweep sent %v", got)
	}
}

func sentToAddr(sent *[]packet, to *net.UDPAddr) []string {
	var out []string
	for _, p := range *sent {
		if p.to == to.String() {
			out = append(out, p.data)
		}
	}
	return out
}

func TestOnlyKnownRacesAndNewGamesMayQueue(t *testing.T) {
	relay, sent, _ := setup()
	from := driverAt(1)
	queueAsk(relay, "ranked", 1, "", from)
	cookie, _ := strings.CutPrefix(lastTo(sent, from), "event|cookie|")
	queueAsk(relay, "ranked", 1, cookie, from)
	if got := lastTo(sent, from); got != "event|error|This server doesn't have that kind of race" {
		t.Fatalf("got %q", got)
	}
	queueAsk(relay, "quick", 0, cookie, from)
	if got := lastTo(sent, from); got != "event|error|"+outOfDate {
		t.Fatalf("got %q", got)
	}
	if len(relay.clients) != 0 {
		t.Fatal("a refused queuer was seated")
	}
}

func TestAnOldGamesPaddingReadsAsNoFeatures(t *testing.T) {
	relay, sent, _ := setup()
	from := driverAt(1)
	enter(t, relay, sent, "host", "ABC234", "", from)
	if got := relay.clients[from.String()].Features; got != 0 {
		t.Fatalf("features %d", got)
	}
	parts := strings.SplitN("event|host|5|ABC234|c|t|2|||"+strings.Repeat(".", 20), "|", 12)
	if featuresOf(parts) != 2 || field(parts, 9) != "" || field(parts, 20) != "" {
		t.Fatalf("fields %q", parts)
	}
}

func TestAForgedQueuerGetsOneSmallAnswer(t *testing.T) {
	relay, sent, _ := setup()
	from := driverAt(1)
	queueAsk(relay, "quick", 1, "", from)
	if len(*sent) != 1 || len((*sent)[0].data) > minRegisterBytes || len(relay.clients) != 0 {
		t.Fatalf("sent %v", *sent)
	}
	// Short of the padding, nothing at all.
	relay.Handle([]byte("event|queue|5||||1|||quick||"), from)
	if len(*sent) != 1 {
		t.Fatalf("sent %v", *sent)
	}
}

func TestAQuickMatchCannotBeJoinedByCode(t *testing.T) {
	relay, sent, _ := setup()
	queueIn(t, relay, sent, driverAt(1))
	code := lastRoom(sent, driverAt(1))[3]
	if got := enter(t, relay, sent, "join", code, "", driverAt(2)); strings.Join(got, "|") != "event|error|That room is for quick match" {
		t.Fatalf("got %v", got)
	}
}

func TestLeavingWhileFillingClearsTheClockAndKeepsTheRoom(t *testing.T) {
	relay, sent, _ := setup()
	queueIn(t, relay, sent, driverAt(1))
	queueIn(t, relay, sent, driverAt(2))
	room := roomOf(relay, driverAt(1))
	relay.Handle([]byte("event|leave|"), driverAt(1))
	if relay.rooms[room.Code] != room || !room.FillBy.IsZero() || !filling(relay, room) {
		t.Fatalf("room %+v", room)
	}
	if got := lastMatch(sent, driverAt(2)); got[6] != "-1" {
		t.Fatalf("match %v", got)
	}
	// The next to queue joins the one still waiting.
	queueIn(t, relay, sent, driverAt(3))
	if roomOf(relay, driverAt(3)) != room {
		t.Fatal("the room still filling should take the next driver")
	}
}

func TestLockingOrFillingUpStopsTakingDrivers(t *testing.T) {
	relay, sent, now := setup()
	queueIn(t, relay, sent, driverAt(1))
	queueIn(t, relay, sent, driverAt(2))
	room := roomOf(relay, driverAt(1))
	relay.Handle([]byte("event|lock|"), driverAt(1))
	if filling(relay, room) {
		t.Fatal("a locked room is still filling")
	}

	queueIn(t, relay, sent, driverAt(3))
	queueIn(t, relay, sent, driverAt(4))
	other := roomOf(relay, driverAt(3))
	*now = now.Add(15 * time.Second)
	talk(relay, driverAt(3), driverAt(4))
	relay.Sweep(5*time.Second, 60*time.Second)
	if filling(relay, other) {
		t.Fatal("a room past its fill time is still filling")
	}
	queueIn(t, relay, sent, driverAt(5))
	if roomOf(relay, driverAt(5)) == other {
		t.Fatal("a room past its fill time took a driver")
	}
}

func TestARoomThatNeverStartsIsClosed(t *testing.T) {
	relay, sent, now := setup()
	queueIn(t, relay, sent, driverAt(1))
	queueIn(t, relay, sent, driverAt(2))
	code := roomOf(relay, driverAt(1)).Code
	for range 80 {
		*now = now.Add(time.Second)
		talk(relay, driverAt(1), driverAt(2))
		relay.Sweep(5*time.Second, 60*time.Second)
	}
	if relay.rooms[code] != nil {
		t.Fatal("the room is still open")
	}
	if got := lastTo(sent, driverAt(2)); got != "event|closed|"+notStarted {
		t.Fatalf("got %q", got)
	}
}

func TestAQuickMatchSurvivesARestart(t *testing.T) {
	relay, sent, _ := setup()
	queueIn(t, relay, sent, driverAt(1))
	queueIn(t, relay, sent, driverAt(2))
	room := roomOf(relay, driverAt(1))

	again, _, _ := setup()
	if rooms, drivers := again.RestoreRooms(relay.saveRooms()); rooms != 1 || drivers != 2 {
		t.Fatalf("restored %d rooms with %d drivers", rooms, drivers)
	}
	back := again.rooms[room.Code]
	if back == nil || back.Kind != quickKind || back.Race != room.Race || !back.FillBy.Equal(room.FillBy) ||
		!filling(again, back) || back.Seats[0].Features != 1 {
		t.Fatalf("room %+v", back)
	}
}

// Three drivers in a quick match, each on an address of their own.
func threeInARoom(t *testing.T, relay *Relay, sent *[]packet) *Room {
	t.Helper()
	for i := 1; i <= 3; i++ {
		queueIn(t, relay, sent, driverAt(i))
	}
	return roomOf(relay, driverAt(1))
}

func kick(relay *Relay, from *net.UDPAddr, seat int) {
	relay.Handle([]byte(fmt.Sprintf("event|kick|%d|", seat)), from)
}

func TestTwoVotesRemoveADriver(t *testing.T) {
	relay, sent, _ := setup()
	room := threeInARoom(t, relay, sent)
	kick(relay, driverAt(1), 3)
	if got := lastMatch(sent, driverAt(3)); got[8] != "3:1" {
		t.Fatalf("the target should see the vote: %v", got)
	}
	kick(relay, driverAt(1), 3) // a repeat counts once
	if room.Seats[2] == nil {
		t.Fatal("one driver removed another")
	}
	kick(relay, driverAt(2), 3)
	if room.Seats[2] != nil {
		t.Fatal("two votes should remove the driver")
	}
	if got := lastTo(sent, driverAt(3)); got != "event|closed|"+votedOut {
		t.Fatalf("got %q", got)
	}
	if got := lastRoom(sent, driverAt(1)); got[4] != "1,2" {
		t.Fatalf("the others should hear: %v", got)
	}
	if got := lastMatch(sent, driverAt(1)); got[8] != "" {
		t.Fatalf("votes against a seat that's gone: %v", got)
	}
}

func TestVotesOnlyCountFromTheRoomAgainstOthersInIt(t *testing.T) {
	relay, sent, _ := setup()
	queueIn(t, relay, sent, driverAt(1))
	queueIn(t, relay, sent, driverAt(2))
	room := roomOf(relay, driverAt(1))
	kick(relay, driverAt(1), 2)
	if room.Votes != nil {
		t.Fatal("a vote counted in a room of two")
	}
	queueIn(t, relay, sent, driverAt(3))
	kick(relay, driverAt(1), 1)
	kick(relay, driverAt(1), 4)
	kick(relay, driverAt(1), 9)
	kick(relay, driverAt(9), 2) // not in the room, so not even a client
	if len(room.Votes) != 0 {
		t.Fatalf("votes %v", room.Votes)
	}
	// Nor in a room someone hosted.
	enter(t, relay, sent, "host", "ABC234", "", driverAt(5))
	enter(t, relay, sent, "join", "ABC234", "", driverAt(6))
	enter(t, relay, sent, "join", "ABC234", "", driverAt(7))
	kick(relay, driverAt(5), 3)
	kick(relay, driverAt(6), 3)
	if roomOf(relay, driverAt(7)) == nil {
		t.Fatal("a vote removed someone from a hosted room")
	}
}

func TestAVotedOutDriverWaitsLongerEachTime(t *testing.T) {
	relay, sent, now := setup()
	threeInARoom(t, relay, sent)
	kick(relay, driverAt(1), 3)
	kick(relay, driverAt(2), 3)
	if wait := relay.coolingDown(driverAt(3).IP.String()); wait != 2*time.Minute {
		t.Fatalf("wait %v", wait)
	}
	if got := queueIn(t, relay, sent, driverAt(3)); got != "event|error|You can look for a race again in 2 minutes" {
		t.Fatalf("got %q", got)
	}
	relay.coolDown(driverAt(3).IP.String())
	if wait := relay.coolingDown(driverAt(3).IP.String()); wait != 4*time.Minute {
		t.Fatalf("wait %v", wait)
	}
	for range 10 {
		relay.coolDown(driverAt(3).IP.String())
	}
	if wait := relay.coolingDown(driverAt(3).IP.String()); wait != time.Hour {
		t.Fatalf("wait %v", wait)
	}
	*now = now.Add(time.Hour)
	queueIn(t, relay, sent, driverAt(3))
	if roomOf(relay, driverAt(3)) == nil {
		t.Fatal("the cooldown should be over")
	}
}

func TestVotersAndTheirTargetAreKeptApart(t *testing.T) {
	relay, sent, now := setup()
	room := threeInARoom(t, relay, sent)
	kick(relay, driverAt(1), 3)
	kick(relay, driverAt(2), 3)
	relay.Handle([]byte("event|lock|"), driverAt(1))

	// Driver 2 looks again, and so does driver 3 once they may.
	relay.Handle([]byte("event|leave|"), driverAt(2))
	queueIn(t, relay, sent, driverAt(2))
	*now = now.Add(2 * time.Minute)
	talk(relay, driverAt(2))
	queueIn(t, relay, sent, driverAt(3))
	if roomOf(relay, driverAt(3)) == roomOf(relay, driverAt(2)) || roomOf(relay, driverAt(3)) == room {
		t.Fatal("a voter and their target were matched again")
	}
	// Someone else can join either of them.
	queueIn(t, relay, sent, driverAt(4))
	if roomOf(relay, driverAt(4)) != roomOf(relay, driverAt(2)) {
		t.Fatal("a stranger should join the oldest room")
	}

	// Half an hour on, they can meet again.
	relay.Handle([]byte("event|leave|"), driverAt(3))
	relay.Handle([]byte("event|leave|"), driverAt(4))
	*now = now.Add(28 * time.Minute)
	talk(relay, driverAt(2))
	relay.Sweep(5*time.Second, time.Hour)
	if len(relay.avoid) != 0 {
		t.Fatalf("avoid %v", relay.avoid)
	}
	queueIn(t, relay, sent, driverAt(3))
	if roomOf(relay, driverAt(3)) != roomOf(relay, driverAt(2)) {
		t.Fatal("the pair should be matched again after 30 minutes")
	}
}

func TestDriversOnOneAddressAreNeverKeptApart(t *testing.T) {
	relay, sent, _ := setup()
	for port := 1; port <= 3; port++ {
		queueIn(t, relay, sent, addrAt("192.0.2.1", port))
	}
	kick(relay, addrAt("192.0.2.1", 1), 3)
	kick(relay, addrAt("192.0.2.1", 2), 3)
	if relay.clients[addrAt("192.0.2.1", 3).String()] != nil {
		t.Fatal("the vote should still remove them")
	}
	if len(relay.avoid) != 0 {
		t.Fatalf("an address was kept apart from itself: %v", relay.avoid)
	}
}

func TestQuickRacesAreCounted(t *testing.T) {
	relay, sent, _ := setup()
	relay.EnableAnalytics([]byte("key"))
	queueIn(t, relay, sent, driverAt(1))
	queueIn(t, relay, sent, driverAt(2))
	relay.Handle([]byte("event|lock|"), driverAt(1))
	relay.Handle([]byte("event|leave|"), driverAt(1))
	relay.Handle([]byte("event|leave|"), driverAt(2))
	tally := relay.tally
	if tally.QuickRaces != 1 || tally.Races != 1 || tally.Rooms != 1 || tally.Joins != 1 ||
		len(tally.Finished) != 1 || tally.Finished[0].Kind != quickKind {
		t.Fatalf("tally %+v", tally)
	}
}

// A database from 3.0's relay gains the quick match columns.
func TestAVersionTwoDatabaseGainsQuickMatch(t *testing.T) {
	path := filepath.Join(t.TempDir(), "v2.db")
	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE daily (day TEXT PRIMARY KEY,
		unique_ips INTEGER NOT NULL DEFAULT 0, rooms INTEGER NOT NULL DEFAULT 0,
		joins INTEGER NOT NULL DEFAULT 0, races INTEGER NOT NULL DEFAULT 0,
		racers INTEGER NOT NULL DEFAULT 0, refused INTEGER NOT NULL DEFAULT 0,
		peak_players INTEGER NOT NULL DEFAULT 0,
		bytes_in INTEGER NOT NULL DEFAULT 0, bytes_out INTEGER NOT NULL DEFAULT 0,
		backs INTEGER NOT NULL DEFAULT 0);
		CREATE TABLE races (id INTEGER PRIMARY KEY, started INTEGER NOT NULL, ended INTEGER NOT NULL,
		players INTEGER NOT NULL, proto TEXT NOT NULL);
		INSERT INTO races (started, ended, players, proto) VALUES (1000, 1090, 2, '5');
		PRAGMA user_version = 2;`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	tally := &Tally{Day: "2026-11-07", QuickRaces: 1, Finished: []RaceRecord{
		{Started: time.Unix(2000, 0), Ended: time.Unix(2100, 0), Players: 3, Proto: "5", Kind: quickKind}}}
	if err := store.WriteTally(tally); err != nil {
		t.Fatal(err)
	}
	days, err := store.Days(1)
	if err != nil || days[0].QuickRaces != 1 {
		t.Fatalf("days %+v err %v", days, err)
	}
	var out strings.Builder
	if err := store.ExportRaces(&out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 3 || !strings.HasSuffix(lines[1], ",5,") || !strings.HasSuffix(lines[2], ",5,quick") {
		t.Fatalf("races %q", lines)
	}
}
