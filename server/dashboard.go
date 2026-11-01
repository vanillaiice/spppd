package main

import (
	"bytes"
	_ "embed"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"net/url"
	"time"
)

//go:embed dashboard.html
var dashboardHTML string

//go:embed htmx.min.js
var htmxScript []byte

func formatAge(d time.Duration) string {
	seconds := int(d.Seconds())
	switch {
	case seconds < 60:
		return fmt.Sprintf("%ds", seconds)
	case seconds < 3600:
		return fmt.Sprintf("%dm %ds", seconds/60, seconds%60)
	case seconds < 86400:
		return fmt.Sprintf("%dh %dm", seconds/3600, seconds%3600/60)
	}
	return fmt.Sprintf("%dd %dh", seconds/86400, seconds%86400/3600)
}

func formatBytes(n uint64) string {
	units := []string{"B", "KB", "MB", "GB"}
	size, unit := float64(n), 0
	for size >= 1024 && unit < len(units)-1 {
		size /= 1024
		unit++
	}
	if unit == 0 {
		return fmt.Sprintf("%d B", n)
	}
	return fmt.Sprintf("%.1f %s", size, units[unit])
}

func formatClock(t time.Time) string {
	return t.Format("15:04:05")
}

func isLoopbackHost(host string) bool {
	if name, _, err := net.SplitHostPort(host); err == nil {
		host = name
	}
	if host == "localhost" {
		return true
	}
	if len(host) > 2 && host[0] == '[' {
		host = host[1 : len(host)-1]
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// guard keeps other websites away. The dashboard has no login, so a page open
// in the same browser could otherwise reach it through the tunnel.
func guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !isLoopbackHost(r.Host) {
			http.Error(w, "the dashboard only answers on localhost", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			if origin := r.Header.Get("Origin"); origin != "" {
				parsed, err := url.Parse(origin)
				if err != nil || parsed.Host != r.Host {
					http.Error(w, "cross-site request refused", http.StatusForbidden)
					return
				}
			}
		}
		next.ServeHTTP(w, r)
	})
}

func newDashboard(relay *Relay) http.Handler {
	pages := template.Must(template.New("dashboard").Funcs(template.FuncMap{
		"age": formatAge, "bytes": formatBytes, "clock": formatClock,
	}).Parse(dashboardHTML))

	render := func(w http.ResponseWriter, name string) {
		var out bytes.Buffer
		if err := pages.ExecuteTemplate(&out, name, relay.Snapshot()); err != nil {
			log.Printf("[DASHBOARD] %v", err)
			http.Error(w, "the page could not be drawn", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(out.Bytes())
	}

	// action runs a change, then answers with the fresh live section.
	action := func(run func(r *http.Request) error) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodPost {
				http.Error(w, "POST only", http.StatusMethodNotAllowed)
				return
			}
			if err := run(r); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			render(w, "live")
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		render(w, "page")
	})
	mux.HandleFunc("/live", func(w http.ResponseWriter, r *http.Request) {
		render(w, "live")
	})
	mux.HandleFunc("/htmx.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		_, _ = w.Write(htmxScript)
	})
	mux.HandleFunc("/close", action(func(r *http.Request) error {
		relay.Close(r.FormValue("addr")) // already gone is fine
		return nil
	}))
	mux.HandleFunc("/ban", action(func(r *http.Request) error {
		if !relay.Ban(r.FormValue("ip")) {
			return fmt.Errorf("that isn't an IP address")
		}
		return nil
	}))
	mux.HandleFunc("/unban", action(func(r *http.Request) error {
		relay.Unban(r.FormValue("ip"))
		return nil
	}))
	return guard(mux)
}
