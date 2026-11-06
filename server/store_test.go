package main

import (
	"bytes"
	"database/sql"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fileStore(t *testing.T, path string) *Store {
	t.Helper()
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func from(ip string, port int) *net.UDPAddr {
	return &net.UDPAddr{IP: net.ParseIP(ip), Port: port}
}

func TestBansSurviveARestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	store := fileStore(t, path)
	relay, _, _ := setup()
	if err := relay.AttachStore(store); err != nil {
		t.Fatal(err)
	}
	relay.Ban("203.0.113.7", "ana")
	relay.Ban("198.51.100.2", "ana")
	relay.Unban("198.51.100.2")
	store.Close()

	store = fileStore(t, path)
	defer store.Close()
	again, sent, _ := setup()
	if err := again.AttachStore(store); err != nil {
		t.Fatal(err)
	}
	again.Handle([]byte("event|host|2|ABCD"), from("203.0.113.7", 1))
	if len(*sent) != 0 || len(again.rooms) != 0 {
		t.Fatalf("a ban from before the restart was forgotten: %v", *sent)
	}
	snap := again.Snapshot()
	if len(snap.Banned) != 1 || snap.Banned[0].IP != "203.0.113.7" || snap.Banned[0].By != "ana" || snap.Banned[0].At.IsZero() {
		t.Fatalf("banned %+v", snap.Banned)
	}
}

func TestUsersAndPasswords(t *testing.T) {
	store := memoryStore(t)
	now := time.Unix(1000, 0)
	for _, name := range []string{"", "has space", "<b>", strings.Repeat("a", 33)} {
		if err := store.AddUser(name, "long enough", now); err != errBadName {
			t.Errorf("%q: %v", name, err)
		}
	}
	for _, password := range []string{"short", strings.Repeat("a", 73)} {
		if err := store.AddUser("ana", password, now); err != errBadPassword {
			t.Errorf("%d characters: %v", len(password), err)
		}
	}
	if store.HasUsers() {
		t.Fatal("a refused user was added")
	}
	if err := store.AddUser("ana", "long enough", now); err != nil {
		t.Fatal(err)
	}
	if err := store.AddUser("ana", "another one", now); err != errUserExists {
		t.Fatalf("got %v", err)
	}
	if !store.CheckPassword("ana", "long enough") || store.CheckPassword("ana", "long enougH") || store.CheckPassword("bo", "long enough") {
		t.Fatal("passwords checked wrong")
	}
	if err := store.SetPassword("bo", "long enough"); err != errNoUser {
		t.Fatalf("got %v", err)
	}
	if err := store.DeleteUser("bo"); err != errNoUser {
		t.Fatalf("got %v", err)
	}
}

func TestPasswordsAreNotKeptAsTheyAre(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	store := fileStore(t, path)
	if err := store.AddUser("ana", "correct horse", time.Now()); err != nil {
		t.Fatal(err)
	}
	token, _ := store.NewSession("ana", time.Now())
	store.Close()
	for _, suffix := range []string{"", "-wal"} {
		raw, _ := os.ReadFile(path + suffix)
		if bytes.Contains(raw, []byte("correct horse")) || bytes.Contains(raw, []byte(token)) {
			t.Fatalf("%s holds a password or token as it is", path+suffix)
		}
	}
}

func TestSessionsRunOut(t *testing.T) {
	store := memoryStore(t)
	now := time.Unix(1000, 0)
	if err := store.AddUser("ana", "correct horse", now); err != nil {
		t.Fatal(err)
	}
	token, err := store.NewSession("ana", now)
	if err != nil {
		t.Fatal(err)
	}
	if user, ok := store.SessionUser(token, now.Add(sessionLife-time.Second)); !ok || user != "ana" {
		t.Fatalf("got %q %v", user, ok)
	}
	if _, ok := store.SessionUser(token, now.Add(sessionLife)); ok {
		t.Fatal("an old login still works")
	}
	if _, ok := store.SessionUser("", now); ok {
		t.Fatal("no token is a login")
	}
	if err := store.Prune("1970-01-01", now.Add(sessionLife)); err != nil {
		t.Fatal(err)
	}
	var left int
	store.db.QueryRow(`SELECT COUNT(*) FROM sessions`).Scan(&left)
	if left != 0 {
		t.Fatalf("%d run-out sessions kept", left)
	}
}

func TestAnalyticsKeyIsKept(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	store := fileStore(t, path)
	first, err := store.AnalyticsKey()
	if err != nil || len(first) != 32 {
		t.Fatalf("%v %d", err, len(first))
	}
	store.Close()
	store = fileStore(t, path)
	defer store.Close()
	second, _ := store.AnalyticsKey()
	if !bytes.Equal(first, second) {
		t.Fatal("a new key would count everyone again")
	}
}

// The key stays out of the database, so a backup of it can't undo the hashes,
// and a key an older relay put there is moved out and wiped.
func TestAnalyticsKeyStaysOutOfTheDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	old := bytes.Repeat([]byte{0xA7, 0x5C}, 16)
	store := fileStore(t, path)
	if _, err := store.db.Exec(`INSERT INTO meta (key, value) VALUES ('analytics_key', ?)`, old); err != nil {
		t.Fatal(err)
	}
	store.Close()

	store = fileStore(t, path)
	key, err := store.AnalyticsKey()
	if err != nil || !bytes.Equal(key, old) {
		t.Fatalf("moving it out changed the key: %v", err)
	}
	var rows int
	store.db.QueryRow(`SELECT COUNT(*) FROM meta WHERE key = 'analytics_key'`).Scan(&rows)
	store.Close()
	if rows != 0 {
		t.Fatal("the key is still in the database")
	}
	info, err := os.Stat(path + ".key")
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("key file: %v %v", err, info)
	}
	for _, f := range []string{path, path + "-wal"} {
		if raw, err := os.ReadFile(f); err == nil && bytes.Contains(raw, old) {
			t.Fatalf("%s still holds the key's bytes", filepath.Base(f))
		}
	}

	store = fileStore(t, path)
	defer store.Close()
	if again, _ := store.AnalyticsKey(); !bytes.Equal(again, old) {
		t.Fatal("the key file wasn't read back")
	}
}

func analyticsRelay(t *testing.T) (*Relay, *Store, *time.Time) {
	t.Helper()
	relay, _, now := setup()
	store := memoryStore(t)
	if err := relay.AttachStore(store); err != nil {
		t.Fatal(err)
	}
	key, _ := store.AnalyticsKey()
	relay.EnableAnalytics(key)
	return relay, store, now
}

func TestAnalyticsOffCountsNothing(t *testing.T) {
	relay, _, _ := setup()
	store := memoryStore(t)
	relay.AttachStore(store)
	relay.Handle([]byte("event|host|2|ABCD"), from("203.0.113.7", 1))
	relay.Handle([]byte("event|lock|"), from("203.0.113.7", 1))
	relay.Sweep(5*time.Second, time.Minute)
	relay.FlushAnalytics()
	if relay.tally != nil {
		t.Fatal("counting with analytics off")
	}
	for _, table := range []string{"daily", "visitors", "races", "meta"} {
		var n int
		store.db.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&n)
		if n != 0 {
			t.Errorf("%s has %d rows", table, n)
		}
	}
}

func TestAnalyticsCountWhatHappens(t *testing.T) {
	relay, store, now := analyticsRelay(t)
	relay.Handle([]byte("event|host|2|ABCD"), from("203.0.113.7", 1))
	relay.Handle([]byte("event|join|2|ABCD"), from("198.51.100.2", 1))
	relay.Handle([]byte("event|join|2|ABCD"), from("198.51.100.2", 2)) // same IP, another device
	relay.Handle([]byte("event|join|2|NOPE"), from("192.0.2.9", 1))    // refused
	relay.Sweep(5*time.Second, time.Minute)
	relay.Handle([]byte("event|lock|"), from("203.0.113.7", 1))
	relay.Handle([]byte("event|lock|"), from("203.0.113.7", 1)) // said twice, counted once
	relay.FlushAnalytics()

	*now = now.Add(90 * time.Second)
	for _, port := range []int{1, 2} {
		relay.Handle([]byte("event|leave|"), from("198.51.100.2", port))
	}
	relay.Handle([]byte("event|leave|"), from("203.0.113.7", 1))
	relay.FlushAnalytics()

	days, _ := store.Days(14)
	if len(days) != 1 {
		t.Fatalf("days %+v", days)
	}
	d := days[0]
	if d.Day != "1970-01-01" || d.UniqueIPs != 3 || d.Rooms != 1 || d.Joins != 2 || d.Races != 1 || d.Racers != 3 || d.Refused != 1 || d.PeakPlayers != 3 {
		t.Fatalf("day %+v", d)
	}
	var out bytes.Buffer
	store.ExportRaces(&out)
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 || lines[1] != "1970-01-01T00:16:40Z,1970-01-01T00:18:10Z,90,3,2" {
		t.Fatalf("races %q", lines)
	}
	// Two writes in a day don't count someone twice.
	relay.Handle([]byte("event|host|2|WXYZ"), from("203.0.113.7", 1))
	relay.FlushAnalytics()
	if days, _ := store.Days(1); days[0].UniqueIPs != 3 || days[0].Rooms != 2 {
		t.Fatalf("day %+v", days[0])
	}
}

func TestAnalyticsNeverHoldAnIP(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	store := fileStore(t, path)
	relay, _, _ := setup()
	relay.AttachStore(store)
	key, _ := store.AnalyticsKey()
	relay.EnableAnalytics(key)
	relay.Handle([]byte("event|host|2|ABCD"), from("203.0.113.7", 1))
	relay.FlushAnalytics()
	store.Close()
	for _, suffix := range []string{"", "-wal"} {
		raw, _ := os.ReadFile(path + suffix)
		if bytes.Contains(raw, []byte("203.0.113.7")) || bytes.Contains(raw, net.ParseIP("203.0.113.7").To4()) {
			t.Fatalf("%s holds the IP", path+suffix)
		}
	}
}

func TestAnalyticsSplitAtMidnight(t *testing.T) {
	relay, _, now := setup()
	*now = time.Date(2026, 11, 3, 23, 59, 59, 0, time.UTC)
	store := memoryStore(t)
	relay.AttachStore(store)
	key, _ := store.AnalyticsKey()
	relay.EnableAnalytics(key)
	relay.Handle([]byte("event|host|2|ABCD"), from("203.0.113.7", 1))
	*now = now.Add(2 * time.Second)
	relay.Sweep(5*time.Second, time.Minute)
	relay.Handle([]byte("event|host|2|WXYZ"), from("198.51.100.2", 1))
	relay.FlushAnalytics()

	days, _ := store.Days(14)
	if len(days) != 2 || days[0].Day != "2026-11-04" || days[1].Day != "2026-11-03" || days[0].Rooms != 1 || days[1].Rooms != 1 {
		t.Fatalf("days %+v", days)
	}
	if days[0].PeakPlayers != 2 {
		t.Fatalf("whoever stayed past midnight still counts toward the new day's peak: %+v", days[0])
	}
	if n, _ := store.UniqueSince("2026-11-03"); n != 2 {
		t.Fatalf("unique %d", n)
	}
}

func TestPruneForgetsHashesButKeepsCounts(t *testing.T) {
	store := memoryStore(t)
	for i, day := range []string{"2026-10-01", "2026-11-01"} {
		tally := newTally(time.Now())
		tally.Day = day
		tally.Visitors[[32]byte{byte(i)}] = struct{}{}
		tally.Visitors[[32]byte{9}] = struct{}{}
		if err := store.WriteTally(tally); err != nil {
			t.Fatal(err)
		}
	}
	if n, _ := store.UniqueSince("2026-01-01"); n != 3 {
		t.Fatalf("unique %d", n)
	}
	if err := store.Prune("2026-10-15", time.Now()); err != nil {
		t.Fatal(err)
	}
	if n, _ := store.UniqueSince("2026-01-01"); n != 2 {
		t.Fatalf("old hashes kept: unique %d", n)
	}
	days, _ := store.Days(14)
	if len(days) != 2 || days[1].UniqueIPs != 2 {
		t.Fatalf("the old day's count should stay: %+v", days)
	}
}

func TestVisitorsAreCapped(t *testing.T) {
	relay, _, _ := analyticsRelay(t)
	relay.mu.Lock()
	defer relay.mu.Unlock()
	for i := 0; i < maxVisitors+10; i++ {
		relay.visit(net.IPv4(10, byte(i>>16), byte(i>>8), byte(i)).String())
	}
	if len(relay.tally.Visitors) != maxVisitors {
		t.Fatalf("%d visitors held", len(relay.tally.Visitors))
	}
}

func TestUserCommands(t *testing.T) {
	store := memoryStore(t)
	var out bytes.Buffer
	run := func(input string, args ...string) error {
		out.Reset()
		return userCommand(store, args, strings.NewReader(input), &out)
	}
	if err := run("correct horse\n", "user", "add", "ana"); err != nil || !store.CheckPassword("ana", "correct horse") {
		t.Fatalf("add: %v", err)
	}
	if err := run("", "user", "add", "bo"); err == nil {
		t.Fatal("added a user with no password")
	}
	token, _ := store.NewSession("ana", time.Now())
	if err := run("battery staple", "user", "passwd", "ana"); err != nil || !store.CheckPassword("ana", "battery staple") {
		t.Fatalf("passwd: %v", err)
	}
	if _, ok := store.SessionUser(token, time.Now()); ok {
		t.Fatal("a new password should end old logins")
	}
	if err := run("", "user", "list"); err != nil || !strings.HasPrefix(out.String(), "ana\tadded ") {
		t.Fatalf("list: %v %q", err, out.String())
	}
	if err := run("", "user", "del", "ana"); err != nil || store.HasUsers() {
		t.Fatalf("del: %v", err)
	}
	if err := run("", "user", "del", "ana"); err != errNoUser {
		t.Fatalf("del twice: %v", err)
	}
	if err := run("", "nonsense"); err == nil {
		t.Fatal("ran nonsense")
	}
}

// A database from before the backs column gets it, and keeps what it had.
func TestAnOlderDatabaseIsBroughtUpToDate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE daily (day TEXT PRIMARY KEY,
		unique_ips INTEGER NOT NULL DEFAULT 0, rooms INTEGER NOT NULL DEFAULT 0,
		joins INTEGER NOT NULL DEFAULT 0, races INTEGER NOT NULL DEFAULT 0,
		racers INTEGER NOT NULL DEFAULT 0, refused INTEGER NOT NULL DEFAULT 0,
		peak_players INTEGER NOT NULL DEFAULT 0,
		bytes_in INTEGER NOT NULL DEFAULT 0, bytes_out INTEGER NOT NULL DEFAULT 0);
		INSERT INTO daily (day, rooms) VALUES ('2026-11-01', 7);
		PRAGMA user_version = 1;`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	for range 2 {
		store, err := OpenStore(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := store.WriteTally(&Tally{Day: "2026-11-01", Backs: 2}); err != nil {
			t.Fatal(err)
		}
		days, err := store.Days(5)
		store.Close()
		if err != nil || len(days) != 1 || days[0].Rooms != 7 || days[0].Backs == 0 {
			t.Fatalf("days %+v err %v", days, err)
		}
	}
}
