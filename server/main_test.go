package main

import (
	"net"
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
