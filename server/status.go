package main

// The public status, for the website's status page: whether the relay is up and
// how busy it is. -status serves it as JSON at /api/status. It holds counts only,
// nothing that points to anyone.

import (
	"encoding/json"
	"net/http"
)

// Status is what the page shows. If the relay answers at all, it's up.
type Status struct {
	Up      bool `json:"up"`
	Players int  `json:"players"`
	Races   int  `json:"races"`   // rooms that are racing
	Looking int  `json:"looking"` // drivers in quick matches that haven't started
}

func (r *Relay) Status() Status {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := Status{Up: true, Players: len(r.clients)}
	for _, room := range r.rooms {
		if room.Locked {
			out.Races++
		} else if room.Kind != "" {
			out.Looking += len(room.members())
		}
	}
	return out
}

func newStatusPage(relay *Relay) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Type", "application/json")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Cache-Control", "public, max-age=5")
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			h.Set("Allow", "GET, HEAD")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		_ = json.NewEncoder(w).Encode(relay.Status())
	})
	return mux
}
