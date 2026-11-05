package main

import (
	"bytes"
	"context"
	_ "embed"
	"fmt"
	"html/template"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"
)

//go:embed dashboard.html
var dashboardHTML string

//go:embed htmx.min.js
var htmxScript []byte

//go:embed favicon.svg
var faviconSVG []byte

const (
	cookieName    = "spppd_session"
	maxLoginFails = 10
	loginLockout  = 15 * time.Minute
)

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
	units := []string{"B", "KB", "MB", "GB", "TB"}
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

// The page shows times in the viewer's own zone. These are what it shows
// before its script runs, labelled, so they can't pass for local times.
func formatClock(t time.Time) string {
	return t.UTC().Format("15:04:05") + " UTC"
}

func formatDate(t time.Time) string {
	return t.UTC().Format("2006-01-02 15:04 UTC")
}

// formatInstant is the machine-readable time the page's script reads.
func formatInstant(t time.Time) string {
	return t.UTC().Format(time.RFC3339)
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

func clientIP(r *http.Request) string {
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}

// loginLimiter turns an address away after too many wrong passwords. Behind
// Docker every connection can share one address, so there it limits everyone,
// which is still better than letting passwords be guessed.
type loginLimiter struct {
	mu    sync.Mutex
	fails map[string]*loginFails
}

type loginFails struct {
	count int
	first time.Time
}

func (l *loginLimiter) allowed(ip string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	f := l.fails[ip]
	if f == nil {
		return true
	}
	if now.Sub(f.first) > loginLockout {
		delete(l.fails, ip)
		return true
	}
	return f.count < maxLoginFails
}

func (l *loginLimiter) fail(ip string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.fails) > 4096 {
		l.fails = make(map[string]*loginFails)
	}
	if f := l.fails[ip]; f != nil {
		f.count++
		return
	}
	l.fails[ip] = &loginFails{count: 1, first: now}
}

func (l *loginLimiter) succeed(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.fails, ip)
}

// sameOrigin stops another site making a browser post to the dashboard.
func sameOrigin(r *http.Request) bool {
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		return true
	}
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	parsed, err := url.Parse(origin)
	return err == nil && parsed.Host == r.Host
}

type userKey struct{}

// viewer is who is looking at the page. Name is empty on a dashboard with no users.
type viewer struct {
	Name  string
	Local bool
}

// pageData is everything the templates can draw.
type pageData struct {
	Snapshot
	Viewer    viewer
	Users     []User
	Analytics *analyticsView
	Error     string
	Notice    string
}

type analyticsView struct {
	Days       []Day
	Week       int // unique IPs over the last 7 days
	Window     int // and over every day the hashes are kept
	WindowDays int
}

type dashboard struct {
	relay         *Relay
	store         *Store
	pages         *template.Template
	limiter       *loginLimiter
	analyticsDays int
	now           func() time.Time
}

// newDashboard serves the relay's dashboard. Once the store has a user, everything
// takes a login. Until then it only answers this machine: the connection has to
// come from loopback, and so does the name it asked for, which stops a web page
// using DNS tricks to reach it through a local browser.
func newDashboard(relay *Relay, store *Store, analyticsDays int) http.Handler {
	d := &dashboard{
		relay: relay, store: store, analyticsDays: analyticsDays,
		limiter: &loginLimiter{fails: make(map[string]*loginFails)},
		now:     time.Now,
	}
	d.pages = template.Must(template.New("dashboard").Funcs(template.FuncMap{
		"age": formatAge, "bytes": formatBytes, "clock": formatClock, "date": formatDate, "instant": formatInstant,
	}).Parse(dashboardHTML))

	mux := http.NewServeMux()
	mux.HandleFunc("/", d.authed(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		d.render(w, "page", d.full(r))
	}))
	mux.HandleFunc("/live", d.authed(func(w http.ResponseWriter, r *http.Request) {
		d.render(w, "live", d.data(r))
	}))
	mux.HandleFunc("/activity", d.authed(func(w http.ResponseWriter, r *http.Request) {
		d.render(w, "activity", d.data(r))
	}))
	mux.HandleFunc("/htmx.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		_, _ = w.Write(htmxScript)
	})
	mux.HandleFunc("/favicon.svg", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/svg+xml")
		w.Header().Set("Cache-Control", "public, max-age=86400")
		_, _ = w.Write(faviconSVG)
	})
	mux.HandleFunc("/login", d.login)
	mux.HandleFunc("/logout", d.logout)

	mux.HandleFunc("/close", d.action("live", func(r *http.Request, data *pageData) {
		relay.Close(r.FormValue("addr")) // already gone is fine
	}))
	mux.HandleFunc("/ban", d.action("live", func(r *http.Request, data *pageData) {
		by := data.Viewer.Name
		if by == "" {
			by = "localhost"
		}
		if !relay.Ban(r.FormValue("ip"), by) {
			data.Error = "That isn't an IP address."
		}
	}))
	mux.HandleFunc("/unban", d.action("live", func(r *http.Request, data *pageData) {
		relay.Unban(r.FormValue("ip"))
	}))

	mux.HandleFunc("/users/add", d.usersAction(d.addUser))
	mux.HandleFunc("/users/password", d.usersAction(d.changePassword))
	mux.HandleFunc("/users/delete", d.usersAction(d.deleteUser))

	mux.HandleFunc("/analytics", d.authed(d.analyticsOnly(func(w http.ResponseWriter, r *http.Request) {
		data := d.data(r)
		data.Analytics = d.analytics()
		d.render(w, "analytics", data)
	})))
	mux.HandleFunc("/export/daily.csv", d.authed(d.analyticsOnly(func(w http.ResponseWriter, r *http.Request) {
		d.export(w, "daily", d.store.ExportDaily)
	})))
	mux.HandleFunc("/export/races.csv", d.authed(d.analyticsOnly(func(w http.ResponseWriter, r *http.Request) {
		d.export(w, "races", d.store.ExportRaces)
	})))

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !sameOrigin(r) {
			http.Error(w, "cross-site request refused", http.StatusForbidden)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func (d *dashboard) render(w http.ResponseWriter, name string, data pageData) {
	var out bytes.Buffer
	if err := d.pages.ExecuteTemplate(&out, name, data); err != nil {
		log.Printf("[DASHBOARD] %v", err)
		http.Error(w, "the page could not be drawn", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(out.Bytes())
}

func (d *dashboard) data(r *http.Request) pageData {
	who, _ := r.Context().Value(userKey{}).(viewer)
	return pageData{Snapshot: d.relay.Snapshot(), Viewer: who}
}

func (d *dashboard) full(r *http.Request) pageData {
	data := d.data(r)
	data.Users, _ = d.store.Users()
	if d.relay.AnalyticsOn() {
		data.Analytics = d.analytics()
	}
	return data
}

func (d *dashboard) analytics() *analyticsView {
	d.relay.FlushAnalytics()
	now := d.now()
	view := &analyticsView{WindowDays: d.analyticsDays}
	view.Days, _ = d.store.Days(14)
	view.Week, _ = d.store.UniqueSince(dayOf(now.AddDate(0, 0, -6)))
	view.Window, _ = d.store.UniqueSince(dayOf(now.AddDate(0, 0, -(d.analyticsDays - 1))))
	return view
}

// who works out who sent the request, and whether they may see the dashboard.
func (d *dashboard) who(r *http.Request) (viewer, bool) {
	if !d.store.HasUsers() {
		return viewer{Local: true}, isLoopbackHost(r.RemoteAddr) && isLoopbackHost(r.Host)
	}
	cookie, err := r.Cookie(cookieName)
	if err != nil {
		return viewer{}, false
	}
	name, ok := d.store.SessionUser(cookie.Value, d.now())
	return viewer{Name: name}, ok
}

func (d *dashboard) authed(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		who, ok := d.who(r)
		switch {
		case ok:
			next(w, r.WithContext(context.WithValue(r.Context(), userKey{}, who)))
		case who.Local:
			http.Error(w, "the dashboard only answers on localhost until it has a user", http.StatusForbidden)
		case r.Header.Get("HX-Request") != "":
			// htmx follows this, so a login that runs out mid-poll lands on the form.
			w.Header().Set("HX-Redirect", "/login")
			http.Error(w, "log in again", http.StatusUnauthorized)
		case r.Method == http.MethodGet:
			http.Redirect(w, r, "/login", http.StatusSeeOther)
		default:
			http.Error(w, "log in first", http.StatusUnauthorized)
		}
	}
}

func (d *dashboard) analyticsOnly(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !d.relay.AnalyticsOn() {
			http.NotFound(w, r)
			return
		}
		next(w, r)
	}
}

// action runs a change on a POST, then answers with a fresh section.
func (d *dashboard) action(section string, run func(r *http.Request, data *pageData)) http.HandlerFunc {
	return d.authed(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		data := d.data(r)
		run(r, &data)
		if data.Error != "" {
			http.Error(w, data.Error, http.StatusBadRequest)
			return
		}
		data.Snapshot = d.relay.Snapshot()
		d.render(w, section, data)
	})
}

// usersAction is an action on the users section, which shows its own errors.
func (d *dashboard) usersAction(run func(w http.ResponseWriter, r *http.Request, data *pageData)) http.HandlerFunc {
	return d.authed(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		data := d.data(r)
		run(w, r, &data)
		data.Users, _ = d.store.Users()
		d.render(w, "users", data)
	})
}

func (d *dashboard) setSession(w http.ResponseWriter, r *http.Request, name string) error {
	token, err := d.store.NewSession(name, d.now())
	if err != nil {
		return err
	}
	http.SetCookie(w, &http.Cookie{
		Name: cookieName, Value: token, Path: "/", MaxAge: int(sessionLife.Seconds()),
		HttpOnly: true, SameSite: http.SameSiteStrictMode, Secure: r.TLS != nil,
	})
	return nil
}

func (d *dashboard) addUser(w http.ResponseWriter, r *http.Request, data *pageData) {
	name, password := r.FormValue("name"), r.FormValue("password")
	if err := d.store.AddUser(name, password, d.now()); err != nil {
		data.Error = err.Error()
		return
	}
	log.Printf("[USER] %s added %s", orLocal(data.Viewer.Name), name)
	// The first user turns logins on. Whoever added it is that user, so they
	// shouldn't be shut out of the page they're on.
	if data.Viewer.Local {
		if err := d.setSession(w, r, name); err != nil {
			data.Error = err.Error()
			return
		}
		w.Header().Set("HX-Refresh", "true")
	}
	data.Notice = "Added " + name + "."
}

func (d *dashboard) changePassword(w http.ResponseWriter, r *http.Request, data *pageData) {
	name := data.Viewer.Name
	if name == "" {
		data.Error = "add a user first"
		return
	}
	if !d.store.CheckPassword(name, r.FormValue("current")) {
		data.Error = "your current password is wrong"
		return
	}
	// Changing it logs out everywhere, here too, so this page gets a new login.
	if err := d.store.SetPassword(name, r.FormValue("password")); err != nil {
		data.Error = err.Error()
		return
	}
	if err := d.setSession(w, r, name); err != nil {
		data.Error = err.Error()
		return
	}
	log.Printf("[USER] %s changed their password", name)
	data.Notice = "Password changed. Other logins have ended."
}

func (d *dashboard) deleteUser(w http.ResponseWriter, r *http.Request, data *pageData) {
	name := r.FormValue("name")
	if name == data.Viewer.Name {
		data.Error = "you can't remove yourself"
		return
	}
	if err := d.store.DeleteUser(name); err != nil {
		data.Error = err.Error()
		return
	}
	log.Printf("[USER] %s removed %s", orLocal(data.Viewer.Name), name)
	data.Notice = "Removed " + name + "."
}

func orLocal(name string) string {
	if name == "" {
		return "localhost"
	}
	return name
}

func (d *dashboard) login(w http.ResponseWriter, r *http.Request) {
	if !d.store.HasUsers() {
		if isLoopbackHost(r.RemoteAddr) && isLoopbackHost(r.Host) {
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		w.WriteHeader(http.StatusForbidden)
		d.render(w, "login", pageData{Error: "This dashboard has no users yet. Add one with: relay user add NAME"})
		return
	}
	switch r.Method {
	case http.MethodGet:
		d.render(w, "login", pageData{})
		return
	case http.MethodPost:
	default:
		http.Error(w, "GET or POST", http.StatusMethodNotAllowed)
		return
	}
	ip, now := clientIP(r), d.now()
	if !d.limiter.allowed(ip, now) {
		w.WriteHeader(http.StatusTooManyRequests)
		d.render(w, "login", pageData{Error: "Too many wrong passwords. Try again in a few minutes."})
		return
	}
	name := r.FormValue("name")
	if !d.store.CheckPassword(name, r.FormValue("password")) {
		d.limiter.fail(ip, now)
		log.Printf("[LOGIN] wrong password for %q from %s", name, ip)
		w.WriteHeader(http.StatusUnauthorized)
		d.render(w, "login", pageData{Error: "Wrong name or password."})
		return
	}
	d.limiter.succeed(ip)
	if err := d.setSession(w, r, name); err != nil {
		http.Error(w, "couldn't log you in", http.StatusInternalServerError)
		return
	}
	log.Printf("[LOGIN] %s from %s", name, ip)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (d *dashboard) logout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	if cookie, err := r.Cookie(cookieName); err == nil {
		d.store.EndSession(cookie.Value)
	}
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteStrictMode})
	// htmx would follow a redirect itself and put the login form inside the button.
	if r.Header.Get("HX-Request") != "" {
		w.Header().Set("HX-Redirect", "/login")
		return
	}
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

func (d *dashboard) export(w http.ResponseWriter, name string, write func(io.Writer) error) {
	d.relay.FlushAnalytics()
	var out bytes.Buffer
	if err := write(&out); err != nil {
		log.Printf("[EXPORT] %s: %v", name, err)
		http.Error(w, "the export failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="spppd-%s-%s.csv"`, name, dayOf(d.now())))
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(out.Bytes())
}
