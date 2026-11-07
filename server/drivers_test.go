package main

import (
	"encoding/base64"
	"fmt"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The same key, message and proof are in tests/test_account.lua, so the game's
// HMAC and the relay's can't drift apart.
func TestProofMatchesTheGamesVector(t *testing.T) {
	key := make([]byte, 16)
	for i := range key {
		key[i] = byte(i)
	}
	if got := base64.RawURLEncoding.EncodeToString(key); got != "AAECAwQFBgcICQoLDA0ODw" {
		t.Fatalf("key encodes as %q", got)
	}
	if got := proofOf(key, "host|AbCdEfGhIjKlMnOpQrStUv"); got != "gbQf53MRd0ygIfyg4uDLEd" {
		t.Fatalf("proof %q", got)
	}
}

func TestNames(t *testing.T) {
	for name, ok := range map[string]bool{
		"bob": true, "SPEED_DEMON": true, "a-1": true, "TWELVECHARSX": true,
		"ab": false, "THIRTEENCHARS": false, "has space": false, "pipe|": false, "comma,": false, "colon:": false,
		"admin": false, "Spppd": false, "DRIVER1042": false, "DRIVERX": true,
		"FUCKER": false, "f_u_c_k": false, "5H1T": false, "CLASSIC": true, "COCKPIT": true, "GRAPE": true, "TORPEDO": true,
	} {
		clean, err := cleanName(name)
		if (err == nil) != ok {
			t.Errorf("%q: got %v", name, err)
		}
		if err == nil && clean != strings.ToUpper(name) {
			t.Errorf("%q came back as %q", name, clean)
		}
	}
}

func newKey(n byte) ([]byte, string) {
	key := make([]byte, driverKeyBytes)
	for i := range key {
		key[i] = n + byte(i)
	}
	return key, base64.RawURLEncoding.EncodeToString(key)
}

// driverAsk sends a driver request as the game does, padded, taking a cookie
// first. It returns the relay's answer.
func driverAsk(t *testing.T, relay *Relay, sent *[]packet, from *net.UDPAddr, intent string, fields func(cookie string) []string) string {
	t.Helper()
	send := func(cookie string) {
		text := fmt.Sprintf("event|%s|5|%s|%s|", intent, cookie, strings.Join(fields(cookie), "|"))
		if len(text) < minRegisterBytes {
			text += strings.Repeat(".", minRegisterBytes-len(text))
		}
		relay.Handle([]byte(text), from)
	}
	send("")
	cookie, found := strings.CutPrefix(lastTo(sent, from), "event|cookie|")
	if !found {
		t.Fatalf("expected a cookie, got %q", lastTo(sent, from))
	}
	before := len(*sent)
	send(cookie)
	if len(*sent) == before {
		return ""
	}
	return lastTo(sent, from)
}

func signUp(t *testing.T, relay *Relay, sent *[]packet, from *net.UDPAddr, name string, key, recovery string) string {
	t.Helper()
	return driverAsk(t, relay, sent, from, "signup", func(string) []string { return []string{name, key, recovery, "Linux"} })
}

// act sends a request from a signed-in device, proven with its key.
func act(t *testing.T, relay *Relay, sent *[]packet, from *net.UDPAddr, intent string, id int, key []byte, extra ...string) string {
	t.Helper()
	return driverAsk(t, relay, sent, from, intent, func(cookie string) []string {
		return append([]string{fmt.Sprint(id), proofOf(key, intent+"|"+cookie)}, extra...)
	})
}

func TestSignUpGivesADriver(t *testing.T) {
	relay, sent, _ := setup()
	_, key := newKey(1)
	_, recovery := newKey(50)
	from := driverAt(1)
	if got := signUp(t, relay, sent, from, "speedy", key, recovery); got != "event|driver|1001|SPEEDY" {
		t.Fatalf("got %q", got)
	}
	// The answer was lost: asking again answers again, and makes nobody new.
	if got := signUp(t, relay, sent, from, "SPEEDY", key, recovery); got != "event|driver|1001|SPEEDY" {
		t.Fatalf("again: got %q", got)
	}
	if len(relay.accounts) != 1 {
		t.Fatalf("%d drivers", len(relay.accounts))
	}
	_, other := newKey(2)
	if got := signUp(t, relay, sent, driverAt(2), "Speedy", other, recovery); got != "event|denied|signup|That name is taken" {
		t.Fatalf("taken: got %q", got)
	}
	if got := signUp(t, relay, sent, driverAt(2), "admin", other, recovery); !strings.HasPrefix(got, "event|denied|signup|") {
		t.Fatalf("reserved: got %q", got)
	}
}

func TestSignUpsAreLimitedPerAddress(t *testing.T) {
	relay, sent, now := setup()
	from := driverAt(1)
	for i := range signupsPerHour {
		_, key := newKey(byte(i))
		if got := signUp(t, relay, sent, from, fmt.Sprintf("racer%d", i), key, key); !strings.HasPrefix(got, "event|driver|") {
			t.Fatalf("sign-up %d: %q", i, got)
		}
	}
	_, key := newKey(9)
	if got := signUp(t, relay, sent, from, "onemore", key, key); !strings.HasPrefix(got, "event|denied|signup|Too many") {
		t.Fatalf("got %q", got)
	}
	*now = now.Add(time.Hour)
	if got := signUp(t, relay, sent, from, "onemore", key, key); !strings.HasPrefix(got, "event|driver|") {
		t.Fatalf("an hour later: %q", got)
	}
}

func TestASignedInSeatShowsItsName(t *testing.T) {
	relay, sent, _ := setup()
	raw, key := newKey(1)
	_, recovery := newKey(50)
	signUp(t, relay, sent, driverAt(1), "speedy", key, recovery)

	// Host with the proof, join without one: only the host has a name.
	hostAt, joinAt := driverAt(1), driverAt(2)
	seatAsk := func(intent, code, cookie string, from *net.UDPAddr, account string, key []byte) {
		proof := ""
		if key != nil {
			proof = proofOf(key, intent+"|"+cookie)
		}
		text := fmt.Sprintf("event|%s|5|%s|%s||1|%s|%s|", intent, code, cookie, account, proof)
		text += strings.Repeat(".", max(0, minRegisterBytes-len(text)))
		relay.Handle([]byte(text), from)
	}
	seatAsk("host", "ROOM1", "", hostAt, "", nil)
	cookie := strings.TrimPrefix(lastTo(sent, hostAt), "event|cookie|")
	seatAsk("host", "ROOM1", cookie, hostAt, "1001", raw)
	enter(t, relay, sent, "join", "ROOM1", "", joinAt)
	room := lastRoom(sent, joinAt)
	if room[8] != "1:SPEEDY" {
		t.Fatalf("names %q in %v", room[8], room)
	}

	// A wrong proof just races without a name.
	other := driverAt(3)
	seatAsk("join", "ROOM1", "", other, "", nil)
	cookie = strings.TrimPrefix(lastTo(sent, other), "event|cookie|")
	wrong, _ := newKey(7)
	seatAsk("join", "ROOM1", cookie, other, "1001", wrong)
	if room := lastRoom(sent, other); room == nil || room[8] != "1:SPEEDY" {
		t.Fatalf("got %v", room)
	}
}

func TestProfileRenameAndSignOut(t *testing.T) {
	relay, sent, now := setup()
	raw, key := newKey(1)
	_, recovery := newKey(50)
	from := driverAt(1)
	signUp(t, relay, sent, from, "speedy", key, recovery)

	if got := act(t, relay, sent, from, "profile", 1001, raw); !strings.HasPrefix(got, "event|profile|SPEEDY|") ||
		!strings.HasSuffix(got, "|1|1001") {
		t.Fatalf("profile %q", got)
	}
	if got := act(t, relay, sent, from, "rename", 1001, raw, "zoomer"); got != "event|driver|1001|ZOOMER" {
		t.Fatalf("rename %q", got)
	}
	if got := act(t, relay, sent, from, "rename", 1001, raw, "zoomer2"); !strings.HasPrefix(got, "event|denied|rename|You can rename again in 30 days") {
		t.Fatalf("second rename %q", got)
	}
	*now = now.Add(renameEvery)
	if got := act(t, relay, sent, from, "rename", 1001, raw, "zoomer2"); got != "event|driver|1001|ZOOMER2" {
		t.Fatalf("a month later %q", got)
	}
	// The old name is free again.
	_, other := newKey(2)
	if got := signUp(t, relay, sent, driverAt(2), "speedy", other, other); !strings.HasPrefix(got, "event|driver|") {
		t.Fatalf("old name %q", got)
	}

	wrong, _ := newKey(9)
	if got := act(t, relay, sent, from, "profile", 1001, wrong); got != "event|signedout|1001" {
		t.Fatalf("wrong key %q", got)
	}
	if got := act(t, relay, sent, from, "signout", 1001, raw); got != "event|signedout|1001" {
		t.Fatalf("sign out %q", got)
	}
	if got := act(t, relay, sent, from, "profile", 1001, raw); got != "event|signedout|1001" {
		t.Fatalf("after sign-out %q", got)
	}
	if got := act(t, relay, sent, from, "profile", 4242, raw); got != "event|nodriver|4242" {
		t.Fatalf("nobody %q", got)
	}
}

func recoverAsk(t *testing.T, relay *Relay, sent *[]packet, from *net.UDPAddr, id int, recovery []byte, newKey string) string {
	return driverAsk(t, relay, sent, from, "recover", func(cookie string) []string {
		return []string{fmt.Sprint(id), newKey, "Android", proofOf(recovery, "recover|"+cookie+"|"+newKey)}
	})
}

func TestRecoveryAddsADevice(t *testing.T) {
	relay, sent, now := setup()
	_, key := newKey(1)
	recoveryRaw, recovery := newKey(50)
	signUp(t, relay, sent, driverAt(1), "speedy", key, recovery)

	phoneRaw, phone := newKey(2)
	if got := recoverAsk(t, relay, sent, driverAt(2), 1001, recoveryRaw, phone); got != "event|driver|1001|SPEEDY" {
		t.Fatalf("recover %q", got)
	}
	if got := act(t, relay, sent, driverAt(2), "profile", 1001, phoneRaw); !strings.HasSuffix(got, "|2|1001") {
		t.Fatalf("two devices: %q", got)
	}
	// A proof made for one key can't add another.
	_, sneaky := newKey(3)
	got := driverAsk(t, relay, sent, driverAt(3), "recover", func(cookie string) []string {
		return []string{"1001", sneaky, "Android", proofOf(recoveryRaw, "recover|"+cookie+"|"+phone)}
	})
	if got != "event|denied|recover|"+notRecovered {
		t.Fatalf("other key %q", got)
	}

	// Past ten devices, the one seen least recently goes: the first.
	for i := range maxDeviceKeys {
		*now = now.Add(25 * time.Hour)
		_, k := newKey(byte(100 + i))
		recoverAsk(t, relay, sent, driverAt(10+i), 1001, recoveryRaw, k)
	}
	account := relay.accounts[1001]
	if len(account.Keys) != maxDeviceKeys || hasKey(account, mustKey(key)) {
		t.Fatalf("%d keys, first still there: %v", len(account.Keys), hasKey(account, mustKey(key)))
	}
}

func mustKey(text string) []byte {
	key, _ := decodeKey(text)
	return key
}

func TestRecoveryTriesAreLimited(t *testing.T) {
	relay, sent, _ := setup()
	_, key := newKey(1)
	_, recovery := newKey(50)
	signUp(t, relay, sent, driverAt(1), "speedy", key, recovery)
	guess, _ := newKey(60)
	_, phone := newKey(2)
	for i := range recoversPerHour {
		if got := recoverAsk(t, relay, sent, driverAt(2), 1001, guess, phone); got != "event|denied|recover|"+notRecovered {
			t.Fatalf("try %d: %q", i, got)
		}
	}
	if got := recoverAsk(t, relay, sent, driverAt(2), 1001, guess, phone); !strings.HasPrefix(got, "event|denied|recover|Too many") {
		t.Fatalf("got %q", got)
	}
	// Another address is held back too: the driver has had its ten.
	if got := recoverAsk(t, relay, sent, driverAt(3), 1001, guess, phone); !strings.HasPrefix(got, "event|denied|recover|Too many") {
		t.Fatalf("other address %q", got)
	}
}

func TestDeletingADriver(t *testing.T) {
	relay, sent, _ := setup()
	raw, key := newKey(1)
	_, recovery := newKey(50)
	from := driverAt(1)
	signUp(t, relay, sent, from, "speedy", key, recovery)
	relay.mu.Lock()
	room := &Room{Code: "R", Proto: "5", Since: relay.now()}
	relay.rooms["R"] = room
	client := relay.seat(room, 1, driverAt(5), "tok")
	client.Account = relay.accounts[1001]
	relay.mu.Unlock()

	if got := act(t, relay, sent, from, "forget", 1001, raw); got != "event|nodriver|1001" {
		t.Fatalf("forget %q", got)
	}
	if len(relay.accounts) != 0 || len(relay.names) != 0 || client.Account != nil {
		t.Fatalf("driver still there")
	}
	if got := act(t, relay, sent, from, "forget", 1001, raw); got != "event|nodriver|1001" {
		t.Fatalf("asked again %q", got)
	}
}

func TestABannedDriverIsRefusedASeat(t *testing.T) {
	relay, sent, _ := setup()
	raw, key := newKey(1)
	signUp(t, relay, sent, driverAt(1), "speedy", key, key)
	relay.BanDriver(1001, true, "test")
	from := driverAt(2)
	text := func(cookie string) []byte {
		out := fmt.Sprintf("event|host|5|ROOM1|%s||1|1001|%s|", cookie, proofOf(raw, "host|"+cookie))
		return []byte(out + strings.Repeat(".", max(0, minRegisterBytes-len(out))))
	}
	relay.Handle(text(""), from)
	cookie := strings.TrimPrefix(lastTo(sent, from), "event|cookie|")
	relay.Handle(text(cookie), from)
	if got := lastTo(sent, from); got != "event|error|"+bannedDriver {
		t.Fatalf("got %q", got)
	}
	relay.BanDriver(1001, false, "test")
	relay.Handle(text(cookie), from)
	if room := lastRoom(sent, from); room == nil || room[8] != "1:SPEEDY" {
		t.Fatalf("after unban: %v", room)
	}
}

func TestTheDashboardCanResetAName(t *testing.T) {
	relay, sent, _ := setup()
	raw, key := newKey(1)
	from := driverAt(1)
	signUp(t, relay, sent, from, "speedy", key, key)
	if !relay.ResetDriverName(1001, "test") {
		t.Fatalf("not renamed")
	}
	if got := act(t, relay, sent, from, "profile", 1001, raw); !strings.HasPrefix(got, "event|profile|DRIVER1001|") {
		t.Fatalf("got %q", got)
	}
	// It didn't use up their own rename.
	if got := act(t, relay, sent, from, "rename", 1001, raw, "speedy2"); got != "event|driver|1001|SPEEDY2" {
		t.Fatalf("got %q", got)
	}
	views, total := relay.FindDrivers("speedy")
	if total != 1 || len(views) != 1 || views[0].Devices[0].Label != "Linux" {
		t.Fatalf("found %v of %d", views, total)
	}
}

func TestDriversOutliveARestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	relay, sent, _ := setup()
	stop, err := relay.KeepDrivers(store)
	if err != nil {
		t.Fatal(err)
	}
	raw, key := newKey(1)
	recoveryRaw, recovery := newKey(50)
	signUp(t, relay, sent, driverAt(1), "speedy", key, recovery)
	phoneRaw, phone := newKey(2)
	recoverAsk(t, relay, sent, driverAt(2), 1001, recoveryRaw, phone)
	act(t, relay, sent, driverAt(2), "rename", 1001, phoneRaw, "zoomer")
	act(t, relay, sent, driverAt(1), "signout", 1001, raw)
	_, other := newKey(3)
	signUp(t, relay, sent, driverAt(3), "gone", other, other)
	goneRaw, _ := newKey(3)
	act(t, relay, sent, driverAt(3), "forget", 1002, goneRaw)
	relay.BanDriver(1001, true, "test")
	stop()
	store.Close()

	store, err = OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	again, sent2, _ := setup()
	stop, err = again.KeepDrivers(store)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	account := again.accounts[1001]
	if len(again.accounts) != 1 || account == nil || account.Name != "ZOOMER" || !account.Banned || account.Renamed.IsZero() {
		t.Fatalf("got %+v", account)
	}
	if len(account.Keys) != 1 || !hasKey(account, phoneRaw) {
		t.Fatalf("keys %v", account.Keys)
	}
	// Numbers carry on from where they were, and the deleted one isn't reused.
	_, next := newKey(4)
	if got := signUp(t, again, sent2, driverAt(4), "newbie", next, next); got != "event|driver|1003|NEWBIE" {
		t.Fatalf("got %q", got)
	}
}

func TestAFullWriterDropsTheRequest(t *testing.T) {
	relay, sent, _ := setup()
	relay.driverWrites = make(chan func(*Store) error, 1)
	relay.driverWrites <- func(*Store) error { return nil }
	_, key := newKey(1)
	if got := signUp(t, relay, sent, driverAt(1), "speedy", key, key); got != "" {
		t.Fatalf("answered %q", got)
	}
	if len(relay.accounts) != 0 {
		t.Fatalf("made a driver it couldn't save")
	}
	<-relay.driverWrites
	if got := signUp(t, relay, sent, driverAt(1), "speedy", key, key); got != "event|driver|1001|SPEEDY" {
		t.Fatalf("got %q", got)
	}
}

func TestDriverNamesSurviveARestartOfTheRooms(t *testing.T) {
	relay, sent, _ := setup()
	raw, key := newKey(1)
	signUp(t, relay, sent, driverAt(1), "speedy", key, key)
	from := driverAt(2)
	text := func(cookie string) []byte {
		out := fmt.Sprintf("event|host|5|ROOM1|%s||1|1001|%s|", cookie, proofOf(raw, "host|"+cookie))
		return []byte(out + strings.Repeat(".", max(0, minRegisterBytes-len(out))))
	}
	relay.Handle(text(""), from)
	relay.Handle(text(strings.TrimPrefix(lastTo(sent, from), "event|cookie|")), from)
	saved := relay.saveRooms()

	again, _, _ := setup()
	again.mu.Lock()
	again.addAccount(relay.accounts[1001])
	again.mu.Unlock()
	again.RestoreRooms(saved)
	if names := again.rooms["ROOM1"].names(); names != "1:SPEEDY" {
		t.Fatalf("names %q", names)
	}
}
