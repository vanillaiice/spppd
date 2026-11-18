package main

import (
	"strings"
	"testing"
)

func TestWebAddressFromTheFlags(t *testing.T) {
	cases := []struct {
		flagged, status string
		tracks          bool
		want            string
		fails           bool
	}{
		{"https://spppd.xyz/", "127.0.0.1:8081", true, "https://spppd.xyz", false},
		{"", ":8081", true, "http://:8081", false},
		{"", "0.0.0.0:9000", true, "http://:9000", false},
		{"", ":8081", false, "", false},
		{"http://192.168.1.5:8081", "", false, "http://192.168.1.5:8081", false},
		{"spppd.xyz", ":8081", true, "", true},
		{"https://a b", ":8081", true, "", true},
		{"https://x|y", ":8081", true, "", true},
		{"https://" + strings.Repeat("a", 120), ":8081", true, "", true},
		{"", "nope", true, "", true},
	}
	for _, c := range cases {
		got, err := webAddress(c.flagged, c.status, c.tracks)
		if (err != nil) != c.fails || got != c.want {
			t.Errorf("webAddress(%q, %q, %v) = %q, %v", c.flagged, c.status, c.tracks, got, err)
		}
	}
}

func TestTheRelayTellsGamesWhereTheWebSideIs(t *testing.T) {
	relay, sent, _ := setup()
	relay.web = "http://:8081"
	from := addrAt("198.51.100.4", 4000)
	ask := []byte("event|web|" + strings.Repeat(".", 60))
	relay.Handle(ask, from)
	if got := lastTo(sent, from); got != "event|web|http://:8081" {
		t.Fatalf("got %q", got)
	}
	if len(relay.clients) != 0 || len(relay.rooms) != 0 {
		t.Fatalf("asking took a seat")
	}

	relay.web = ""
	relay.Handle(ask, from)
	if got := lastTo(sent, from); got != "event|web|" {
		t.Fatalf("no track server should answer empty, got %q", got)
	}
}

func TestAShortWebAskGetsNoAnswer(t *testing.T) {
	relay, sent, _ := setup()
	relay.web = "https://spppd.xyz"
	relay.Handle([]byte("event|web|"), addr(1))
	long := "https://" + strings.Repeat("a", 100)
	relay.web = long
	relay.Handle([]byte("event|web|"+strings.Repeat(".", 60)), addr(2))
	if len(*sent) != 0 {
		t.Fatalf("an ask smaller than the answer was answered: %v", *sent)
	}
	relay.Handle([]byte("event|web|"+strings.Repeat(".", 150)), addr(3))
	if got := lastTo(sent, addr(3)); got != "event|web|"+long {
		t.Fatalf("a big enough ask should be answered, got %q", got)
	}
}
