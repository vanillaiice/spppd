package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

func request(handler http.Handler, method, target string, form url.Values, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, strings.NewReader(form.Encode()))
	req.Host = "localhost:9090"
	req.RemoteAddr = "127.0.0.1:50000"
	if method == http.MethodPost {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	for name, value := range headers {
		if name == "Host" {
			req.Host = value
		} else if name == "Remote" {
			req.RemoteAddr = value
		} else {
			req.Header.Set(name, value)
		}
	}
	out := httptest.NewRecorder()
	handler.ServeHTTP(out, req)
	return out
}

// memoryStore is a fresh in-memory store with cheap password hashing.
func memoryStore(t *testing.T) *Store {
	t.Helper()
	store, err := OpenStore("")
	if err != nil {
		t.Fatal(err)
	}
	store.cost = bcrypt.MinCost
	t.Cleanup(func() { store.Close() })
	return store
}

// dash is the dashboard over a relay with an in-memory store and no users.
func dash(t *testing.T, relay *Relay) (http.Handler, *Store) {
	t.Helper()
	store := memoryStore(t)
	if err := relay.AttachStore(store); err != nil {
		t.Fatal(err)
	}
	return newDashboard(relay, store, 30), store
}

// remote is a browser on another machine, as everything looks in a container.
func remote() map[string]string {
	return map[string]string{"Host": "172.17.0.2:9090", "Remote": "172.17.0.1:40000"}
}

// logIn adds a user and returns headers carrying their login.
func logIn(t *testing.T, page http.Handler, store *Store, name string) map[string]string {
	t.Helper()
	if !store.HasUsers() || !userExists(store, name) {
		if err := store.AddUser(name, "correct horse", time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	out := request(page, http.MethodPost, "/login", url.Values{"name": {name}, "password": {"correct horse"}}, remote())
	if out.Code != http.StatusSeeOther {
		t.Fatalf("login: status %d: %s", out.Code, out.Body)
	}
	headers := remote()
	headers["Cookie"] = sessionCookie(t, out)
	return headers
}

func userExists(store *Store, name string) bool {
	users, _ := store.Users()
	for _, user := range users {
		if user.Name == name {
			return true
		}
	}
	return false
}

func sessionCookie(t *testing.T, out *httptest.ResponseRecorder) string {
	t.Helper()
	for _, cookie := range out.Result().Cookies() {
		if cookie.Name == cookieName && cookie.Value != "" {
			if !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode {
				t.Fatalf("the login cookie should be HttpOnly and SameSite=Strict: %+v", cookie)
			}
			return cookie.Name + "=" + cookie.Value
		}
	}
	t.Fatalf("no login cookie: %v", out.Header())
	return ""
}

func TestPageShowsWhatIsHappening(t *testing.T) {
	relay, _, _ := setup()
	pair(relay)
	host(relay, "WXYZ", 3)
	relay.maxRooms = 50
	page, _ := dash(t, relay)

	out := request(page, http.MethodGet, "/", nil, nil)
	if out.Code != http.StatusOK {
		t.Fatalf("status %d: %s", out.Code, out.Body)
	}
	for _, want := range []string{"SPPPD Relay", "ABCD", "WXYZ", "127.0.0.1:3", "/htmx.js", `hx-trigger="every 2s"`, "No users yet", "of 2000 allowed", "of 50 allowed"} {
		if !strings.Contains(out.Body.String(), want) {
			t.Errorf("page lacks %q", want)
		}
	}
	fragment := request(page, http.MethodGet, "/live", nil, nil).Body.String()
	if !strings.Contains(fragment, "WXYZ") || strings.Contains(fragment, "<html") {
		t.Fatalf("live fragment wrong: %s", fragment)
	}
}

func TestActivityIsItsOwnFragment(t *testing.T) {
	relay, _, _ := setup()
	relay.record("oldest line")
	relay.record("newest line")
	page, _ := dash(t, relay)

	body := request(page, http.MethodGet, "/activity", nil, nil).Body.String()
	if strings.Index(body, `data-seq="2"`) > strings.Index(body, `data-seq="1"`) || !strings.Contains(body, `data-seq="1"`) {
		t.Fatalf("newest should come first, numbered: %s", body)
	}
	if strings.Contains(body, "<html") {
		t.Fatalf("activity should be a fragment: %s", body)
	}
	// Part of the two second redraw, it would lose its scroll and selection.
	if live := request(page, http.MethodGet, "/live", nil, nil).Body.String(); strings.Contains(live, "newest line") {
		t.Fatalf("the live section shouldn't hold the activity: %s", live)
	}
	if full := request(page, http.MethodGet, "/", nil, nil).Body.String(); !strings.Contains(full, `data-seq="2"`) {
		t.Fatalf("the page should open with the activity: %s", full)
	}
}

func TestActivityIsEmptyWhenNothingHasHappened(t *testing.T) {
	relay, _, _ := setup()
	page, _ := dash(t, relay)
	// The page's "nothing yet" line is CSS on :empty, which any whitespace would stop.
	if body := request(page, http.MethodGet, "/activity", nil, nil).Body.String(); body != "" {
		t.Fatalf("expected nothing, got %q", body)
	}
}

func TestPageEscapesWhatItShows(t *testing.T) {
	relay, _, _ := setup()
	relay.record("<script>x")
	page, _ := dash(t, relay)
	body := request(page, http.MethodGet, "/activity", nil, nil).Body.String()
	if !strings.Contains(body, "script") || strings.Contains(body, "<script>x") {
		t.Fatalf("an event reached the page raw: %s", body)
	}
}

func TestPageServesHtmx(t *testing.T) {
	relay, _, _ := setup()
	page, _ := dash(t, relay)
	out := request(page, http.MethodGet, "/htmx.js", nil, nil)
	if out.Code != http.StatusOK || !strings.Contains(out.Body.String(), "htmx") {
		t.Fatalf("status %d", out.Code)
	}
}

func TestPageServesFavicon(t *testing.T) {
	relay, _, _ := setup()
	page, _ := dash(t, relay)
	out := request(page, http.MethodGet, "/favicon.svg", nil, nil)
	if out.Code != http.StatusOK || out.Header().Get("Content-Type") != "image/svg+xml" || !strings.Contains(out.Body.String(), "<svg") {
		t.Fatalf("status %d %v", out.Code, out.Header())
	}
}

func TestUnknownPagesAreMissing(t *testing.T) {
	relay, _, _ := setup()
	page, _ := dash(t, relay)
	if got := request(page, http.MethodGet, "/nope", nil, nil).Code; got != http.StatusNotFound {
		t.Fatalf("status %d", got)
	}
}

func TestWithoutUsersForeignHostIsRefused(t *testing.T) {
	relay, _, _ := setup()
	page, _ := dash(t, relay)
	for _, host := range []string{"evil.example", "evil.example:9090", "spppd.hblabs.xyz"} {
		out := request(page, http.MethodGet, "/", nil, map[string]string{"Host": host})
		if out.Code != http.StatusForbidden {
			t.Errorf("%s: status %d", host, out.Code)
		}
	}
	for _, host := range []string{"localhost", "localhost:9090", "127.0.0.1:9090", "[::1]:9090"} {
		out := request(page, http.MethodGet, "/", nil, map[string]string{"Host": host})
		if out.Code != http.StatusOK {
			t.Errorf("%s: status %d", host, out.Code)
		}
	}
}

func TestWithoutUsersForgedHostFromAnotherMachineIsRefused(t *testing.T) {
	relay, _, _ := setup()
	host(relay, "ABCD", 1)
	page, _ := dash(t, relay)
	form := url.Values{"addr": {addr(1).String()}}
	out := request(page, http.MethodPost, "/close", form,
		map[string]string{"Host": "localhost", "Remote": "192.168.1.50:40000"})
	if out.Code != http.StatusForbidden || len(relay.rooms) != 1 {
		t.Fatalf("status %d rooms %v", out.Code, relay.rooms)
	}
}

func TestWithoutUsersLoginPageSaysHowToAddOne(t *testing.T) {
	relay, _, _ := setup()
	page, _ := dash(t, relay)
	if out := request(page, http.MethodGet, "/login", nil, nil); out.Code != http.StatusSeeOther {
		t.Fatalf("on this machine the login page should lead to the page, got %d", out.Code)
	}
	out := request(page, http.MethodGet, "/login", nil, remote())
	if out.Code != http.StatusForbidden || !strings.Contains(out.Body.String(), "relay user add") {
		t.Fatalf("status %d: %s", out.Code, out.Body)
	}
}

func TestUsersMeanEveryoneLogsIn(t *testing.T) {
	relay, _, _ := setup()
	page, store := dash(t, relay)
	if err := store.AddUser("ana", "correct horse", time.Now()); err != nil {
		t.Fatal(err)
	}

	// Even on this machine, which used to be enough.
	if out := request(page, http.MethodGet, "/", nil, nil); out.Code != http.StatusSeeOther || out.Header().Get("Location") != "/login" {
		t.Fatalf("status %d, location %q", out.Code, out.Header().Get("Location"))
	}
	poll := request(page, http.MethodGet, "/live", nil, map[string]string{"HX-Request": "true"})
	if poll.Code != http.StatusUnauthorized || poll.Header().Get("HX-Redirect") != "/login" {
		t.Fatalf("a poll without a login should send htmx to the form, got %d %v", poll.Code, poll.Header())
	}
	if got := request(page, http.MethodPost, "/ban", url.Values{"ip": {"203.0.113.7"}}, nil).Code; got != http.StatusUnauthorized {
		t.Fatalf("status %d", got)
	}
	if _, banned := relay.banned["203.0.113.7"]; banned {
		t.Fatalf("banned without a login")
	}
	if got := request(page, http.MethodGet, "/", nil, map[string]string{"Cookie": cookieName + "=made-up"}).Code; got != http.StatusSeeOther {
		t.Fatalf("a made-up session got status %d", got)
	}
}

func TestLoginWorksFromAnywhere(t *testing.T) {
	relay, _, _ := setup()
	page, store := dash(t, relay)
	if err := store.AddUser("ana", "correct horse", time.Now()); err != nil {
		t.Fatal(err)
	}
	for _, wrong := range []url.Values{
		{"name": {"ana"}, "password": {"wrong horse"}},
		{"name": {"nobody"}, "password": {"correct horse"}},
	} {
		out := request(page, http.MethodPost, "/login", wrong, remote())
		if out.Code != http.StatusUnauthorized || !strings.Contains(out.Body.String(), "Wrong name or password") {
			t.Fatalf("status %d: %s", out.Code, out.Body)
		}
	}
	headers := logIn(t, page, store, "ana")
	out := request(page, http.MethodGet, "/", nil, headers)
	if out.Code != http.StatusOK || !strings.Contains(out.Body.String(), "ana (you)") {
		t.Fatalf("status %d: %s", out.Code, out.Body)
	}
}

func TestTooManyWrongPasswordsLockTheAddressOut(t *testing.T) {
	relay, _, _ := setup()
	page, store := dash(t, relay)
	if err := store.AddUser("ana", "correct horse", time.Now()); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < maxLoginFails; i++ {
		request(page, http.MethodPost, "/login", url.Values{"name": {"ana"}, "password": {"guess"}}, remote())
	}
	right := url.Values{"name": {"ana"}, "password": {"correct horse"}}
	if got := request(page, http.MethodPost, "/login", right, remote()).Code; got != http.StatusTooManyRequests {
		t.Fatalf("status %d", got)
	}
	other := map[string]string{"Host": "172.17.0.2:9090", "Remote": "10.100.0.2:40000"}
	if got := request(page, http.MethodPost, "/login", right, other).Code; got != http.StatusSeeOther {
		t.Fatalf("another address should still get in, got %d", got)
	}
}

func TestLimiterForgivesAfterAWhile(t *testing.T) {
	limiter := &loginLimiter{fails: make(map[string]*loginFails)}
	now := time.Unix(1000, 0)
	for i := 0; i < maxLoginFails; i++ {
		limiter.fail("1.2.3.4", now)
	}
	if limiter.allowed("1.2.3.4", now) {
		t.Fatal("should be locked out")
	}
	if !limiter.allowed("1.2.3.4", now.Add(loginLockout+time.Second)) {
		t.Fatal("should be let back in")
	}
}

func TestLogoutEndsTheLogin(t *testing.T) {
	relay, _, _ := setup()
	page, store := dash(t, relay)
	headers := logIn(t, page, store, "ana")
	headers["HX-Request"] = "true"
	out := request(page, http.MethodPost, "/logout", nil, headers)
	if out.Header().Get("HX-Redirect") != "/login" {
		t.Fatalf("htmx should be sent to the form: %v", out.Header())
	}
	delete(headers, "HX-Request")
	if got := request(page, http.MethodGet, "/", nil, headers).Code; got != http.StatusSeeOther {
		t.Fatalf("still logged in: status %d", got)
	}
}

func TestFirstUserAddedHereLogsThemIn(t *testing.T) {
	relay, _, _ := setup()
	page, store := dash(t, relay)
	out := request(page, http.MethodPost, "/users/add", url.Values{"name": {"ana"}, "password": {"correct horse"}}, nil)
	if out.Header().Get("HX-Refresh") != "true" || !store.HasUsers() {
		t.Fatalf("status %d %v: %s", out.Code, out.Header(), out.Body)
	}
	cookie := sessionCookie(t, out)
	if got := request(page, http.MethodGet, "/", nil, nil).Code; got != http.StatusSeeOther {
		t.Fatalf("with a user, this machine needs a login too, got %d", got)
	}
	if got := request(page, http.MethodGet, "/", nil, map[string]string{"Cookie": cookie}).Code; got != http.StatusOK {
		t.Fatalf("whoever added the user should be logged in, got %d", got)
	}
}

func TestUsersSection(t *testing.T) {
	relay, _, _ := setup()
	page, store := dash(t, relay)
	ana := logIn(t, page, store, "ana")

	body := request(page, http.MethodPost, "/users/add", url.Values{"name": {"bo"}, "password": {"short"}}, ana).Body.String()
	if !strings.Contains(body, errBadPassword.Error()) {
		t.Fatalf("a short password should be refused: %s", body)
	}
	body = request(page, http.MethodPost, "/users/add", url.Values{"name": {"bo"}, "password": {"correct horse"}}, ana).Body.String()
	if !strings.Contains(body, "Added bo") || !userExists(store, "bo") {
		t.Fatalf("bo wasn't added: %s", body)
	}
	body = request(page, http.MethodPost, "/users/add", url.Values{"name": {"bo"}, "password": {"correct horse"}}, ana).Body.String()
	if !strings.Contains(body, errUserExists.Error()) {
		t.Fatalf("a taken name should be refused: %s", body)
	}
	body = request(page, http.MethodPost, "/users/delete", url.Values{"name": {"ana"}}, ana).Body.String()
	if !strings.Contains(body, "remove yourself") || !userExists(store, "ana") {
		t.Fatalf("ana removed herself: %s", body)
	}
	bo := logIn(t, page, store, "bo")
	request(page, http.MethodPost, "/users/delete", url.Values{"name": {"bo"}}, ana)
	if userExists(store, "bo") {
		t.Fatal("bo is still there")
	}
	if got := request(page, http.MethodGet, "/", nil, bo).Code; got != http.StatusSeeOther {
		t.Fatalf("a removed user's login should end, got %d", got)
	}
}

func TestChangingPasswordEndsOtherLogins(t *testing.T) {
	relay, _, _ := setup()
	page, store := dash(t, relay)
	laptop := logIn(t, page, store, "ana")
	phone := logIn(t, page, store, "ana")

	out := request(page, http.MethodPost, "/users/password", url.Values{"current": {"wrong"}, "password": {"battery staple"}}, laptop)
	if !strings.Contains(out.Body.String(), "current password is wrong") {
		t.Fatalf("changed without the current password: %s", out.Body)
	}
	out = request(page, http.MethodPost, "/users/password", url.Values{"current": {"correct horse"}, "password": {"battery staple"}}, laptop)
	if !strings.Contains(out.Body.String(), "Password changed") {
		t.Fatalf("not changed: %s", out.Body)
	}
	laptop["Cookie"] = sessionCookie(t, out)
	if got := request(page, http.MethodGet, "/", nil, laptop).Code; got != http.StatusOK {
		t.Fatalf("the page that changed it should stay logged in, got %d", got)
	}
	if got := request(page, http.MethodGet, "/", nil, phone).Code; got != http.StatusSeeOther {
		t.Fatalf("other logins should end, got %d", got)
	}
	if !store.CheckPassword("ana", "battery staple") {
		t.Fatal("the new password doesn't work")
	}
}

func TestForeignOriginCannotAct(t *testing.T) {
	relay, _, _ := setup()
	host(relay, "ABCD", 1)
	page, store := dash(t, relay)
	form := url.Values{"addr": {addr(1).String()}}
	out := request(page, http.MethodPost, "/close", form, map[string]string{"Origin": "https://evil.example"})
	if out.Code != http.StatusForbidden || len(relay.rooms) != 1 {
		t.Fatalf("status %d rooms %v", out.Code, relay.rooms)
	}
	if err := store.AddUser("ana", "correct horse", time.Now()); err != nil {
		t.Fatal(err)
	}
	login := url.Values{"name": {"ana"}, "password": {"correct horse"}}
	if got := request(page, http.MethodPost, "/login", login, map[string]string{"Origin": "https://evil.example"}).Code; got != http.StatusForbidden {
		t.Fatalf("another site shouldn't be able to log a browser in, got %d", got)
	}
}

func TestSameOriginCanAct(t *testing.T) {
	relay, _, _ := setup()
	host(relay, "ABCD", 1)
	page, _ := dash(t, relay)
	form := url.Values{"addr": {addr(1).String()}}
	out := request(page, http.MethodPost, "/close", form, map[string]string{"Origin": "http://localhost:9090"})
	if out.Code != http.StatusOK || len(relay.rooms) != 0 {
		t.Fatalf("status %d rooms %v", out.Code, relay.rooms)
	}
}

func TestActionsAreNotReachableByGet(t *testing.T) {
	relay, _, _ := setup()
	host(relay, "ABCD", 1)
	page, _ := dash(t, relay)
	out := request(page, http.MethodGet, "/close?addr="+addr(1).String(), nil, nil)
	if out.Code != http.StatusMethodNotAllowed || len(relay.rooms) != 1 {
		t.Fatalf("status %d rooms %v", out.Code, relay.rooms)
	}
}

func TestBanAndUnbanThroughThePage(t *testing.T) {
	relay, _, _ := setup()
	page, store := dash(t, relay)
	ana := logIn(t, page, store, "ana")

	if got := request(page, http.MethodPost, "/ban", url.Values{"ip": {"nonsense"}}, ana).Code; got != http.StatusBadRequest {
		t.Fatalf("status %d", got)
	}
	body := request(page, http.MethodPost, "/ban", url.Values{"ip": {"203.0.113.7"}}, ana).Body.String()
	if !strings.Contains(body, "203.0.113.7") || relay.banned["203.0.113.7"].By != "ana" {
		t.Fatalf("ban missing or not credited to ana: %s", body)
	}
	if bans, _ := store.Bans(); len(bans) != 1 || bans[0].By != "ana" {
		t.Fatalf("ban not saved: %v", bans)
	}
	request(page, http.MethodPost, "/unban", url.Values{"ip": {"203.0.113.7"}}, ana)
	if _, banned := relay.banned["203.0.113.7"]; banned {
		t.Fatalf("still banned")
	}
	if bans, _ := store.Bans(); len(bans) != 0 {
		t.Fatalf("unban not saved: %v", bans)
	}
}

func TestAnalyticsAreHiddenWhenOff(t *testing.T) {
	relay, _, _ := setup()
	page, _ := dash(t, relay)
	for _, path := range []string{"/analytics", "/export/daily.csv", "/export/races.csv"} {
		if got := request(page, http.MethodGet, path, nil, nil).Code; got != http.StatusNotFound {
			t.Errorf("%s: status %d", path, got)
		}
	}
	if body := request(page, http.MethodGet, "/", nil, nil).Body.String(); strings.Contains(body, "Analytics") {
		t.Fatal("the page shows analytics that are off")
	}
}

func TestAnalyticsOnThePageAndExported(t *testing.T) {
	relay, _, _ := setup()
	page, store := dash(t, relay)
	key, _ := store.AnalyticsKey()
	relay.EnableAnalytics(key)
	pair(relay)

	body := request(page, http.MethodGet, "/", nil, nil).Body.String()
	for _, want := range []string{"Analytics", "unique IPs, last 7 days", "1970-01-01", "/export/daily.csv"} {
		if !strings.Contains(body, want) {
			t.Errorf("page lacks %q", want)
		}
	}
	out := request(page, http.MethodGet, "/export/daily.csv", nil, nil)
	if out.Code != http.StatusOK || out.Header().Get("Content-Type") != "text/csv; charset=utf-8" ||
		!strings.Contains(out.Header().Get("Content-Disposition"), "attachment") {
		t.Fatalf("status %d %v", out.Code, out.Header())
	}
	lines := strings.Split(strings.TrimSpace(out.Body.String()), "\n")
	if len(lines) != 2 || !strings.HasPrefix(lines[0], "day,unique_ips,rooms,joins") || !strings.HasPrefix(lines[1], "1970-01-01,1,1,1,") {
		t.Fatalf("daily.csv: %q", lines)
	}
	if body := request(page, http.MethodGet, "/export/races.csv", nil, nil).Body.String(); !strings.HasPrefix(body, "started,ended,seconds,players,protocol") {
		t.Fatalf("races.csv: %q", body)
	}
}

func TestFormats(t *testing.T) {
	ages := map[time.Duration]string{
		9 * time.Second:   "9s",
		192 * time.Second: "3m 12s",
		2 * time.Hour:     "2h 0m",
		49 * time.Hour:    "2d 1h",
	}
	for in, want := range ages {
		if got := formatAge(in); got != want {
			t.Errorf("%v: got %q want %q", in, got, want)
		}
	}
	sizes := map[uint64]string{512: "512 B", 2048: "2.0 KB", 3 * 1024 * 1024: "3.0 MB"}
	for in, want := range sizes {
		if got := formatBytes(in); got != want {
			t.Errorf("%d: got %q want %q", in, got, want)
		}
	}
}
