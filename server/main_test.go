package main

import (
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

type packet struct {
	data string
	to   string
}

func setup() (*Relay, *[]packet, *time.Time) {
	sent := &[]packet{}
	now := time.Unix(1000, 0)
	relay := NewRelay(func(data []byte, to *net.UDPAddr) {
		*sent = append(*sent, packet{string(data), to.String()})
	})
	relay.now = func() time.Time { return now }
	return relay, sent, &now
}

func addr(port int) *net.UDPAddr {
	return &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port}
}

func last(sent *[]packet) packet {
	return (*sent)[len(*sent)-1]
}

func host(relay *Relay, code string, port int) {
	relay.Handle([]byte("event|host|2|"+code), addr(port))
}

func join(relay *Relay, code string, port int) {
	relay.Handle([]byte("event|join|2|"+code), addr(port))
}

func pair(relay *Relay) {
	host(relay, "ABCD", 1)
	join(relay, "ABCD", 2)
}

// sentTo lists what one address received.
func sentTo(sent *[]packet, port int) []string {
	var out []string
	for _, p := range *sent {
		if p.to == addr(port).String() {
			out = append(out, p.data)
		}
	}
	return out
}

func TestHostIsAcknowledged(t *testing.T) {
	relay, sent, _ := setup()
	host(relay, "ABCD", 1)
	if got := last(sent).data; got != "event|room|1|ABCD|1|0" {
		t.Fatalf("got %q", got)
	}
}

func TestLostAcknowledgementIsResent(t *testing.T) {
	relay, sent, _ := setup()
	host(relay, "ABCD", 1)
	host(relay, "ABCD", 1)
	if len(*sent) != 2 || last(sent).data != "event|room|1|ABCD|1|0" {
		t.Fatalf("expected a repeat ack, got %v", *sent)
	}
}

func TestJoinTellsEveryone(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	if got := sentTo(sent, 1); got[len(got)-1] != "event|room|1|ABCD|1,2|0" {
		t.Fatalf("host not told: %v", got)
	}
	if got := sentTo(sent, 2); len(got) != 1 || got[0] != "event|room|2|ABCD|1,2|0" {
		t.Fatalf("joiner not told: %v", got)
	}
}

func TestFourDriversFitAndAFifthDoesNot(t *testing.T) {
	relay, sent, _ := setup()
	host(relay, "ABCD", 1)
	for port := 2; port <= 4; port++ {
		join(relay, "ABCD", port)
	}
	if got := sentTo(sent, 4); got[len(got)-1] != "event|room|4|ABCD|1,2,3,4|0" {
		t.Fatalf("got %v", got)
	}
	join(relay, "ABCD", 5)
	if last(sent).data != "event|error|That room is full" || relay.clients[addr(5).String()] != nil {
		t.Fatalf("got %v", last(sent))
	}
}

func TestLockedRoomTakesNobody(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	relay.Handle([]byte("event|lock|"), addr(1))
	join(relay, "ABCD", 3)
	if last(sent).data != "event|error|That race has already started" {
		t.Fatalf("got %v", last(sent))
	}
}

func TestJoinWithBadCodeFails(t *testing.T) {
	relay, sent, _ := setup()
	join(relay, "NOPE", 2)
	if last(sent).data != "event|error|No room with that code" {
		t.Fatalf("got %v", last(sent))
	}
	if len(relay.clients) != 0 {
		t.Fatalf("failed joiner must not be registered")
	}
}

func TestDuplicateRoomIsRefused(t *testing.T) {
	relay, sent, _ := setup()
	host(relay, "ABCD", 1)
	host(relay, "ABCD", 2)
	if last(sent).data != "event|error|That room code is taken" {
		t.Fatalf("got %v", last(sent))
	}
}

func TestBadCodesAreRefused(t *testing.T) {
	relay, sent, _ := setup()
	for _, code := range []string{"", "12345678901234567", "AB|CD", "<script>"} {
		host(relay, code, 1)
	}
	if len(relay.rooms) != 0 || len(*sent) != 4 {
		t.Fatalf("rooms %v sent %v", relay.rooms, *sent)
	}
}

func TestOldClientsAreToldToUpdate(t *testing.T) {
	relay, sent, _ := setup()
	relay.Handle([]byte("event|host|ABCD"), addr(1))
	if last(sent).data != "event|error|This game is out of date. Update it to play online" || len(relay.rooms) != 0 {
		t.Fatalf("got %v", *sent)
	}
}

func TestDifferentVersionsCannotShareARoom(t *testing.T) {
	relay, sent, _ := setup()
	host(relay, "ABCD", 1)
	relay.Handle([]byte("event|join|3|ABCD"), addr(2))
	if last(sent).data != "event|error|That room is on a different version of the game" {
		t.Fatalf("got %v", last(sent))
	}
}

func TestPacketsGoToTheRestOfTheRoomStamped(t *testing.T) {
	relay, sent, _ := setup()
	host(relay, "ABCD", 1)
	join(relay, "ABCD", 2)
	join(relay, "ABCD", 3)
	n := len(*sent)
	relay.Handle([]byte("sync|1|2|3"), addr(2))
	got := (*sent)[n:]
	if len(got) != 2 {
		t.Fatalf("got %v", got)
	}
	for i, port := range []int{1, 3} {
		if got[i].data != "2|sync|1|2|3" || got[i].to != addr(port).String() {
			t.Fatalf("got %v", got[i])
		}
	}
}

func TestAClientCannotPassOffAnEventAsARelayMessage(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	n := len(*sent)
	relay.Handle([]byte("event|closed|gotcha"), addr(2))
	if len(*sent) != n {
		t.Fatalf("forwarded %v", (*sent)[n:])
	}
}

func TestStrangersAreIgnored(t *testing.T) {
	relay, sent, _ := setup()
	relay.Handle([]byte("sync|1|2|3"), addr(9))
	relay.Handle([]byte("garbage"), addr(9))
	if len(*sent) != 0 {
		t.Fatalf("got %v", *sent)
	}
}

func TestLeavingARaceTellsTheOthers(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	join(relay, "ABCD", 3)
	relay.Handle([]byte("event|lock|"), addr(1))
	relay.Handle([]byte("event|leave|"), addr(2))
	if p := last(sent); p.data != "event|room|3|ABCD|1,3|1" || p.to != addr(3).String() {
		t.Fatalf("got %v", p)
	}
	if len(relay.clients) != 2 {
		t.Fatalf("the others should stay: %v", relay.clients)
	}
}

func TestARaceGoesOnWithoutItsHost(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	relay.Handle([]byte("event|lock|"), addr(1))
	relay.Handle([]byte("event|leave|"), addr(1))
	if p := last(sent); p.data != "event|room|2|ABCD|2|1" {
		t.Fatalf("got %v", p)
	}
}

func TestALobbyClosesWithoutItsHost(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	relay.Handle([]byte("event|leave|"), addr(1))
	if p := last(sent); p.data != "event|closed|The host left the room" || p.to != addr(2).String() {
		t.Fatalf("got %v", p)
	}
	if len(relay.clients) != 0 || len(relay.rooms) != 0 {
		t.Fatalf("clients %v rooms %v", relay.clients, relay.rooms)
	}
}

func TestLastOneOutFreesTheCode(t *testing.T) {
	relay, _, _ := setup()
	pair(relay)
	relay.Handle([]byte("event|lock|"), addr(1))
	relay.Handle([]byte("event|leave|"), addr(1))
	relay.Handle([]byte("event|leave|"), addr(2))
	if len(relay.rooms) != 0 {
		t.Fatalf("rooms %v", relay.rooms)
	}
}

func TestSweepDropsASilentDriverAndTellsTheOthers(t *testing.T) {
	relay, sent, now := setup()
	pair(relay)
	relay.Handle([]byte("event|lock|"), addr(1))
	*now = now.Add(3 * time.Second)
	relay.Handle([]byte("sync|1"), addr(1))
	*now = now.Add(3 * time.Second)
	relay.Sweep(5*time.Second, 60*time.Second)
	if p := last(sent); p.data != "event|room|1|ABCD|1|1" || p.to != addr(1).String() {
		t.Fatalf("got %v", p)
	}
}

func TestSweepRepeatsTheRoom(t *testing.T) {
	relay, sent, _ := setup()
	host(relay, "ABCD", 1)
	n := len(*sent)
	relay.Sweep(5*time.Second, 60*time.Second)
	if len(*sent) != n+1 || last(sent).data != "event|room|1|ABCD|1|0" {
		t.Fatalf("got %v", (*sent)[n:])
	}
}

func TestSweepKeepsWaitingHost(t *testing.T) {
	relay, _, now := setup()
	host(relay, "ABCD", 1)
	*now = now.Add(30 * time.Second)
	relay.Sweep(5*time.Second, 60*time.Second)
	if len(relay.rooms) != 1 {
		t.Fatalf("host should still be waiting")
	}
	*now = now.Add(31 * time.Second)
	relay.Sweep(5*time.Second, 60*time.Second)
	if len(relay.rooms) != 0 || len(relay.clients) != 0 {
		t.Fatalf("host should have timed out")
	}
}

func TestOneIPCannotFloodTheRelay(t *testing.T) {
	relay, sent, now := setup()
	relay.rate = 10
	pair(relay)
	n := len(*sent)
	for i := 0; i < 100; i++ {
		relay.Handle([]byte("sync|1"), addr(1))
	}
	// Twenty tokens to start with, two of them spent pairing.
	if got := len(*sent) - n; got != 18 {
		t.Fatalf("forwarded %d", got)
	}
	if got := relay.Snapshot().Dropped; got != 82 {
		t.Fatalf("dropped %d", got)
	}
	*now = now.Add(time.Second)
	n = len(*sent)
	relay.Handle([]byte("sync|1"), addr(1))
	if len(*sent) != n+1 {
		t.Fatalf("the limit should refill")
	}
}

func TestRateBucketsDoNotPileUp(t *testing.T) {
	relay, _, now := setup()
	relay.Handle([]byte("garbage"), addrAt("203.0.113.7", 1))
	if len(relay.buckets) != 1 {
		t.Fatalf("buckets %v", relay.buckets)
	}
	*now = now.Add(11 * time.Second)
	relay.Sweep(5*time.Second, 60*time.Second)
	if len(relay.buckets) != 0 {
		t.Fatalf("buckets %v", relay.buckets)
	}
}

func TestOversizedPacketsAreDropped(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	n := len(*sent)
	relay.Handle(make([]byte, maxPacketBytes+1), addr(1))
	if len(*sent) != n || relay.Snapshot().Dropped != 1 {
		t.Fatalf("sent %v", (*sent)[n:])
	}
}

func TestOneIPCannotFillTheRelay(t *testing.T) {
	relay, sent, _ := setup()
	for i := 0; i < maxPerIP; i++ {
		host(relay, fmt.Sprintf("ROOM%d", i), i+1)
	}
	host(relay, "ONEMORE", 100)
	if last(sent).data != "event|error|Too many connections from your address" || len(relay.rooms) != maxPerIP {
		t.Fatalf("got %v, %d rooms", last(sent), len(relay.rooms))
	}
	relay.Handle([]byte("event|leave|"), addr(1))
	host(relay, "ONEMORE", 100)
	if relay.rooms["ONEMORE"] == nil {
		t.Fatalf("a freed place should be usable")
	}
}

func TestTheRelayHasACeiling(t *testing.T) {
	relay, sent, _ := setup()
	relay.maxPlayers = 1
	host(relay, "ABCD", 1)
	host(relay, "WXYZ", 2)
	if last(sent).data != "event|error|The server is full" {
		t.Fatalf("got %v", last(sent))
	}
}

func TestShutdownTellsEveryone(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	relay.Shutdown()
	for _, port := range []int{1, 2} {
		got := sentTo(sent, port)
		if got[len(got)-1] != "event|closed|The server is restarting" {
			t.Fatalf("got %v", got)
		}
	}
	if len(relay.clients) != 0 || len(relay.rooms) != 0 {
		t.Fatalf("clients %v rooms %v", relay.clients, relay.rooms)
	}
}

func addrAt(ip string, port int) *net.UDPAddr {
	return &net.UDPAddr{IP: net.ParseIP(ip), Port: port}
}

func TestTrafficIsCountedBothWays(t *testing.T) {
	relay, _, _ := setup()
	host(relay, "ABCD", 1) // 17 bytes in, 21 out
	snap := relay.Snapshot()
	if snap.Total.PacketsIn != 1 || snap.Total.BytesIn != 17 {
		t.Fatalf("in: %+v", snap.Total)
	}
	if snap.Total.PacketsOut != 1 || snap.Total.BytesOut != 21 {
		t.Fatalf("out: %+v", snap.Total)
	}
}

func TestSweepWorksOutRates(t *testing.T) {
	relay, _, _ := setup()
	relay.Handle([]byte("garbage"), addr(9))
	relay.Handle([]byte("garbage"), addr(9))
	relay.Sweep(5*time.Second, 60*time.Second)
	if got := relay.Snapshot().Rate.PacketsIn; got != 2 {
		t.Fatalf("got %d packets a second", got)
	}
	relay.Sweep(5*time.Second, 60*time.Second)
	if got := relay.Snapshot().Rate.PacketsIn; got != 0 {
		t.Fatalf("a quiet second should read 0, got %d", got)
	}
}

func TestSnapshotListsRoomsAndRaces(t *testing.T) {
	relay, _, now := setup()
	pair(relay)
	relay.Handle([]byte("event|lock|"), addr(1))
	*now = now.Add(5 * time.Second)
	host(relay, "WXYZ", 3)
	*now = now.Add(2 * time.Second)

	snap := relay.Snapshot()
	if snap.Players != 3 {
		t.Fatalf("players: %d", snap.Players)
	}
	if len(snap.Rooms) != 1 || snap.Rooms[0].Code != "WXYZ" || snap.Rooms[0].Age != 2*time.Second {
		t.Fatalf("rooms: %+v", snap.Rooms)
	}
	if len(snap.Races) != 1 || snap.Races[0].Code != "ABCD" || snap.Races[0].Age != 7*time.Second {
		t.Fatalf("races: %+v", snap.Races)
	}
	if len(snap.Races[0].Drivers) != 2 || snap.Races[0].Drivers[1].Slot != 2 {
		t.Fatalf("drivers: %+v", snap.Races[0].Drivers)
	}
}

func TestSnapshotDoesNotShareEvents(t *testing.T) {
	relay, _, _ := setup()
	host(relay, "ABCD", 1)
	join(relay, "NOPE", 2)
	snap := relay.Snapshot()
	if len(snap.Events) != 2 || snap.Events[0].Text != "[REFUSED] 127.0.0.1:2: No room with that code" {
		t.Fatalf("newest should come first: %+v", snap.Events)
	}
	snap.Events[0].Text = "changed"
	if relay.events[1].Text == "changed" {
		t.Fatalf("a snapshot must be a copy")
	}
}

func TestEventsStayWithinTheLimit(t *testing.T) {
	relay, _, _ := setup()
	for i := 0; i < maxEvents+25; i++ {
		join(relay, "NOPE", i+1)
	}
	events := relay.Snapshot().Events
	if len(events) != maxEvents {
		t.Fatalf("kept %d events", len(events))
	}
	want := "[REFUSED] 127.0.0.1:225: No room with that code"
	if events[0].Text != want {
		t.Fatalf("newest event lost: %q", events[0].Text)
	}
}

func TestCloseTellsEveryDriver(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	if !relay.Close(addr(1).String()) {
		t.Fatalf("close should find the client")
	}
	for _, port := range []int{1, 2} {
		got := sentTo(sent, port)
		if got[len(got)-1] != "event|closed|Room closed by the server" {
			t.Fatalf("got %v", got)
		}
	}
	if len(relay.clients) != 0 || len(relay.rooms) != 0 {
		t.Fatalf("both should be gone: %v", relay.clients)
	}
}

func TestCloseFreesAWaitingRoom(t *testing.T) {
	relay, sent, _ := setup()
	host(relay, "ABCD", 1)
	relay.Close(addr(1).String())
	if last(sent).data != "event|closed|Room closed by the server" || len(relay.rooms) != 0 {
		t.Fatalf("sent %v rooms %v", *sent, relay.rooms)
	}
	if relay.Close(addr(1).String()) {
		t.Fatalf("a second close has nothing to find")
	}
}

func TestBanRemovesClientsAndIgnoresThem(t *testing.T) {
	relay, sent, _ := setup()
	bad := addrAt("203.0.113.7", 1)
	relay.Handle([]byte("event|host|2|ABCD"), bad)
	host(relay, "WXYZ", 2)

	if !relay.Ban("203.0.113.7") {
		t.Fatalf("ban should accept an IP")
	}
	if len(relay.rooms) != 1 || relay.rooms["WXYZ"] == nil {
		t.Fatalf("only the banned room should go: %v", relay.rooms)
	}
	if p := last(sent); p.data != "event|closed|Removed by the server" || p.to != bad.String() {
		t.Fatalf("got %v", p)
	}

	n := len(*sent)
	relay.Handle([]byte("event|host|2|ABCD"), addrAt("203.0.113.7", 2)) // any port
	if len(*sent) != n || len(relay.rooms) != 1 {
		t.Fatalf("a banned IP must get no answer: %v", *sent)
	}
	if got := relay.Snapshot().Total.PacketsIn; got != 3 {
		t.Fatalf("banned packets still count as traffic, got %d", got)
	}

	relay.Unban("203.0.113.7")
	relay.Handle([]byte("event|host|2|ABCD"), bad)
	if relay.rooms["ABCD"] == nil {
		t.Fatalf("unbanned IP should work again")
	}
}

func TestBanRemovesBothDriversFromOneIP(t *testing.T) {
	relay, _, _ := setup()
	pair(relay)
	relay.Ban("127.0.0.1")
	if len(relay.clients) != 0 {
		t.Fatalf("left behind: %v", relay.clients)
	}
}

func TestBanRefusesNonsense(t *testing.T) {
	relay, _, _ := setup()
	if relay.Ban("not an ip") || len(relay.banned) != 0 {
		t.Fatalf("banned %v", relay.banned)
	}
}

func TestABanLeavesTheOthersRacing(t *testing.T) {
	relay, sent, _ := setup()
	relay.Handle([]byte("event|host|2|ABCD"), addrAt("198.51.100.1", 1))
	relay.Handle([]byte("event|join|2|ABCD"), addrAt("198.51.100.2", 1))
	relay.Handle([]byte("event|lock|"), addrAt("198.51.100.1", 1))
	relay.Ban("198.51.100.2")
	if p := last(sent); p.data != "event|room|1|ABCD|1|1" {
		t.Fatalf("got %v", p)
	}
}

func TestStragglersAfterARaceGetNoAnswer(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	relay.Handle([]byte("event|lock|"), addr(1))
	relay.Handle([]byte("event|leave|"), addr(1))
	relay.Handle([]byte("event|leave|"), addr(2))
	n := len(*sent)
	relay.Handle([]byte("event|leave|"), addr(2))
	relay.Handle([]byte("hello|rocket|2|1|0|0"), addr(2))
	if len(*sent) != n {
		t.Fatalf("stragglers need no answer: %v", (*sent)[n:])
	}
	for _, event := range relay.Snapshot().Events {
		if strings.HasPrefix(event.Text, "[REFUSED]") {
			t.Fatalf("a normal goodbye was logged as refused: %q", event.Text)
		}
	}
}
