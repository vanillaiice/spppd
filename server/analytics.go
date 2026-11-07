package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"log"
	"time"
)

// maxVisitors caps the addresses one tally holds, so forged sources can't grow it
// without limit between writes.
const maxVisitors = 1 << 16

// RaceRecord is a room that started racing, once it has emptied. The relay reads
// nothing it forwards, so it can't see single races: rematches in the same room
// are one record.
type RaceRecord struct {
	Started, Ended time.Time
	Players        int
	Proto          string
	Kind           string // "" for a hosted room, "quick" for quick match
}

// Tally is one UTC day's analytics, gathered in memory until they're written.
type Tally struct {
	Day                                  string
	Visitors                             map[[32]byte]struct{} // keyed hashes of IPs, never the IPs
	Rooms, Joins, Races, Racers, Refused int
	Backs                                int // seats taken back from a new address
	QuickRaces                           int // races in rooms quick match made
	Peak                                 int
	BytesIn, BytesOut                    uint64
	Finished                             []RaceRecord
}

func dayOf(t time.Time) string { return t.UTC().Format("2006-01-02") }

func newTally(now time.Time) *Tally {
	return &Tally{Day: dayOf(now), Visitors: make(map[[32]byte]struct{})}
}

// EnableAnalytics starts counting. Without it the relay counts nothing.
func (r *Relay) EnableAnalytics(key []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.analyticsKey = key
	r.tally = newTally(r.now())
}

// visit counts an IP for today. Callers hold the lock.
func (r *Relay) visit(ip string) {
	if r.tally == nil || len(r.tally.Visitors) >= maxVisitors {
		return
	}
	mac := hmac.New(sha256.New, r.analyticsKey)
	mac.Write([]byte(ip))
	var hash [32]byte
	copy(hash[:], mac.Sum(nil))
	r.tally.Visitors[hash] = struct{}{}
}

// rollTally starts a new tally when the day changes, keeping the old one to be
// written. Callers hold the lock.
func (r *Relay) rollTally() {
	if r.tally == nil {
		return
	}
	if today := dayOf(r.now()); r.tally.Day != today {
		r.finished = append(r.finished, r.tally)
		r.tally = newTally(r.now())
	}
}

// takeTallies hands over everything counted so far and starts afresh.
func (r *Relay) takeTallies() []*Tally {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.tally == nil {
		return nil
	}
	out := append(r.finished, r.tally)
	r.finished = nil
	r.tally = newTally(r.now())
	// Whoever is on now still counts toward the new tally's peak.
	r.tally.Peak = len(r.clients)
	return out
}

// FlushAnalytics writes what has been counted. A tally that fails to write is
// lost, rather than piling up in memory.
func (r *Relay) FlushAnalytics() {
	if r.store == nil {
		return
	}
	r.flushMu.Lock()
	defer r.flushMu.Unlock()
	for _, tally := range r.takeTallies() {
		if err := r.store.WriteTally(tally); err != nil {
			log.Printf("[ANALYTICS] writing %s: %v", tally.Day, err)
		}
	}
}

// AnalyticsOn says whether the relay was started with -analytics.
func (r *Relay) AnalyticsOn() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.tally != nil
}
