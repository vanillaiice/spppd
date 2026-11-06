package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func tempStore(t *testing.T) *TempStore {
	t.Helper()
	temp, err := OpenTempStore(filepath.Join(t.TempDir(), "relay-temp.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { temp.Close() })
	return temp
}

// restart stops relay as main does, and starts another on the same file at the
// same moment plus after. It returns the new relay and what it sent.
func restart(t *testing.T, relay *Relay, temp *TempStore, stop func(), after time.Duration) (*Relay, *[]packet) {
	t.Helper()
	relay.Shutdown(true)
	stop()
	next, sent, now := setup()
	*now = relay.now().Add(after)
	if _, _, err := next.LoadTemp(temp, 35*time.Second); err != nil {
		t.Fatal(err)
	}
	return next, sent
}

func TestARaceGoesOnThroughARestart(t *testing.T) {
	relay, sent, _ := setup()
	temp := tempStore(t)
	stop := relay.KeepTemp(temp)
	_, token := pair5(t, relay, sent)
	relay.Handle([]byte("event|lock|"), addr(1))

	before := len(*sent)
	next, nextSent := restart(t, relay, temp, stop, 5*time.Second)
	for _, p := range (*sent)[before:] {
		if strings.HasPrefix(p.data, "event|closed|") {
			t.Fatalf("a protocol 5 driver was told the room closed: %v", p)
		}
	}

	room := next.rooms["ABC234"]
	if room == nil || !room.Locked || room.Racers != 2 || len(room.members()) != 2 {
		t.Fatalf("the room didn't come back as it was: %+v", room)
	}
	// A game whose address didn't change carries on.
	next.Handle([]byte("sync|1"), addr(1))
	if got := lastTo(nextSent, addr(2)); got != "1|sync|1" {
		t.Fatalf("the race should go on, got %q", got)
	}
	// One that moved takes its seat back with the token it already has.
	moved := addrAt("203.0.113.50", 6000)
	back := enter(t, next, nextSent, "back", "ABC234", token, moved)
	if back[1] != "room" || back[2] != "2" || back[4] != "1,2" {
		t.Fatalf("got %v", back)
	}
	if next.perIP["127.0.0.1"] != 1 || next.perIP["203.0.113.50"] != 1 {
		t.Fatalf("per IP %v", next.perIP)
	}
}

func TestOldGamesAreStillToldTheServerIsRestarting(t *testing.T) {
	relay, sent, _ := setup()
	temp := tempStore(t)
	stop := relay.KeepTemp(temp)
	pair(relay)

	next, _ := restart(t, relay, temp, stop, time.Second)
	for _, port := range []int{1, 2} {
		got := sentTo(sent, port)
		if got[len(got)-1] != "event|closed|The server is restarting" {
			t.Fatalf("port %d got %v", port, got)
		}
	}
	if len(next.rooms) != 0 {
		t.Fatalf("a room that can't be got back into was kept: %v", next.rooms)
	}
}

func TestRoomsFromLongAgoAreNotBroughtBack(t *testing.T) {
	relay, sent, _ := setup()
	temp := tempStore(t)
	stop := relay.KeepTemp(temp)
	pair5(t, relay, sent)

	next, _ := restart(t, relay, temp, stop, 36*time.Second)
	if len(next.rooms) != 0 || len(next.clients) != 0 {
		t.Fatalf("their games gave up on them by now: %v", next.rooms)
	}
}

func TestTheRoomsAreSavedWhileTheRelayRuns(t *testing.T) {
	relay, sent, _ := setup()
	temp := tempStore(t)
	stop := relay.KeepTemp(temp)
	defer stop()
	pair5(t, relay, sent)

	// A crash gets no last save, so the rooms must already be on disk.
	deadline := time.Now().Add(3 * roomsEvery)
	for {
		if _, data, _ := temp.Rooms(); strings.Contains(string(data), "ABC234") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the rooms were never saved")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestActivityOutlastsARestart(t *testing.T) {
	relay, sent, _ := setup()
	temp := tempStore(t)
	stop := relay.KeepTemp(temp)
	pair5(t, relay, sent)
	old := relay.Snapshot().Events

	next, _ := restart(t, relay, temp, stop, time.Second)
	got := next.Snapshot().Events
	if len(got) != len(old) || len(got) == 0 {
		t.Fatalf("got %d lines back, had %d", len(got), len(old))
	}
	for i := range old {
		if got[i].Seq != old[i].Seq || got[i].Text != old[i].Text || !got[i].At.Equal(old[i].At) {
			t.Fatalf("line %d: got %+v, had %+v", i, got[i], old[i])
		}
	}
	// New lines carry on from the old numbers, so an open dashboard adds them.
	next.Note("after")
	if latest := next.Snapshot().Events[0]; latest.Seq != old[0].Seq+1 {
		t.Fatalf("got seq %d after %d", latest.Seq, old[0].Seq)
	}
}

func TestCleanUpKeepsTheNewestLinesOfTheLastWeek(t *testing.T) {
	temp := tempStore(t)
	now := time.Unix(1_000_000, 0)
	lines := func(from, to int, at time.Time) []Event {
		var out []Event
		for i := from; i <= to; i++ {
			out = append(out, Event{Seq: uint64(i), At: at, Text: fmt.Sprintf("line %d", i)})
		}
		return out
	}
	kept := func() (count, oldest int) {
		temp.db.QueryRow(`SELECT COUNT(*), MIN(seq) FROM events`).Scan(&count, &oldest)
		return
	}

	// No more than the dashboard shows.
	temp.AddEvents(lines(1, maxEvents+50, now.Add(-time.Hour)))
	temp.CleanUp(now)
	if count, oldest := kept(); count != maxEvents || oldest != 51 {
		t.Fatalf("kept %d lines from %d", count, oldest)
	}

	// None from more than a week ago, and they aren't brought back meanwhile either.
	temp.AddEvents(lines(51, 100, now.Add(-8*24*time.Hour)))
	if back, _ := temp.Events(now); len(back) != maxEvents-50 || back[0].Seq != 101 {
		t.Fatalf("brought back %d lines from %d", len(back), back[0].Seq)
	}
	temp.CleanUp(now)
	if count, oldest := kept(); count != maxEvents-50 || oldest != 101 {
		t.Fatalf("kept %d lines from %d", count, oldest)
	}
}

func TestTheRelayNeverWaitsForTheDisk(t *testing.T) {
	relay, _, _ := setup()
	// A writer that has stopped reading.
	relay.tempEvents = make(chan Event)
	done := make(chan struct{})
	go func() {
		for i := range 500 {
			from := addrAt(fmt.Sprintf("10.0.%d.%d", i/250, i%250+1), 4000)
			relay.Handle([]byte(fmt.Sprintf("event|host|2|ROOM%d", i)), from)
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("the relay waited on the writer")
	}
	if relay.tempLost != 500 {
		t.Fatalf("expected 500 lines lost to the file, got %d", relay.tempLost)
	}
	if len(relay.rooms) != 500 {
		t.Fatalf("the relay should have gone on as usual: %d rooms", len(relay.rooms))
	}
}
