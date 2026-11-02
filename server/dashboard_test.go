package main

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
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

func TestPageShowsWhatIsHappening(t *testing.T) {
	relay, _, _ := setup()
	pair(relay)
	host(relay, "WXYZ", 3)
	page := newDashboard(relay, "")

	out := request(page, http.MethodGet, "/", nil, nil)
	if out.Code != http.StatusOK {
		t.Fatalf("status %d: %s", out.Code, out.Body)
	}
	for _, want := range []string{"SPPPD Relay", "ABCD", "WXYZ", "127.0.0.1:3", "/htmx.js", `hx-trigger="every 2s"`} {
		if !strings.Contains(out.Body.String(), want) {
			t.Errorf("page lacks %q", want)
		}
	}
	fragment := request(page, http.MethodGet, "/live", nil, nil).Body.String()
	if !strings.Contains(fragment, "WXYZ") || strings.Contains(fragment, "<html") {
		t.Fatalf("live should be a fragment: %s", fragment)
	}
}

func TestPageEscapesWhatItShows(t *testing.T) {
	relay, _, _ := setup()
	relay.record("<script>x")
	body := request(newDashboard(relay, ""), http.MethodGet, "/live", nil, nil).Body.String()
	if strings.Contains(body, "<script>x") {
		t.Fatalf("an event reached the page raw: %s", body)
	}
}

func TestPageServesHtmx(t *testing.T) {
	relay, _, _ := setup()
	out := request(newDashboard(relay, ""), http.MethodGet, "/htmx.js", nil, nil)
	if out.Code != http.StatusOK || !strings.Contains(out.Body.String(), "htmx") {
		t.Fatalf("status %d", out.Code)
	}
}

func TestUnknownPagesAreMissing(t *testing.T) {
	relay, _, _ := setup()
	if got := request(newDashboard(relay, ""), http.MethodGet, "/nope", nil, nil).Code; got != http.StatusNotFound {
		t.Fatalf("status %d", got)
	}
}

func TestForeignHostIsRefused(t *testing.T) {
	relay, _, _ := setup()
	page := newDashboard(relay, "")
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

func TestForgedHostFromAnotherMachineIsRefused(t *testing.T) {
	relay, _, _ := setup()
	host(relay, "ABCD", 1)
	form := url.Values{"addr": {addr(1).String()}}
	out := request(newDashboard(relay, ""), http.MethodPost, "/close", form,
		map[string]string{"Host": "localhost", "Remote": "192.168.1.50:40000"})
	if out.Code != http.StatusForbidden || len(relay.rooms) != 1 {
		t.Fatalf("status %d rooms %v", out.Code, relay.rooms)
	}
}

func TestTokenLetsItsHolderInFromAnywhere(t *testing.T) {
	relay, _, _ := setup()
	page := newDashboard(relay, "letmein")
	remote := map[string]string{"Host": "172.17.0.2:9090", "Remote": "172.17.0.1:40000"}

	out := request(page, http.MethodGet, "/", nil, remote)
	if out.Code != http.StatusUnauthorized || out.Header().Get("WWW-Authenticate") == "" {
		t.Fatalf("status %d", out.Code)
	}
	remote["Authorization"] = "Basic " + base64.StdEncoding.EncodeToString([]byte("admin:wrong"))
	if got := request(page, http.MethodGet, "/", nil, remote).Code; got != http.StatusUnauthorized {
		t.Fatalf("status %d", got)
	}
	remote["Authorization"] = "Basic " + base64.StdEncoding.EncodeToString([]byte("admin:letmein"))
	if got := request(page, http.MethodGet, "/", nil, remote).Code; got != http.StatusOK {
		t.Fatalf("status %d", got)
	}
}

func TestTokenIsNeededOnLoopbackToo(t *testing.T) {
	relay, _, _ := setup()
	if got := request(newDashboard(relay, "letmein"), http.MethodGet, "/", nil, nil).Code; got != http.StatusUnauthorized {
		t.Fatalf("status %d", got)
	}
}

func TestForeignOriginCannotAct(t *testing.T) {
	relay, _, _ := setup()
	host(relay, "ABCD", 1)
	form := url.Values{"addr": {addr(1).String()}}
	out := request(newDashboard(relay, ""), http.MethodPost, "/close", form, map[string]string{"Origin": "https://evil.example"})
	if out.Code != http.StatusForbidden || len(relay.rooms) != 1 {
		t.Fatalf("status %d rooms %v", out.Code, relay.rooms)
	}
}

func TestSameOriginCanAct(t *testing.T) {
	relay, _, _ := setup()
	host(relay, "ABCD", 1)
	form := url.Values{"addr": {addr(1).String()}}
	out := request(newDashboard(relay, ""), http.MethodPost, "/close", form, map[string]string{"Origin": "http://localhost:9090"})
	if out.Code != http.StatusOK || len(relay.rooms) != 0 {
		t.Fatalf("status %d rooms %v", out.Code, relay.rooms)
	}
}

func TestActionsAreNotReachableByGet(t *testing.T) {
	relay, _, _ := setup()
	host(relay, "ABCD", 1)
	out := request(newDashboard(relay, ""), http.MethodGet, "/close?addr="+addr(1).String(), nil, nil)
	if out.Code != http.StatusMethodNotAllowed || len(relay.rooms) != 1 {
		t.Fatalf("status %d rooms %v", out.Code, relay.rooms)
	}
}

func TestBanAndUnbanThroughThePage(t *testing.T) {
	relay, _, _ := setup()
	page := newDashboard(relay, "")

	if got := request(page, http.MethodPost, "/ban", url.Values{"ip": {"nonsense"}}, nil).Code; got != http.StatusBadRequest {
		t.Fatalf("status %d", got)
	}
	body := request(page, http.MethodPost, "/ban", url.Values{"ip": {"203.0.113.7"}}, nil).Body.String()
	if !strings.Contains(body, "203.0.113.7") || !relay.banned["203.0.113.7"] {
		t.Fatalf("ban missing: %s", body)
	}
	request(page, http.MethodPost, "/unban", url.Values{"ip": {"203.0.113.7"}}, nil)
	if relay.banned["203.0.113.7"] {
		t.Fatalf("still banned")
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
