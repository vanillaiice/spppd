package main

import (
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

// ask sends a protocol 5 request, padded as the game pads it.
func ask(relay *Relay, intent, code, cookie, token string, from *net.UDPAddr) {
	text := fmt.Sprintf("event|%s|5|%s|%s|%s|", intent, code, cookie, token)
	if len(text) < minRegisterBytes {
		text += strings.Repeat(".", minRegisterBytes-len(text))
	}
	relay.Handle([]byte(text), from)
}

// lastTo is the newest packet one address received, or "".
func lastTo(sent *[]packet, to *net.UDPAddr) string {
	for i := len(*sent) - 1; i >= 0; i-- {
		if (*sent)[i].to == to.String() {
			return (*sent)[i].data
		}
	}
	return ""
}

// lastRoom is the newest room update one address received, split into fields.
func lastRoom(sent *[]packet, to *net.UDPAddr) []string {
	for i := len(*sent) - 1; i >= 0; i-- {
		if p := (*sent)[i]; p.to == to.String() && strings.HasPrefix(p.data, "event|room|") {
			return strings.Split(p.data, "|")
		}
	}
	return nil
}

// enter does what the game does: ask, take the cookie, ask again. It returns the
// room as the relay told it, split into its fields.
func enter(t *testing.T, relay *Relay, sent *[]packet, intent, code, token string, from *net.UDPAddr) []string {
	t.Helper()
	ask(relay, intent, code, "", token, from)
	cookie, found := strings.CutPrefix(lastTo(sent, from), "event|cookie|")
	if !found {
		t.Fatalf("expected a cookie, got %q", lastTo(sent, from))
	}
	ask(relay, intent, code, cookie, token, from)
	return strings.Split(lastTo(sent, from), "|")
}

func TestASeatNeedsTheCookie(t *testing.T) {
	relay, sent, _ := setup()
	from := addrAt("198.51.100.4", 4000)
	ask(relay, "host", "ABC234", "", "", from)
	if len(relay.clients) != 0 || len(relay.rooms) != 0 {
		t.Fatalf("a request without a cookie took a seat")
	}
	reply := lastTo(sent, from)
	if !strings.HasPrefix(reply, "event|cookie|") || len(reply) > minRegisterBytes {
		t.Fatalf("got %q", reply)
	}
	room := enter(t, relay, sent, "host", "ABC234", "", from)
	if len(room) != 8 || room[1] != "room" || room[2] != "1" || room[3] != "ABC234" || room[4] != "1" || room[5] != "0" {
		t.Fatalf("got %v", room)
	}
	if len(room[6]) < 20 || room[7] != "" {
		t.Fatalf("expected a token and nobody away, got %v", room)
	}
}

func TestAShortRequestGetsNoAnswer(t *testing.T) {
	relay, sent, _ := setup()
	relay.Handle([]byte("event|host|5|ABC234||"), addr(1))
	if len(*sent) != 0 {
		t.Fatalf("a request smaller than the answer was answered: %v", *sent)
	}
}

func TestACookieOnlyWorksForItsOwnAddress(t *testing.T) {
	relay, sent, _ := setup()
	mine, theirs := addrAt("198.51.100.4", 4000), addrAt("203.0.113.9", 4000)
	ask(relay, "host", "ABC234", "", "", mine)
	cookie := strings.TrimPrefix(lastTo(sent, mine), "event|cookie|")
	ask(relay, "host", "ABC234", cookie, "", theirs)
	if len(relay.clients) != 0 {
		t.Fatalf("someone else's cookie took a seat")
	}
	if !strings.HasPrefix(lastTo(sent, theirs), "event|cookie|") {
		t.Fatalf("expected a fresh cookie, got %q", lastTo(sent, theirs))
	}
}

func TestACookieRunsOut(t *testing.T) {
	relay, sent, now := setup()
	from := addr(1)
	ask(relay, "host", "ABC234", "", "", from)
	cookie := strings.TrimPrefix(lastTo(sent, from), "event|cookie|")
	*now = now.Add(cookieWindow * time.Second)
	ask(relay, "host", "ABC234", cookie, "", from)
	if len(relay.clients) != 1 {
		t.Fatalf("a cookie from the window before should still work")
	}
	relay.remove(relay.clients[from.String()])
	*now = now.Add(2 * cookieWindow * time.Second)
	ask(relay, "host", "ABC234", cookie, "", from)
	if len(relay.clients) != 0 {
		t.Fatalf("an old cookie took a seat")
	}
}

// The attack from the review: forged hosts can no longer fill the server.
func TestForgedHostsCannotFillTheServer(t *testing.T) {
	relay, sent, _ := setup()
	relay.maxPlayers = 10
	for i := range 100 {
		ask(relay, "host", fmt.Sprintf("F%05d", i), "", "", addrAt(fmt.Sprintf("10.0.%d.%d", i/250, i%250+1), 1))
	}
	if len(relay.clients) != 0 {
		t.Fatalf("forged hosts hold %d seats", len(relay.clients))
	}
	real := addrAt("198.51.100.7", 1)
	if room := enter(t, relay, sent, "host", "REAL01", "", real); room[1] != "room" {
		t.Fatalf("a real host got %v", room)
	}
}

func TestOldGamesCanBeToldToUpdate(t *testing.T) {
	relay, sent, _ := setup()
	host(relay, "ABCD", 1)
	if len(relay.clients) != 1 {
		t.Fatalf("protocol 2 should still work by default")
	}
	relay.minProto = cookieProto
	host(relay, "WXYZ", 2)
	if got := last(sent).data; got != "event|error|"+outOfDate {
		t.Fatalf("got %q", got)
	}
	if room := enter(t, relay, sent, "host", "NEW234", "", addr(3)); room[1] != "room" {
		t.Fatalf("got %v", room)
	}
}

// pair5 seats a host and a joiner and returns their tokens.
func pair5(t *testing.T, relay *Relay, sent *[]packet) (string, string) {
	t.Helper()
	a := enter(t, relay, sent, "host", "ABC234", "", addr(1))
	b := enter(t, relay, sent, "join", "ABC234", "", addr(2))
	return a[6], b[6]
}

func TestASeatCanBeTakenBackFromANewAddress(t *testing.T) {
	relay, sent, _ := setup()
	_, token := pair5(t, relay, sent)
	relay.Handle([]byte("event|lock|"), addr(1))

	moved := addrAt("203.0.113.50", 6000)
	room := enter(t, relay, sent, "back", "ABC234", token, moved)
	if room[1] != "room" || room[2] != "2" || room[4] != "1,2" {
		t.Fatalf("got %v", room)
	}
	if relay.clients[addr(2).String()] != nil || relay.clients[moved.String()] == nil {
		t.Fatalf("the seat should have moved: %v", relay.clients)
	}
	if relay.perIP["127.0.0.1"] != 1 || relay.perIP["203.0.113.50"] != 1 {
		t.Fatalf("per IP %v", relay.perIP)
	}
	relay.Handle([]byte("sync|1"), addr(1))
	if got := lastTo(sent, moved); got != "1|sync|1" {
		t.Fatalf("the race should reach the new address, got %q", got)
	}
	relay.Handle([]byte("sync|2"), moved)
	if got := lastTo(sent, addr(1)); got != "2|sync|2" {
		t.Fatalf("and come from it as the same seat, got %q", got)
	}
}

func TestOnlyTheRightTokenTakesASeatBack(t *testing.T) {
	relay, sent, _ := setup()
	hostToken, _ := pair5(t, relay, sent)
	thief := addrAt("203.0.113.66", 1)
	for _, token := range []string{"", "nonsense", hostToken[:len(hostToken)-1] + "x"} {
		enter(t, relay, sent, "back", "ABC234", token, thief)
		if got := lastTo(sent, thief); got != "event|error|Your place in that room has gone" {
			t.Fatalf("token %q got %q", token, got)
		}
	}
	enter(t, relay, sent, "back", "OTHER1", hostToken, thief)
	if relay.clients[thief.String()] != nil {
		t.Fatalf("a token works in its own room only")
	}
}

func TestOldGamesCannotComeBack(t *testing.T) {
	relay, sent, _ := setup()
	pair(relay)
	n := len(*sent)
	relay.Handle([]byte("event|back|2|ABCD"), addr(3))
	if len(*sent) != n || len(relay.clients) != 2 {
		t.Fatalf("got %v", (*sent)[n:])
	}
	if !strings.HasSuffix(sentTo(sent, 1)[0], "|1|0") {
		t.Fatalf("an old game's room has no token: %q", sentTo(sent, 1)[0])
	}
}

func TestADriverWhoGoesQuietIsAwayBeforeTheyAreGone(t *testing.T) {
	relay, sent, now := setup()
	_, token := pair5(t, relay, sent)
	for range 6 {
		*now = now.Add(time.Second)
		relay.Handle([]byte("hello|1"), addr(1))
		relay.Sweep(5*time.Second, 60*time.Second)
	}
	room := lastRoom(sent, addr(1))
	if room[4] != "1,2" || room[7] != "2" {
		t.Fatalf("seat 2 should be away and still seated: %v", room)
	}
	n := len(sentTo(sent, 2))
	relay.Handle([]byte("sync|1"), addr(1))
	if len(sentTo(sent, 2)) != n {
		t.Fatalf("nothing should be sent to a driver who's away")
	}
	if snap := relay.Snapshot(); !snap.Rooms[0].Drivers[1].Away {
		t.Fatalf("the dashboard should show it: %+v", snap.Rooms[0].Drivers)
	}

	// Coming back from the same address needs no token.
	relay.Handle([]byte("hello|2"), addr(2))
	room = lastRoom(sent, addr(1))
	if room[7] != "" || relay.clients[addr(2).String()].Away {
		t.Fatalf("seat 2 should be back: %v", room)
	}

	// Away for good.
	for range 36 {
		*now = now.Add(time.Second)
		relay.Handle([]byte("hello|1"), addr(1))
		relay.Sweep(5*time.Second, 60*time.Second)
	}
	if room := lastRoom(sent, addr(1)); room[4] != "1" {
		t.Fatalf("seat 2 should be gone after the wait: %v", room)
	}
	enter(t, relay, sent, "back", "ABC234", token, addr(9))
	if got := lastTo(sent, addr(9)); got != "event|error|Your place in that room has gone" {
		t.Fatalf("got %q", got)
	}
}

func TestAnOldGameIsStillDroppedAtTheRaceTimeout(t *testing.T) {
	relay, sent, now := setup()
	pair(relay)
	*now = now.Add(6 * time.Second)
	relay.Handle([]byte("hello|1"), addr(1))
	relay.Sweep(5*time.Second, 60*time.Second)
	if got := lastTo(sent, addr(1)); got != "event|room|1|ABCD|1|0" {
		t.Fatalf("got %q", got)
	}
}

func TestComingBackIsCounted(t *testing.T) {
	relay, sent, _ := setup()
	relay.EnableAnalytics([]byte("key"))
	_, token := pair5(t, relay, sent)
	enter(t, relay, sent, "back", "ABC234", token, addr(7))
	if relay.tally.Backs != 1 {
		t.Fatalf("backs %d", relay.tally.Backs)
	}
}
