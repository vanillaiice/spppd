package main

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
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
	backs INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS visitors (
	day TEXT NOT NULL, ip_hash BLOB NOT NULL, PRIMARY KEY (day, ip_hash)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS races (
	id INTEGER PRIMARY KEY, started INTEGER NOT NULL, ended INTEGER NOT NULL,
	players INTEGER NOT NULL, proto TEXT NOT NULL);
`

// migrate brings a database from an older relay up to date. Each step checks
// for itself, so running it twice does nothing.
func migrate(db *sql.DB) error {
	var backs int
	if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('daily') WHERE name = 'backs'`).Scan(&backs); err != nil {
		return err
	}
	if backs == 0 {
		if _, err := db.Exec(`ALTER TABLE daily ADD COLUMN backs INTEGER NOT NULL DEFAULT 0`); err != nil {
			return err
		}
	}
	_, err := db.Exec(`PRAGMA user_version = 2`)
	return err
}

// Store keeps what has to outlive a restart: bans, dashboard users and their
// logins, and analytics when they're on. It's one SQLite file, or memory.
type Store struct {
	db    *sql.DB
	cost  int    // bcrypt cost; tests turn it down
	dummy []byte // compared against when a name doesn't exist, so timing doesn't tell
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
	s := &Store{db: db, cost: bcrypt.DefaultCost}
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
// Without it, a hash can't be matched back to an address by trying them all.
func (s *Store) AnalyticsKey() ([]byte, error) {
	var key []byte
	err := s.db.QueryRow(`SELECT value FROM meta WHERE key = 'analytics_key'`).Scan(&key)
	if err == nil {
		return key, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	key = make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	_, err = s.db.Exec(`INSERT INTO meta (key, value) VALUES ('analytics_key', ?)`, key)
	return key, err
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
		peak_players = MAX(peak_players, ?), bytes_in = bytes_in + ?, bytes_out = bytes_out + ?, backs = backs + ?
		WHERE day = ?`,
		fresh, t.Rooms, t.Joins, t.Races, t.Racers, t.Refused, t.Peak, int64(t.BytesIn), int64(t.BytesOut), t.Backs, t.Day)
	if err != nil {
		return err
	}
	for _, race := range t.Finished {
		if _, err := tx.Exec(`INSERT INTO races (started, ended, players, proto) VALUES (?, ?, ?, ?)`,
			race.Started.Unix(), race.Ended.Unix(), race.Players, race.Proto); err != nil {
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
	BytesIn, BytesOut                      uint64
}

const dailyColumns = `day, unique_ips, rooms, joins, races, racers, refused, peak_players, bytes_in, bytes_out, backs`

func scanDay(rows *sql.Rows) (Day, error) {
	var d Day
	var in, out int64
	err := rows.Scan(&d.Day, &d.UniqueIPs, &d.Rooms, &d.Joins, &d.Races, &d.Racers, &d.Refused, &d.PeakPlayers, &in, &out, &d.Backs)
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
	_ = out.Write([]string{"day", "unique_ips", "rooms", "joins", "races", "racers", "refused", "peak_players", "bytes_in", "bytes_out", "backs"})
	for rows.Next() {
		d, err := scanDay(rows)
		if err != nil {
			return err
		}
		_ = out.Write([]string{d.Day, strconv.Itoa(d.UniqueIPs), strconv.Itoa(d.Rooms), strconv.Itoa(d.Joins),
			strconv.Itoa(d.Races), strconv.Itoa(d.Racers), strconv.Itoa(d.Refused), strconv.Itoa(d.PeakPlayers),
			strconv.FormatUint(d.BytesIn, 10), strconv.FormatUint(d.BytesOut, 10), strconv.Itoa(d.Backs)})
	}
	out.Flush()
	if err := rows.Err(); err != nil {
		return err
	}
	return out.Error()
}

// ExportRaces writes every finished race as CSV, oldest first, with UTC times.
func (s *Store) ExportRaces(w io.Writer) error {
	rows, err := s.db.Query(`SELECT started, ended, players, proto FROM races ORDER BY started, id`)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := csv.NewWriter(w)
	_ = out.Write([]string{"started", "ended", "seconds", "players", "protocol"})
	for rows.Next() {
		var started, ended int64
		var players int
		var proto string
		if err := rows.Scan(&started, &ended, &players, &proto); err != nil {
			return err
		}
		_ = out.Write([]string{
			time.Unix(started, 0).UTC().Format(time.RFC3339), time.Unix(ended, 0).UTC().Format(time.RFC3339),
			strconv.FormatInt(ended-started, 10), strconv.Itoa(players), proto})
	}
	out.Flush()
	if err := rows.Err(); err != nil {
		return err
	}
	return out.Error()
}
