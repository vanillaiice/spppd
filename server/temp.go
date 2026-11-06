package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"strconv"
	"time"
)

// Temporary state that should outlast a restart but not be kept: the rooms being
// raced in, so restarting the relay doesn't end their races, and the dashboard's
// recent activity. Both hold IP addresses, and the rooms hold seat tokens, so they
// live in a file of their own (relay-temp.db) that the backup leaves alone.
//
// The relay never waits on this file. It hands events to a buffered channel, and
// drops them rather than block when the channel is full. One goroutine, persist,
// does all the writing, and copies the rooms under the lock only for as long as a
// copy takes.

const (
	eventLife    = 7 * 24 * time.Hour // activity older than this is deleted
	eventQueue   = 1024               // events waiting to be written
	roomsEvery   = 2 * time.Second    // how often the rooms are saved
	eventsEvery  = time.Second        // how often waiting events are written
	cleanupEvery = time.Minute        // how often old activity is deleted
	tempSchema   = `
CREATE TABLE IF NOT EXISTS events (
	seq INTEGER PRIMARY KEY, at INTEGER NOT NULL, text TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS rooms (
	id INTEGER PRIMARY KEY CHECK (id = 1), saved INTEGER NOT NULL, data BLOB NOT NULL);
`
)

// TempStore is the file for temporary state.
type TempStore struct {
	db *sql.DB
}

// OpenTempStore opens the file at path, creating it if needed.
func OpenTempStore(path string) (*TempStore, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)&_pragma=temp_store(MEMORY)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	db.SetConnMaxLifetime(0)
	if _, err := db.Exec(tempSchema); err != nil {
		db.Close()
		return nil, fmt.Errorf("setting up %s: %w", path, err)
	}
	return &TempStore{db: db}, nil
}

func (t *TempStore) Close() error { return t.db.Close() }

// AddEvents writes a batch of activity in one go.
func (t *TempStore) AddEvents(events []Event) error {
	tx, err := t.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, e := range events {
		if _, err := tx.Exec(`INSERT OR REPLACE INTO events (seq, at, text) VALUES (?, ?, ?)`, e.Seq, e.At.UnixMilli(), e.Text); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// CleanUp deletes activity older than a week, and all but the newest lines the
// dashboard shows.
func (t *TempStore) CleanUp(now time.Time) error {
	_, err := t.db.Exec(`DELETE FROM events WHERE at < ? OR seq <= (SELECT MAX(seq) FROM events) - ?`,
		now.Add(-eventLife).UnixMilli(), maxEvents)
	return err
}

// Events is the activity kept, oldest first.
func (t *TempStore) Events(now time.Time) ([]Event, error) {
	rows, err := t.db.Query(`SELECT seq, at, text FROM (
		SELECT seq, at, text FROM events WHERE at >= ? ORDER BY seq DESC LIMIT ?) ORDER BY seq`,
		now.Add(-eventLife).UnixMilli(), maxEvents)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Event
	for rows.Next() {
		var e Event
		var at int64
		if err := rows.Scan(&e.Seq, &at, &e.Text); err != nil {
			return nil, err
		}
		e.At = time.UnixMilli(at)
		out = append(out, e)
	}
	return out, rows.Err()
}

// SaveRooms keeps the rooms as they are at saved. Unchanged rooms only move the
// time on, which is a few bytes.
func (t *TempStore) SaveRooms(saved time.Time, data []byte, changed bool) error {
	if !changed {
		res, err := t.db.Exec(`UPDATE rooms SET saved = ? WHERE id = 1`, saved.UnixMilli())
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 1 {
			return nil
		}
	}
	_, err := t.db.Exec(`INSERT OR REPLACE INTO rooms (id, saved, data) VALUES (1, ?, ?)`, saved.UnixMilli(), data)
	return err
}

// Rooms is what SaveRooms kept last, and when. No rooms were ever saved: nil.
func (t *TempStore) Rooms() (time.Time, []byte, error) {
	var saved int64
	var data []byte
	err := t.db.QueryRow(`SELECT saved, data FROM rooms WHERE id = 1`).Scan(&saved, &data)
	if err == sql.ErrNoRows {
		return time.Time{}, nil, nil
	}
	return time.UnixMilli(saved), data, err
}

// savedRoom is a room as it's written down. Only rooms from protocol 5 on are,
// because only their drivers can get back in after a restart.
type savedRoom struct {
	Code   string
	Proto  string
	Since  time.Time
	Locked bool
	Raced  time.Time
	Racers int
	Seats  []savedSeat
}

type savedSeat struct {
	Slot  int
	Addr  string
	Token string
}

func comesBack(room *Room) bool {
	version, _ := strconv.Atoi(room.Proto)
	return version >= cookieProto
}

// saveRooms copies the rooms worth keeping. It holds the lock only for the copy.
func (r *Relay) saveRooms() []savedRoom {
	r.mu.Lock()
	defer r.mu.Unlock()

	out := make([]savedRoom, 0, len(r.rooms))
	for _, room := range r.rooms {
		if !comesBack(room) {
			continue
		}
		saved := savedRoom{Code: room.Code, Proto: room.Proto, Since: room.Since,
			Locked: room.Locked, Raced: room.Raced, Racers: room.Racers}
		for _, member := range room.members() {
			if member.Token != "" {
				saved.Seats = append(saved.Seats, savedSeat{Slot: member.Slot, Addr: member.Addr.String(), Token: member.Token})
			}
		}
		if len(saved.Seats) > 0 {
			out = append(out, saved)
		}
	}
	return out
}

// RestoreRooms puts back rooms saved before a restart. Each driver is seated at the
// address they had, and seen just now, so a game whose address didn't change goes
// on as if nothing happened, and one that moved takes its seat back with its token.
// The usual timeouts then drop anyone who doesn't return. It says how many rooms and
// drivers it put back.
func (r *Relay) RestoreRooms(rooms []savedRoom) (restored, drivers int) {
	r.mu.Lock()
	defer r.mu.Unlock()

	for _, saved := range rooms {
		if !validCode(saved.Code) || !validProto(saved.Proto) || r.rooms[saved.Code] != nil {
			continue
		}
		room := &Room{Code: saved.Code, Proto: saved.Proto, Since: saved.Since,
			Locked: saved.Locked, Raced: saved.Raced, Racers: saved.Racers}
		for _, seat := range saved.Seats {
			addr, err := net.ResolveUDPAddr("udp", seat.Addr)
			if err != nil || seat.Slot < 1 || seat.Slot > maxRoomPlayers || room.Seats[seat.Slot-1] != nil ||
				seat.Token == "" || r.clients[addr.String()] != nil {
				continue
			}
			r.seat(room, seat.Slot, addr, seat.Token)
			drivers++
		}
		if len(room.members()) > 0 {
			r.rooms[room.Code] = room
			restored++
		}
	}
	return restored, drivers
}

// Note records a line of activity from outside the relay.
func (r *Relay) Note(format string, args ...any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.event(format, args...)
}

// RestoreEvents puts back the dashboard's activity, and numbers new lines after it,
// so an open dashboard keeps adding to its list.
func (r *Relay) RestoreEvents(events []Event) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if len(events) > maxEvents {
		events = events[len(events)-maxEvents:]
	}
	r.events = append(events, r.events...)
	for _, e := range r.events {
		r.eventSeq = max(r.eventSeq, e.Seq)
	}
	// Lines recorded before the restore get numbers after the restored ones.
	for i := len(events); i < len(r.events); i++ {
		r.eventSeq++
		r.events[i].Seq = r.eventSeq
	}
	if len(r.events) > maxEvents {
		r.events = r.events[len(r.events)-maxEvents:]
	}
}

// KeepTemp starts writing temporary state to temp, and returns a function that
// writes the last of it and stops. Call it after Shutdown.
func (r *Relay) KeepTemp(temp *TempStore) (stop func()) {
	events := make(chan Event, eventQueue)
	r.mu.Lock()
	r.tempEvents = events
	r.mu.Unlock()

	quit, done := make(chan struct{}), make(chan struct{})
	go r.persist(temp, events, quit, done)
	return func() {
		close(quit)
		<-done
	}
}

// persist is the one goroutine that writes the temporary file.
func (r *Relay) persist(temp *TempStore, events <-chan Event, quit, done chan struct{}) {
	defer close(done)
	var batch []Event
	var last []byte
	writeEvents := func() {
		if len(batch) == 0 {
			return
		}
		if err := temp.AddEvents(batch); err != nil {
			log.Printf("[TEMP] writing activity: %v", err)
		}
		batch = batch[:0]
	}
	writeRooms := func() {
		data, err := json.Marshal(r.saveRooms())
		if err != nil {
			log.Printf("[TEMP] saving rooms: %v", err)
			return
		}
		changed := !bytes.Equal(data, last)
		if err := temp.SaveRooms(r.now(), data, changed); err != nil {
			log.Printf("[TEMP] saving rooms: %v", err)
			return
		}
		last = data
	}
	cleanUp := func() {
		if err := temp.CleanUp(r.now()); err != nil {
			log.Printf("[TEMP] cleaning up: %v", err)
		}
	}
	cleanUp()

	eventsTick := time.NewTicker(eventsEvery)
	roomsTick := time.NewTicker(roomsEvery)
	cleanupTick := time.NewTicker(cleanupEvery)
	defer eventsTick.Stop()
	defer roomsTick.Stop()
	defer cleanupTick.Stop()
	for {
		select {
		case e := <-events:
			batch = append(batch, e)
		case <-eventsTick.C:
			writeEvents()
		case <-roomsTick.C:
			writeRooms()
		case <-cleanupTick.C:
			cleanUp()
		case <-quit:
			for {
				select {
				case e := <-events:
					batch = append(batch, e)
					continue
				default:
				}
				break
			}
			writeEvents()
			writeRooms()
			cleanUp()
			return
		}
	}
}

// LoadTemp puts back what was kept before a restart, and says how many rooms and
// drivers came back. Rooms saved longer ago than a seat waits for its driver are
// left out: their games have given up. Call it before KeepTemp.
func (r *Relay) LoadTemp(temp *TempStore, seatLife time.Duration) (rooms, drivers int, err error) {
	events, err := temp.Events(r.now())
	if err != nil {
		return 0, 0, err
	}
	r.RestoreEvents(events)

	saved, data, err := temp.Rooms()
	if err != nil || data == nil {
		return 0, 0, err
	}
	if age := r.now().Sub(saved); age < 0 || age > seatLife {
		return 0, 0, nil
	}
	var kept []savedRoom
	if err := json.Unmarshal(data, &kept); err != nil {
		return 0, 0, fmt.Errorf("reading the saved rooms: %w", err)
	}
	rooms, drivers = r.RestoreRooms(kept)
	return rooms, drivers, nil
}
