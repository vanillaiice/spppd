package main

import (
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

func pair(relay *Relay) {
	relay.Handle([]byte("event|host|ABCD"), addr(1))
	relay.Handle([]byte("event|join|ABCD"), addr(2))
}

func TestHostIsAcknowledged(t *testing.T) {
	relay, sent, _ := setup()
	relay.Handle([]byte("event|host|ABCD"), addr(1))
	if got := last(sent).data; got != "event|hosting|ABCD" {
		t.Fatalf("got %q", got)
	}
}

func TestLostAcknowledgementIsResent(t *testing.T) {
	relay, sent, _ := setup()
	relay.Handle([]byte("event|host|ABCD"), addr(1))
	relay.Handle([]byte("event|host|ABCD"), addr(1))
	if len(*sent) != 2 || last(sent).data != "event|hosting|ABCD" {
		t.Fatalf("expected a repeat ack, got %v", *sent)
	}
}

func TestJoinPairsAndStartsBothSides(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	if len(*sent) != 3 {
		t.Fatalf("got %v", *sent)
	}
	if (*sent)[1].data != "event|start_race|host" || (*sent)[1].to != addr(1).String() {
		t.Fatalf("host not told: %v", (*sent)[1])
	}
	if (*sent)[2].data != "event|start_race|join" || (*sent)[2].to != addr(2).String() {
		t.Fatalf("joiner not told: %v", (*sent)[2])
	}
	if len(relay.rooms) != 0 {
		t.Fatalf("room should close once full")
	}
}

func TestJoinWithBadCodeFails(t *testing.T) {
	relay, sent, _ := setup()
	relay.Handle([]byte("event|join|NOPE"), addr(2))
	if last(sent).data != "event|error|No room with that code" {
		t.Fatalf("got %v", last(sent))
	}
	if len(relay.clients) != 0 {
		t.Fatalf("failed joiner must not be registered")
	}
}

func TestDuplicateRoomIsRefused(t *testing.T) {
	relay, sent, _ := setup()
	relay.Handle([]byte("event|host|ABCD"), addr(1))
	relay.Handle([]byte("event|host|ABCD"), addr(2))
	if last(sent).data != "event|error|That room code is taken" {
		t.Fatalf("got %v", last(sent))
	}
}

func TestBadCodesAreRefused(t *testing.T) {
	relay, sent, _ := setup()
	relay.Handle([]byte("event|host|"), addr(1))
	relay.Handle([]byte("event|host|12345678901234567"), addr(1))
	if len(relay.rooms) != 0 || len(*sent) != 2 {
		t.Fatalf("rooms %v sent %v", relay.rooms, *sent)
	}
}

func TestPacketsRelayBothWays(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	relay.Handle([]byte("sync|1|2|3"), addr(1))
	if p := last(sent); p.data != "sync|1|2|3" || p.to != addr(2).String() {
		t.Fatalf("got %v", p)
	}
	relay.Handle([]byte("sync|4|5|6"), addr(2))
	if p := last(sent); p.data != "sync|4|5|6" || p.to != addr(1).String() {
		t.Fatalf("got %v", p)
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

func TestLeaveTellsPartner(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	relay.Handle([]byte("event|leave|"), addr(2))
	if p := last(sent); p.data != "event|error|Opponent disconnected" || p.to != addr(1).String() {
		t.Fatalf("got %v", p)
	}
	if len(relay.clients) != 0 {
		t.Fatalf("both sides should be gone: %v", relay.clients)
	}
}

func TestSweepDropsSilentRacerAndWarnsPartner(t *testing.T) {
	relay, sent, now := setup()
	pair(relay)
	*now = now.Add(3 * time.Second)
	relay.Handle([]byte("sync|1"), addr(1))
	*now = now.Add(3 * time.Second)
	relay.Sweep(5*time.Second, 60*time.Second)
	if p := last(sent); p.data != "event|error|Opponent disconnected" || p.to != addr(1).String() {
		t.Fatalf("got %v", p)
	}
}

func TestSweepKeepsWaitingHost(t *testing.T) {
	relay, _, now := setup()
	relay.Handle([]byte("event|host|ABCD"), addr(1))
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

func TestDroppingOneClientLeavesAReusedRoomAlone(t *testing.T) {
	relay, _, _ := setup()
	pair(relay)
	relay.Handle([]byte("event|host|ABCD"), addr(3)) // code is free again
	relay.Handle([]byte("event|leave|"), addr(1))
	if relay.rooms["ABCD"] == nil {
		t.Fatalf("the new room must survive the old pair leaving")
	}
}

func addrAt(ip string, port int) *net.UDPAddr {
	return &net.UDPAddr{IP: net.ParseIP(ip), Port: port}
}

func TestTrafficIsCountedBothWays(t *testing.T) {
	relay, _, _ := setup()
	relay.Handle([]byte("event|host|ABCD"), addr(1)) // 15 bytes in, 18 out
	snap := relay.Snapshot()
	if snap.Total.PacketsIn != 1 || snap.Total.BytesIn != 15 {
		t.Fatalf("in: %+v", snap.Total)
	}
	if snap.Total.PacketsOut != 1 || snap.Total.BytesOut != 18 {
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
	*now = now.Add(5 * time.Second)
	relay.Handle([]byte("event|host|WXYZ"), addr(3))
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
}

func TestSnapshotDoesNotShareEvents(t *testing.T) {
	relay, _, _ := setup()
	relay.Handle([]byte("event|host|ABCD"), addr(1))
	relay.Handle([]byte("event|join|NOPE"), addr(2))
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
		relay.Handle([]byte("event|join|NOPE"), addr(i+1))
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

func TestCloseTellsBothDrivers(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	if !relay.Close(addr(1).String()) {
		t.Fatalf("close should find the client")
	}
	n := len(*sent)
	first, second := (*sent)[n-2], (*sent)[n-1]
	if first.data != "event|error|Room closed by the server" || first.to != addr(1).String() {
		t.Fatalf("got %v", first)
	}
	if second.data != "event|error|Opponent disconnected" || second.to != addr(2).String() {
		t.Fatalf("got %v", second)
	}
	if len(relay.clients) != 0 {
		t.Fatalf("both should be gone: %v", relay.clients)
	}
}

func TestCloseFreesAWaitingRoom(t *testing.T) {
	relay, sent, _ := setup()
	relay.Handle([]byte("event|host|ABCD"), addr(1))
	relay.Close(addr(1).String())
	if last(sent).data != "event|error|Room closed by the server" || len(relay.rooms) != 0 {
		t.Fatalf("sent %v rooms %v", *sent, relay.rooms)
	}
	if relay.Close(addr(1).String()) {
		t.Fatalf("a second close has nothing to find")
	}
}

func TestBanRemovesClientsAndIgnoresThem(t *testing.T) {
	relay, sent, _ := setup()
	bad := addrAt("203.0.113.7", 1)
	relay.Handle([]byte("event|host|ABCD"), bad)
	relay.Handle([]byte("event|host|WXYZ"), addr(2))

	if !relay.Ban("203.0.113.7") {
		t.Fatalf("ban should accept an IP")
	}
	if len(relay.rooms) != 1 || relay.rooms["WXYZ"] == nil {
		t.Fatalf("only the banned room should go: %v", relay.rooms)
	}
	if p := last(sent); p.data != "event|error|Room closed by the server" || p.to != bad.String() {
		t.Fatalf("got %v", p)
	}

	n := len(*sent)
	relay.Handle([]byte("event|host|ABCD"), addrAt("203.0.113.7", 2)) // any port
	if len(*sent) != n || len(relay.rooms) != 1 {
		t.Fatalf("a banned IP must get no answer: %v", *sent)
	}
	if got := relay.Snapshot().Total.PacketsIn; got != 3 {
		t.Fatalf("banned packets still count as traffic, got %d", got)
	}

	relay.Unban("203.0.113.7")
	relay.Handle([]byte("event|host|ABCD"), bad)
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

func TestLeavingAfterThePartnerLeftIsNotRefused(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	relay.Handle([]byte("event|leave|"), addr(1))
	n := len(*sent)
	relay.Handle([]byte("event|leave|"), addr(2))
	relay.Handle([]byte("event|hello|rocket|2|harbour|4|night|1"), addr(2))
	if len(*sent) != n {
		t.Fatalf("stragglers need no answer: %v", (*sent)[n:])
	}
	for _, event := range relay.Snapshot().Events {
		if strings.HasPrefix(event.Text, "[REFUSED]") {
			t.Fatalf("a normal goodbye was logged as refused: %q", event.Text)
		}
	}
}
