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

func TestRoomsHaveACeiling(t *testing.T) {
	relay, sent, _ := setup()
	relay.maxRooms = 2
	host(relay, "ABCD", 1)
	host(relay, "WXYZ", 2)
	relay.Handle([]byte("event|lock|"), addr(2)) // racing rooms count too
	host(relay, "FULL", 3)
	if last(sent).data != "event|error|The server has no free rooms. Try again soon" || relay.rooms["FULL"] != nil {
		t.Fatalf("got %v", last(sent))
	}
	// Joining an open room takes no new room.
	join(relay, "ABCD", 4)
	if relay.clients[addr(4).String()] == nil {
		t.Fatalf("a join was refused for the room limit")
	}
	relay.Handle([]byte("event|leave|"), addr(2))
	host(relay, "FULL", 3)
	if relay.rooms["FULL"] == nil {
		t.Fatalf("a closed room should free its place")
	}
}

func TestShutdownTellsEveryone(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	relay.Shutdown(false)
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
	relay.Sweep(5*time.Second, 60*time.Second)
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
	relay.rate = 0
	for i := 0; i < maxEvents+25; i++ {
		relay.Handle(fmt.Appendf(nil, "event|host|2|R%d", i), addrAt(fmt.Sprintf("198.51.100.%d", i%250+1), 1000+i))
	}
	events := relay.Snapshot().Events
	if len(events) != maxEvents {
		t.Fatalf("kept %d events", len(events))
	}
	if !strings.Contains(events[0].Text, fmt.Sprintf("%q", fmt.Sprintf("R%d", maxEvents+24))) {
		t.Fatalf("newest event lost: %q", events[0].Text)
	}
}

func TestRefusalsAreSummedUpEachSecond(t *testing.T) {
	relay, _, now := setup()
	relay.rate = 0
	host(relay, "ABCD", 1)
	for i := 0; i < 500; i++ {
		join(relay, "NOPE", 100+i)
	}
	host(relay, "ABCD", 9)
	if got := len(relay.Snapshot().Events); got != 1 {
		t.Fatalf("refusals should wait for the sweep, got %d lines", got)
	}
	*now = now.Add(time.Second)
	relay.Sweep(5*time.Second, 60*time.Second)
	events := relay.Snapshot().Events
	want := "[REFUSED] 501 times, last 127.0.0.1:9: No room with that code (500), That room code is taken (1)"
	if len(events) != 2 || events[0].Text != want {
		t.Fatalf("got %+v", events)
	}
	if !strings.Contains(events[1].Text, "[HOST]") {
		t.Fatalf("the flood pushed out what came before: %+v", events)
	}
	relay.Sweep(5*time.Second, 60*time.Second)
	if got := len(relay.Snapshot().Events); got != 2 {
		t.Fatalf("a quiet second adds nothing, got %d lines", got)
	}
}

// Forged sources filling the rate table mustn't shut new players out.
func TestAFullRateTableStillLetsNewcomersIn(t *testing.T) {
	relay, sent, _ := setup()
	for i := 0; i < maxRateEntries+100; i++ {
		ip := net.IPv4(10, byte(i>>16), byte(i>>8), byte(i))
		relay.Handle([]byte("x"), &net.UDPAddr{IP: ip, Port: 1})
	}
	if len(relay.buckets) > maxRateEntries {
		t.Fatalf("the table grew to %d", len(relay.buckets))
	}
	relay.Handle([]byte("event|host|2|REAL01"), addrAt("198.51.100.7", 1))
	if got := last(sent); got.to != "198.51.100.7:1" || !strings.HasPrefix(got.data, "event|room|1|REAL01") {
		t.Fatalf("a real host got %+v", got)
	}
}

// An address that sent one packet and went quiet gets nothing more, so a forged
// one can't turn the relay into a stream of packets at someone else.
func TestTheSweepOnlyAnswersThoseStillSending(t *testing.T) {
	relay, sent, now := setup()
	host(relay, "ABCD", 1)
	host(relay, "WXYZ", 2)
	for i := 0; i < 59; i++ {
		*now = now.Add(time.Second)
		relay.Handle([]byte("hello|still here"), addr(2))
		relay.Sweep(5*time.Second, 60*time.Second)
	}
	quiet, talking := len(sentTo(sent, 1)), len(sentTo(sent, 2))
	if quiet > 3 {
		t.Fatalf("a silent address got %d packets", quiet)
	}
	if talking < 59 {
		t.Fatalf("a client still sending should hear every second, got %d", talking)
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

	if !relay.Ban("203.0.113.7", "test") {
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
	relay.Ban("127.0.0.1", "test")
	if len(relay.clients) != 0 {
		t.Fatalf("left behind: %v", relay.clients)
	}
}

func TestBanRefusesNonsense(t *testing.T) {
	relay, _, _ := setup()
	if relay.Ban("not an ip", "test") || len(relay.banned) != 0 {
		t.Fatalf("banned %v", relay.banned)
	}
}

func TestABanLeavesTheOthersRacing(t *testing.T) {
	relay, sent, _ := setup()
	relay.Handle([]byte("event|host|2|ABCD"), addrAt("198.51.100.1", 1))
	relay.Handle([]byte("event|join|2|ABCD"), addrAt("198.51.100.2", 1))
	relay.Handle([]byte("event|lock|"), addrAt("198.51.100.1", 1))
	relay.Ban("198.51.100.2", "test")
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

func TestAProbeLeavesNoTrace(t *testing.T) {
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	relay := NewRelay(func(data []byte, to *net.UDPAddr) { _, _ = conn.WriteToUDP(data, to) })
	relay.EnableAnalytics([]byte("key"))
	go func() {
		buffer := make([]byte, maxPacketBytes+1)
		for {
			n, from, err := conn.ReadFromUDP(buffer)
			if err != nil {
				return
			}
			relay.Handle(buffer[:n], from)
		}
	}()
	if err := probe(conn.LocalAddr().String(), 2*time.Second); err != nil {
		t.Fatal(err)
	}
	relay.mu.Lock()
	defer relay.mu.Unlock()
	tally := relay.tally
	if len(tally.Visitors) != 0 || tally.Rooms != 0 || tally.Joins != 0 || tally.Refused != 0 {
		t.Errorf("the probe was counted: %+v", tally)
	}
	if len(relay.events) != 0 || len(relay.rooms) != 0 || len(relay.clients) != 0 {
		t.Errorf("the probe left %d events, %d rooms, %d clients", len(relay.events), len(relay.rooms), len(relay.clients))
	}
}

func TestAProbeOfNothingFails(t *testing.T) {
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	address := conn.LocalAddr().String()
	conn.Close()
	if err := probe(address, 600*time.Millisecond); err == nil {
		t.Error("a probe of a closed port passed")
	}
}
