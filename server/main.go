// Relay server for SPPPD online races. One player hosts a room, another joins
// with its code, and from then on every packet is forwarded to the partner.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	maxCodeLength  = 16
	maxPacketBytes = 2048
	maxEvents      = 200
)

// Sender delivers a packet to an address. Tests replace the real socket.
type Sender func(data []byte, to *net.UDPAddr)

type Client struct {
	Addr     *net.UDPAddr
	LastSeen time.Time
	Since    time.Time
	RoomCode string
	Partner  *Client
}

// Traffic counts packets and bytes in each direction.
type Traffic struct {
	PacketsIn, PacketsOut uint64
	BytesIn, BytesOut     uint64
}

func (t Traffic) minus(other Traffic) Traffic {
	return Traffic{
		PacketsIn:  t.PacketsIn - other.PacketsIn,
		PacketsOut: t.PacketsOut - other.PacketsOut,
		BytesIn:    t.BytesIn - other.BytesIn,
		BytesOut:   t.BytesOut - other.BytesOut,
	}
}

// Event is one line of the dashboard's recent activity.
type Event struct {
	At   time.Time
	Text string
}

type Relay struct {
	mu      sync.Mutex
	clients map[string]*Client
	rooms   map[string]*Client
	banned  map[string]bool
	events  []Event
	total   Traffic
	sampled Traffic
	rate    Traffic
	started time.Time
	send    Sender
	now     func() time.Time
}

func NewRelay(send Sender) *Relay {
	r := &Relay{
		clients: make(map[string]*Client),
		rooms:   make(map[string]*Client),
		banned:  make(map[string]bool),
		started: time.Now(),
		now:     time.Now,
	}
	r.send = func(data []byte, to *net.UDPAddr) {
		r.total.PacketsOut++
		r.total.BytesOut += uint64(len(data))
		send(data, to)
	}
	return r
}

// record keeps a line for the dashboard. Callers hold the lock.
func (r *Relay) record(text string) {
	r.events = append(r.events, Event{At: r.now(), Text: text})
	if len(r.events) > maxEvents {
		r.events = r.events[1:]
	}
}

// event records a line and writes it to the log. Callers hold the lock.
func (r *Relay) event(format string, args ...any) {
	text := fmt.Sprintf(format, args...)
	log.Print(text)
	r.record(text)
}

// refuse turns a player away. It stays out of the log, because anyone can
// send these as fast as they like.
func (r *Relay) refuse(reason string, addr *net.UDPAddr) {
	r.send([]byte("event|error|"+reason), addr)
	r.record(fmt.Sprintf("[REFUSED] %v: %s", addr, reason))
}

// Handle processes one packet from addr.
func (r *Relay) Handle(data []byte, addr *net.UDPAddr) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.total.PacketsIn++
	r.total.BytesIn += uint64(len(data))
	if r.banned[addr.IP.String()] {
		return
	}

	key := addr.String()
	client := r.clients[key]
	parts := strings.SplitN(string(data), "|", 3)
	isEvent := len(parts) >= 2 && parts[0] == "event"

	if client == nil {
		if isEvent && len(parts) == 3 {
			r.register(parts[1], parts[2], addr)
		}
		return
	}

	client.LastSeen = r.now()

	if isEvent {
		switch parts[1] {
		case "leave":
			r.event("[LEAVE] %v", client.Addr)
			r.drop(client)
			return
		case "host":
			// The acknowledgement may have been lost, so repeat it.
			if client.Partner == nil {
				r.send([]byte("event|hosting|"+client.RoomCode), client.Addr)
				return
			}
		case "join":
			if client.Partner != nil {
				r.send([]byte("event|start_race|join"), client.Addr)
				return
			}
		}
	}

	if client.Partner != nil {
		r.send(data, client.Partner.Addr)
	}
}

func (r *Relay) register(intent, code string, addr *net.UDPAddr) {
	// Stragglers from a race that just ended aren't asking for a room.
	if intent != "host" && intent != "join" {
		return
	}
	if code == "" || len(code) > maxCodeLength {
		r.refuse("Room codes are 1 to 16 characters", addr)
		return
	}

	client := &Client{Addr: addr, LastSeen: r.now(), Since: r.now(), RoomCode: code}
	switch intent {
	case "host":
		if _, taken := r.rooms[code]; taken {
			r.refuse("That room code is taken", addr)
			return
		}
		r.rooms[code] = client
		r.clients[addr.String()] = client
		r.send([]byte("event|hosting|"+code), addr)
		r.event("[HOST] %v created room %q", addr, code)
	case "join":
		host, found := r.rooms[code]
		if !found {
			r.refuse("No room with that code", addr)
			return
		}
		client.Partner = host
		host.Partner = client
		r.clients[addr.String()] = client
		delete(r.rooms, code)
		r.event("[JOIN] %v joined room %q with %v", addr, code, host.Addr)
		r.send([]byte("event|start_race|host"), host.Addr)
		r.send([]byte("event|start_race|join"), addr)
	}
}

// drop removes a client and tells its partner, who is removed too.
func (r *Relay) drop(client *Client) {
	delete(r.clients, client.Addr.String())
	if r.rooms[client.RoomCode] == client {
		delete(r.rooms, client.RoomCode)
	}
	if partner := client.Partner; partner != nil {
		r.send([]byte("event|error|Opponent disconnected"), partner.Addr)
		delete(r.clients, partner.Addr.String())
		client.Partner, partner.Partner = nil, nil
	}
}

// Sweep runs once a second. It drops clients that have gone quiet, giving
// waiting hosts longer, and works out the traffic rates.
func (r *Relay) Sweep(racing, waiting time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.rate = r.total.minus(r.sampled)
	r.sampled = r.total

	now := r.now()
	for _, client := range r.clients {
		limit := waiting
		if client.Partner != nil {
			limit = racing
		}
		if now.Sub(client.LastSeen) > limit {
			r.event("[TIMEOUT] %v", client.Addr)
			r.drop(client)
		}
	}
}

// closeClient removes a client on the dashboard's orders. Callers hold the lock.
func (r *Relay) closeClient(client *Client) {
	r.send([]byte("event|error|Room closed by the server"), client.Addr)
	r.drop(client)
}

// Close removes the client at addr, along with anyone racing it.
func (r *Relay) Close(addr string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	client := r.clients[addr]
	if client == nil {
		return false
	}
	r.event("[CLOSE] %v in room %q", client.Addr, client.RoomCode)
	r.closeClient(client)
	return true
}

// Ban ignores an IP until Unban or a restart, and removes its clients now.
func (r *Relay) Ban(ip string) bool {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()

	ip = parsed.String()
	r.banned[ip] = true
	r.event("[BAN] %s", ip)
	for _, client := range r.clients {
		if client.Addr.IP.String() == ip {
			r.closeClient(client)
		}
	}
	return true
}

func (r *Relay) Unban(ip string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.banned[ip] {
		delete(r.banned, ip)
		r.event("[UNBAN] %s", ip)
	}
}

// Room is a host waiting for a driver.
type Room struct {
	Code, Host, HostIP string
	Age                time.Duration
}

// Race is a pair of connected drivers.
type Race struct {
	Code              string
	First, Second     string
	FirstIP, SecondIP string
	Age               time.Duration
}

// Snapshot is a copy of the relay's state, safe to read without the lock.
type Snapshot struct {
	Uptime  time.Duration
	Players int
	Rooms   []Room
	Races   []Race
	Banned  []string
	Events  []Event // newest first
	Total   Traffic
	Rate    Traffic
}

func (r *Relay) Snapshot() Snapshot {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := r.now()
	snap := Snapshot{
		Uptime:  now.Sub(r.started),
		Players: len(r.clients),
		Total:   r.total,
		Rate:    r.rate,
	}
	for code, host := range r.rooms {
		snap.Rooms = append(snap.Rooms, Room{
			Code: code, Host: host.Addr.String(), HostIP: host.Addr.IP.String(), Age: now.Sub(host.Since),
		})
	}
	for key, client := range r.clients {
		partner := client.Partner
		if partner == nil || key > partner.Addr.String() {
			continue // each pair is listed once
		}
		started := client.Since
		if partner.Since.After(started) {
			started = partner.Since
		}
		snap.Races = append(snap.Races, Race{
			Code: client.RoomCode, Age: now.Sub(started),
			First: key, FirstIP: client.Addr.IP.String(),
			Second: partner.Addr.String(), SecondIP: partner.Addr.IP.String(),
		})
	}
	for ip := range r.banned {
		snap.Banned = append(snap.Banned, ip)
	}
	sort.Slice(snap.Rooms, func(i, j int) bool { return snap.Rooms[i].Code < snap.Rooms[j].Code })
	sort.Slice(snap.Races, func(i, j int) bool { return snap.Races[i].First < snap.Races[j].First })
	sort.Strings(snap.Banned)
	for i := len(r.events) - 1; i >= 0; i-- {
		snap.Events = append(snap.Events, r.events[i])
	}
	return snap
}

func main() {
	listen := flag.String("addr", ":8080", "UDP address to listen on")
	racing := flag.Duration("race-timeout", 5*time.Second, "drop a racer after this long without packets")
	waiting := flag.Duration("wait-timeout", 60*time.Second, "drop a waiting host after this long without packets")
	dashboard := flag.String("dashboard", "", "HTTP address for the dashboard, which has no login, so keep it on loopback (off if empty)")
	flag.Parse()

	addr, err := net.ResolveUDPAddr("udp", *listen)
	if err != nil {
		log.Fatalf("Failed to resolve UDP address: %v", err)
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Fatalf("Failed to start UDP listener: %v", err)
	}
	defer conn.Close()
	log.Printf("Relay server listening on %v", conn.LocalAddr())

	relay := NewRelay(func(data []byte, to *net.UDPAddr) {
		if _, err := conn.WriteToUDP(data, to); err != nil {
			log.Printf("[SEND] %v: %v", to, err)
		}
	})

	if *dashboard != "" {
		go func() {
			log.Printf("Dashboard listening on %s", *dashboard)
			log.Fatalf("Dashboard stopped: %v", http.ListenAndServe(*dashboard, newDashboard(relay)))
		}()
	}

	go func() {
		for range time.Tick(time.Second) {
			relay.Sweep(*racing, *waiting)
		}
	}()

	buffer := make([]byte, maxPacketBytes)
	for {
		n, remote, err := conn.ReadFromUDP(buffer)
		if err != nil || n == 0 {
			continue
		}
		relay.Handle(buffer[:n], remote)
	}
}
