package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"time"

	"golang.org/x/crypto/bcrypt"
	_ "modernc.org/sqlite"
)

// sessionLife is how long a dashboard login lasts.
const sessionLife = 7 * 24 * time.Hour

var (
	errUserExists  = errors.New("that name is taken")
	errNoUser      = errors.New("no user with that name")
	errBadName     = errors.New("names are 1 to 32 letters, numbers, dots, dashes or underscores")
	errBadPassword = errors.New("passwords are 8 to 72 characters")
	validName      = regexp.MustCompile(`^[A-Za-z0-9._-]{1,32}$`)
)

const schema = `
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS bans (
	ip TEXT PRIMARY KEY, at INTEGER NOT NULL, by TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS users (
	name TEXT PRIMARY KEY, hash TEXT NOT NULL, created INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sessions (
	token BLOB PRIMARY KEY,
	user TEXT NOT NULL REFERENCES users(name) ON DELETE CASCADE,
	expires INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS daily (
	day TEXT PRIMARY KEY,
	unique_ips INTEGER NOT NULL DEFAULT 0, rooms INTEGER NOT NULL DEFAULT 0,
	joins INTEGER NOT NULL DEFAULT 0, races INTEGER NOT NULL DEFAULT 0,
	racers INTEGER NOT NULL DEFAULT 0, refused INTEGER NOT NULL DEFAULT 0,
	peak_players INTEGER NOT NULL DEFAULT 0,
	bytes_in INTEGER NOT NULL DEFAULT 0, bytes_out INTEGER NOT NULL DEFAULT 0,
	backs INTEGER NOT NULL DEFAULT 0, quick_races INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS visitors (
	day TEXT NOT NULL, ip_hash BLOB NOT NULL, PRIMARY KEY (day, ip_hash)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS races (
	id INTEGER PRIMARY KEY, started INTEGER NOT NULL, ended INTEGER NOT NULL,
	players INTEGER NOT NULL, proto TEXT NOT NULL, kind TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS drivers (
	id INTEGER PRIMARY KEY AUTOINCREMENT, -- so a deleted driver's number is never given again
	name TEXT NOT NULL UNIQUE,      -- in capitals, so unique ignoring case
	recovery BLOB NOT NULL,         -- the recovery key
	created INTEGER NOT NULL,
	seen TEXT NOT NULL,             -- the day of the last sign-in, not the time
	renamed INTEGER NOT NULL DEFAULT 0,
	banned INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS driver_keys (
	id INTEGER PRIMARY KEY,
	driver INTEGER NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
	key BLOB NOT NULL,              -- a device key
	label TEXT NOT NULL,            -- "Android", "Linux"…
	added TEXT NOT NULL,            -- days, not times
	seen TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS driver_keys_driver ON driver_keys (driver);
`

// migrate brings a database from an older relay up to date. Each step checks
// for itself, so running it twice does nothing.
func migrate(db *sql.DB) error {
	columns := []struct{ table, name, def string }{
		{"daily", "backs", "INTEGER NOT NULL DEFAULT 0"},
		{"daily", "quick_races", "INTEGER NOT NULL DEFAULT 0"},
		{"races", "kind", "TEXT NOT NULL DEFAULT ''"},
		{"daily", "signups", "INTEGER NOT NULL DEFAULT 0"},
	}
	for _, c := range columns {
		var found int
		if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?`, c.table, c.name).Scan(&found); err != nil {
			return err
		}
		if found == 0 {
			if _, err := db.Exec(`ALTER TABLE ` + c.table + ` ADD COLUMN ` + c.name + ` ` + c.def); err != nil {
				return err
			}
		}
	}
	_, err := db.Exec(`PRAGMA user_version = 4`)
	return err
}

// Store keeps what has to outlive a restart: bans, dashboard users and their
// logins, and analytics when they're on. It's one SQLite file, or memory.
type Store struct {
	db    *sql.DB
	path  string // the database file, or "" in memory
	cost  int    // bcrypt cost; tests turn it down
	dummy []byte // compared against when a name doesn't exist, so timing doesn't tell
	key   []byte // the analytics key, once read
}

// OpenStore opens the database at path, creating it if needed. An empty path keeps
// everything in memory, gone at exit.
func OpenStore(path string) (*Store, error) {
	name, params := ":memory:", "_pragma=foreign_keys(1)&_pragma=temp_store(MEMORY)"
	if path != "" {
		name = "file:" + path
		params += "&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)"
	}
	db, err := sql.Open("sqlite", name+"?"+params)
	if err != nil {
		return nil, err
	}
	// One connection: SQLite takes one writer anyway, and each in-memory
	// connection would be a database of its own.
	db.SetMaxOpenConns(1)
	db.SetConnMaxLifetime(0)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("setting up %s: %w", path, err)
	}
	if err := migrate(db); err != nil {
		db.Close()
		return nil, fmt.Errorf("updating %s: %w", path, err)
	}
	s := &Store{db: db, path: path, cost: bcrypt.DefaultCost}
	s.dummy, _ = bcrypt.GenerateFromPassword([]byte("not a real password"), s.cost)
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

// Bans -----------------------------------------------------------------------

// Ban is a banned IP, when, and who did it.
type Ban struct {
	IP string
	At time.Time
	By string
}

func (s *Store) Bans() ([]Ban, error) {
	rows, err := s.db.Query(`SELECT ip, at, by FROM bans ORDER BY ip`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Ban
	for rows.Next() {
		var b Ban
		var at int64
		if err := rows.Scan(&b.IP, &at, &b.By); err != nil {
			return nil, err
		}
		b.At = time.Unix(at, 0)
		out = append(out, b)
	}
	return out, rows.Err()
}

func (s *Store) SaveBan(b Ban) error {
	_, err := s.db.Exec(`INSERT OR REPLACE INTO bans (ip, at, by) VALUES (?, ?, ?)`, b.IP, b.At.Unix(), b.By)
	return err
}

func (s *Store) DeleteBan(ip string) error {
	_, err := s.db.Exec(`DELETE FROM bans WHERE ip = ?`, ip)
	return err
}

// Users and sessions -----------------------------------------------------------

type User struct {
	Name    string
	Created time.Time
}

func checkPasswordRules(password string) error {
	if len(password) < 8 || len(password) > 72 {
		return errBadPassword
	}
	return nil
}

func (s *Store) HasUsers() bool {
	var n int
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&n)
	return n > 0
}

func (s *Store) Users() ([]User, error) {
	rows, err := s.db.Query(`SELECT name, created FROM users ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []User
	for rows.Next() {
		var u User
		var created int64
		if err := rows.Scan(&u.Name, &created); err != nil {
			return nil, err
		}
		u.Created = time.Unix(created, 0)
		out = append(out, u)
	}
	return out, rows.Err()
}

func (s *Store) AddUser(name, password string, now time.Time) error {
	if !validName.MatchString(name) {
		return errBadName
	}
	if err := checkPasswordRules(password); err != nil {
		return err
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), s.cost)
	if err != nil {
		return err
	}
	res, err := s.db.Exec(`INSERT OR IGNORE INTO users (name, hash, created) VALUES (?, ?, ?)`, name, hash, now.Unix())
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errUserExists
	}
	return nil
}

// SetPassword changes a password and ends every login that user had.
func (s *Store) SetPassword(name, password string) error {
	if err := checkPasswordRules(password); err != nil {
		return err
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), s.cost)
	if err != nil {
		return err
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.Exec(`UPDATE users SET hash = ? WHERE name = ?`, hash, name)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errNoUser
	}
	if _, err := tx.Exec(`DELETE FROM sessions WHERE user = ?`, name); err != nil {
		return err
	}
	return tx.Commit()
}

// DeleteUser removes a user, and their logins with them.
func (s *Store) DeleteUser(name string) error {
	res, err := s.db.Exec(`DELETE FROM users WHERE name = ?`, name)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errNoUser
	}
	return nil
}

// CheckPassword says whether the password is right. A name that doesn't exist
// takes as long as a wrong password.
func (s *Store) CheckPassword(name, password string) bool {
	var hash []byte
	if err := s.db.QueryRow(`SELECT hash FROM users WHERE name = ?`, name).Scan(&hash); err != nil {
		_ = bcrypt.CompareHashAndPassword(s.dummy, []byte(password))
		return false
	}
	return bcrypt.CompareHashAndPassword(hash, []byte(password)) == nil
}

// Only a hash of each token is kept, so the file alone can't be used to log in.
func tokenKey(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}

func (s *Store) NewSession(user string, now time.Time) (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	token := base64.RawURLEncoding.EncodeToString(raw)
	_, err := s.db.Exec(`INSERT INTO sessions (token, user, expires) VALUES (?, ?, ?)`,
		tokenKey(token), user, now.Add(sessionLife).Unix())
	return token, err
}

// SessionUser gives the user a login token belongs to, if it's still good.
func (s *Store) SessionUser(token string, now time.Time) (string, bool) {
	if token == "" {
		return "", false
	}
	var user string
	err := s.db.QueryRow(`SELECT user FROM sessions WHERE token = ? AND expires > ?`, tokenKey(token), now.Unix()).Scan(&user)
	return user, err == nil
}

func (s *Store) EndSession(token string) {
	_, _ = s.db.Exec(`DELETE FROM sessions WHERE token = ?`, tokenKey(token))
}

// Analytics --------------------------------------------------------------------

// AnalyticsKey is the secret that IP addresses are hashed with, made on first use.
// Without it, a hash can't be matched back to an address by trying them all, so it
// lives in a file of its own next to the database (relay.db.key), which backups of
// the database don't copy. Losing it only means a new one, since players are
// counted day by day. Older relays kept it in the database: it's moved out.
func (s *Store) AnalyticsKey() ([]byte, error) {
	if s.key != nil {
		return s.key, nil
	}
	var old []byte
	err := s.db.QueryRow(`SELECT value FROM meta WHERE key = 'analytics_key'`).Scan(&old)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	key := old
	if s.path != "" {
		switch read, err := os.ReadFile(s.path + ".key"); {
		case err == nil && len(read) == 32:
			key = read
		case err == nil:
			return nil, fmt.Errorf("%s.key holds %d bytes, not 32", s.path, len(read))
		case !errors.Is(err, fs.ErrNotExist):
			return nil, err
		}
	}
	if key == nil {
		key = make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			return nil, err
		}
	}
	if s.path != "" {
		if err := writeKeyFile(s.path+".key", key); err != nil {
			return nil, err
		}
	}
	if old != nil {
		if err := s.forgetOldKey(); err != nil {
			return nil, err
		}
	}
	s.key = key
	return key, nil
}

// writeKeyFile writes the key where only the relay's user can read it, whole or
// not at all.
func writeKeyFile(path string, key []byte) error {
	if read, err := os.ReadFile(path); err == nil && string(read) == string(key) {
		return nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".key-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(key); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// forgetOldKey deletes the key an older relay kept in the database, zeroing it
// rather than leaving it in a free page, and writes that back into the file at
// once, so a backup started afterwards never sees it.
func (s *Store) forgetOldKey() error {
	ctx := context.Background()
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `PRAGMA secure_delete = ON`); err != nil {
		return err
	}
	defer conn.ExecContext(ctx, `PRAGMA secure_delete = OFF`)
	if _, err := conn.ExecContext(ctx, `DELETE FROM meta WHERE key = 'analytics_key'`); err != nil {
		return err
	}
	if s.path != "" {
		_, err = conn.ExecContext(ctx, `PRAGMA wal_checkpoint(TRUNCATE)`)
	}
	return err
}

// WriteTally adds counts gathered in memory to the day they belong to.
func (s *Store) WriteTally(t *Tally) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`INSERT OR IGNORE INTO daily (day) VALUES (?)`, t.Day); err != nil {
		return err
	}
	fresh := 0
	for hash := range t.Visitors {
		res, err := tx.Exec(`INSERT OR IGNORE INTO visitors (day, ip_hash) VALUES (?, ?)`, t.Day, hash[:])
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 1 {
			fresh++
		}
	}
	_, err = tx.Exec(`UPDATE daily SET unique_ips = unique_ips + ?, rooms = rooms + ?, joins = joins + ?,
		races = races + ?, racers = racers + ?, refused = refused + ?,
		peak_players = MAX(peak_players, ?), bytes_in = bytes_in + ?, bytes_out = bytes_out + ?, backs = backs + ?,
		quick_races = quick_races + ?
		WHERE day = ?`,
		fresh, t.Rooms, t.Joins, t.Races, t.Racers, t.Refused, t.Peak, int64(t.BytesIn), int64(t.BytesOut), t.Backs,
		t.QuickRaces, t.Day)
	if err != nil {
		return err
	}
	for _, race := range t.Finished {
		if _, err := tx.Exec(`INSERT INTO races (started, ended, players, proto, kind) VALUES (?, ?, ?, ?, ?)`,
			race.Started.Unix(), race.Ended.Unix(), race.Players, race.Proto, race.Kind); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// Prune forgets visitor hashes from before the given day, and logins that have run
// out. Each day's count of unique IPs stays.
func (s *Store) Prune(before string, now time.Time) error {
	if _, err := s.db.Exec(`DELETE FROM visitors WHERE day < ?`, before); err != nil {
		return err
	}
	_, err := s.db.Exec(`DELETE FROM sessions WHERE expires <= ?`, now.Unix())
	return err
}

// Day is one row of the daily totals.
type Day struct {
	Day                                    string
	UniqueIPs, Rooms, Joins, Races, Racers int
	Refused, PeakPlayers, Backs            int
	QuickRaces, Signups                    int
	BytesIn, BytesOut                      uint64
}

const dailyColumns = `day, unique_ips, rooms, joins, races, racers, refused, peak_players, bytes_in, bytes_out, backs, quick_races, signups`

func scanDay(rows *sql.Rows) (Day, error) {
	var d Day
	var in, out int64
	err := rows.Scan(&d.Day, &d.UniqueIPs, &d.Rooms, &d.Joins, &d.Races, &d.Racers, &d.Refused, &d.PeakPlayers, &in, &out, &d.Backs, &d.QuickRaces, &d.Signups)
	d.BytesIn, d.BytesOut = uint64(in), uint64(out)
	return d, err
}

// Days gives the latest n days that have anything, newest first.
func (s *Store) Days(n int) ([]Day, error) {
	rows, err := s.db.Query(`SELECT `+dailyColumns+` FROM daily ORDER BY day DESC LIMIT ?`, n)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Day
	for rows.Next() {
		d, err := scanDay(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// UniqueSince counts the different IPs seen from the given day on. It only reaches
// as far back as the visitor hashes are kept.
func (s *Store) UniqueSince(day string) (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(DISTINCT ip_hash) FROM visitors WHERE day >= ?`, day).Scan(&n)
	return n, err
}

// ExportDaily writes the daily totals as CSV, oldest first.
func (s *Store) ExportDaily(w io.Writer) error {
	rows, err := s.db.Query(`SELECT ` + dailyColumns + ` FROM daily ORDER BY day`)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := csv.NewWriter(w)
	_ = out.Write([]string{"day", "unique_ips", "rooms", "joins", "races", "racers", "refused", "peak_players", "bytes_in", "bytes_out", "backs", "quick_races", "signups"})
	for rows.Next() {
		d, err := scanDay(rows)
		if err != nil {
			return err
		}
		_ = out.Write([]string{d.Day, strconv.Itoa(d.UniqueIPs), strconv.Itoa(d.Rooms), strconv.Itoa(d.Joins),
			strconv.Itoa(d.Races), strconv.Itoa(d.Racers), strconv.Itoa(d.Refused), strconv.Itoa(d.PeakPlayers),
			strconv.FormatUint(d.BytesIn, 10), strconv.FormatUint(d.BytesOut, 10), strconv.Itoa(d.Backs), strconv.Itoa(d.QuickRaces),
			strconv.Itoa(d.Signups)})
	}
	out.Flush()
	if err := rows.Err(); err != nil {
		return err
	}
	return out.Error()
}

// ExportRaces writes every finished race as CSV, oldest first, with UTC times.
func (s *Store) ExportRaces(w io.Writer) error {
	rows, err := s.db.Query(`SELECT started, ended, players, proto, kind FROM races ORDER BY started, id`)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := csv.NewWriter(w)
	_ = out.Write([]string{"started", "ended", "seconds", "players", "protocol", "kind"})
	for rows.Next() {
		var started, ended int64
		var players int
		var proto, kind string
		if err := rows.Scan(&started, &ended, &players, &proto, &kind); err != nil {
			return err
		}
		_ = out.Write([]string{
			time.Unix(started, 0).UTC().Format(time.RFC3339), time.Unix(ended, 0).UTC().Format(time.RFC3339),
			strconv.FormatInt(ended-started, 10), strconv.Itoa(players), proto, kind})
	}
	out.Flush()
	if err := rows.Err(); err != nil {
		return err
	}
	return out.Error()
}

// Drivers ------------------------------------------------------------------------

// Drivers loads every driver with its device keys, for the relay to hold in memory.
func (s *Store) Drivers() ([]*Account, error) {
	rows, err := s.db.Query(`SELECT id, name, recovery, created, seen, renamed, banned FROM drivers`)
	if err != nil {
		return nil, err
	}
	byID := make(map[int]*Account)
	var out []*Account
	for rows.Next() {
		a := &Account{}
		var created, renamed int64
		if err := rows.Scan(&a.ID, &a.Name, &a.Recovery, &created, &a.Seen, &renamed, &a.Banned); err != nil {
			rows.Close()
			return nil, err
		}
		a.Created = time.Unix(created, 0)
		if renamed != 0 {
			a.Renamed = time.Unix(renamed, 0)
		}
		byID[a.ID] = a
		out = append(out, a)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	keys, err := s.db.Query(`SELECT id, driver, key, label, added, seen FROM driver_keys ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer keys.Close()
	for keys.Next() {
		k := &DeviceKey{}
		var driver int
		if err := keys.Scan(&k.ID, &driver, &k.Key, &k.Label, &k.Added, &k.Seen); err != nil {
			return nil, err
		}
		if a := byID[driver]; a != nil {
			a.Keys = append(a.Keys, k)
		}
	}
	return out, keys.Err()
}

// LastDriverID is the highest driver number ever given, deleted or not.
func (s *Store) LastDriverID() (int, error) {
	var last int
	err := s.db.QueryRow(`SELECT COALESCE(MAX(seq), 0) FROM sqlite_sequence WHERE name = 'drivers'`).Scan(&last)
	return last, err
}

func (s *Store) AddDriver(a *Account) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`INSERT INTO drivers (id, name, recovery, created, seen) VALUES (?, ?, ?, ?, ?)`,
		a.ID, a.Name, a.Recovery, a.Created.Unix(), a.Seen); err != nil {
		return err
	}
	for _, k := range a.Keys {
		if err := insertKey(tx, a.ID, k); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func insertKey(tx *sql.Tx, driver int, k *DeviceKey) error {
	_, err := tx.Exec(`INSERT INTO driver_keys (id, driver, key, label, added, seen) VALUES (?, ?, ?, ?, ?, ?)`,
		k.ID, driver, k.Key, k.Label, k.Added, k.Seen)
	return err
}

// AddDeviceKey signs a driver in on another device, dropping the keys it pushed out.
func (s *Store) AddDeviceKey(driver int, k *DeviceKey, dropped []int, today string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := insertKey(tx, driver, k); err != nil {
		return err
	}
	for _, id := range dropped {
		if _, err := tx.Exec(`DELETE FROM driver_keys WHERE id = ?`, id); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`UPDATE drivers SET seen = ? WHERE id = ?`, today, driver); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) SeeDriver(driver, key int, today string) error {
	if _, err := s.db.Exec(`UPDATE drivers SET seen = ? WHERE id = ?`, today, driver); err != nil {
		return err
	}
	_, err := s.db.Exec(`UPDATE driver_keys SET seen = ? WHERE id = ?`, today, key)
	return err
}

func (s *Store) DeleteDeviceKey(id int) error {
	_, err := s.db.Exec(`DELETE FROM driver_keys WHERE id = ?`, id)
	return err
}

func (s *Store) RenameDriver(id int, name string, at time.Time) error {
	renamed := int64(0)
	if !at.IsZero() {
		renamed = at.Unix()
	}
	_, err := s.db.Exec(`UPDATE drivers SET name = ?, renamed = ? WHERE id = ?`, name, renamed, id)
	return err
}

func (s *Store) BanDriver(id int, banned bool) error {
	_, err := s.db.Exec(`UPDATE drivers SET banned = ? WHERE id = ?`, banned, id)
	return err
}

// DeleteDriver removes a driver and its keys, zeroing them rather than leaving
// them in a free page of the file.
func (s *Store) DeleteDriver(id int) error {
	ctx := context.Background()
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `PRAGMA secure_delete = ON`); err != nil {
		return err
	}
	defer conn.ExecContext(ctx, `PRAGMA secure_delete = OFF`)
	_, err = conn.ExecContext(ctx, `DELETE FROM drivers WHERE id = ?`, id)
	return err
}
