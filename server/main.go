// Relay server for SPPPD online races. A host opens a room, up to three others
// join with its code, and from then on every packet goes to the rest of the
// room, stamped with the seat it came from. The relay reads nothing it forwards.
package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	maxCodeLength  = 16
	maxPacketBytes = 2048
	maxEvents      = 200
	maxRoomPlayers = 4
	maxPerIP       = 16 // a whole LAN party can share one address
	maxRateEntries = 1 << 16
)

var eventPrefix = []byte("event|")

// Sender delivers a packet to an address. Tests replace the real socket.
type Sender func(data []byte, to *net.UDPAddr)

type Client struct {
	Addr     *net.UDPAddr
	LastSeen time.Time
	Room     *Room
	Slot     int // 1 to maxRoomPlayers
}

// Room is a group of up to four drivers. Seat 1 is the host. A locked room has
// started racing and takes nobody new. Its code stays taken until it empties.
type Room struct {
	Code   string
	Proto  string
	Since  time.Time
	Locked bool
	Seats  [maxRoomPlayers]*Client
}

func (room *Room) members() []*Client {
	out := make([]*Client, 0, maxRoomPlayers)
	for _, client := range room.Seats {
		if client != nil {
			out = append(out, client)
		}
	}
	return out
}

// rateBucket is a token bucket for one IP.
type rateBucket struct {
	tokens float64
	last   time.Time
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
	mu         sync.Mutex
	clients    map[string]*Client
	rooms      map[string]*Room
	banned     map[string]bool
	perIP      map[string]int
	buckets    map[string]*rateBucket
	rate       float64 // packets a second per IP, 0 for no limit
	maxPlayers int
	events     []Event
	total      Traffic
	sampled    Traffic
	perSecond  Traffic
	dropped    uint64
	started    time.Time
	send       Sender
	now        func() time.Time
}

func NewRelay(send Sender) *Relay {
	r := &Relay{
		clients:    make(map[string]*Client),
		rooms:      make(map[string]*Room),
		banned:     make(map[string]bool),
		perIP:      make(map[string]int),
		buckets:    make(map[string]*rateBucket),
		rate:       300,
		maxPlayers: 2000,
		started:    time.Now(),
		now:        time.Now,
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

// allow spends one token from an IP's bucket. Callers hold the lock.
func (r *Relay) allow(ip string) bool {
	if r.rate <= 0 {
		return true
	}
	now := r.now()
	burst := r.rate * 2
	bucket := r.buckets[ip]
	if bucket == nil {
		// Forged sources can't grow this without limit.
		if len(r.buckets) >= maxRateEntries {
			return false
		}
		bucket = &rateBucket{tokens: burst, last: now}
		r.buckets[ip] = bucket
	}
	bucket.tokens = min(burst, bucket.tokens+now.Sub(bucket.last).Seconds()*r.rate)
	bucket.last = now
	if bucket.tokens < 1 {
		return false
	}
	bucket.tokens--
	return true
}

// Handle processes one packet from addr.
func (r *Relay) Handle(data []byte, addr *net.UDPAddr) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.total.PacketsIn++
	r.total.BytesIn += uint64(len(data))
	ip := addr.IP.String()
	if r.banned[ip] {
		return
	}
	if len(data) > maxPacketBytes || !r.allow(ip) {
		r.dropped++
		return
	}

	client := r.clients[addr.String()]
	if client != nil {
		client.LastSeen = r.now()
	}
	if !bytes.HasPrefix(data, eventPrefix) {
		if client != nil {
			r.forward(client, data)
		}
		return
	}

	parts := strings.SplitN(string(data), "|", 4)
	if client == nil {
		r.register(parts, addr)
		return
	}
	switch parts[1] {
	case "leave":
		r.event("[LEAVE] %v", client.Addr)
		r.remove(client)
	case "lock":
		client.Room.Locked = true
	case "host", "join":
		// The answer may have been lost, so repeat it.
		r.tell(client)
	}
}

// forward passes a packet to the rest of the room, stamped with its sender's
// seat so nobody can pose as someone else. Callers hold the lock.
func (r *Relay) forward(from *Client, data []byte) {
	out := make([]byte, 0, len(data)+2)
	out = strconv.AppendInt(out, int64(from.Slot), 10)
	out = append(out, '|')
	out = append(out, data...)
	for _, client := range from.Room.Seats {
		if client != nil && client != from {
			r.send(out, client.Addr)
		}
	}
}

// tell sends one client the room as it stands: its own seat, the room's code,
// the seats taken, and whether it has locked.
func (r *Relay) tell(client *Client) {
	room := client.Room
	seats := make([]string, 0, maxRoomPlayers)
	for _, member := range room.members() {
		seats = append(seats, strconv.Itoa(member.Slot))
	}
	locked := 0
	if room.Locked {
		locked = 1
	}
	r.send([]byte(fmt.Sprintf("event|room|%d|%s|%s|%d", client.Slot, room.Code, strings.Join(seats, ","), locked)), client.Addr)
}

func (r *Relay) announce(room *Room) {
	for _, member := range room.members() {
		r.tell(member)
	}
}

func validCode(code string) bool {
	if code == "" || len(code) > maxCodeLength {
		return false
	}
	for _, c := range []byte(code) {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

func validProto(proto string) bool {
	if proto == "" || len(proto) > 4 {
		return false
	}
	_, err := strconv.Atoi(proto)
	return err == nil
}

// seat adds a client to a room. Callers have checked there's a free seat.
func (r *Relay) seat(room *Room, slot int, addr *net.UDPAddr) *Client {
	client := &Client{Addr: addr, LastSeen: r.now(), Room: room, Slot: slot}
	room.Seats[slot-1] = client
	r.clients[addr.String()] = client
	r.perIP[addr.IP.String()]++
	return client
}

// register handles a host or join from an unknown address. Stragglers from a
// race that just ended aren't asking for a room, and get no answer.
func (r *Relay) register(parts []string, addr *net.UDPAddr) {
	if len(parts) < 3 || (parts[1] != "host" && parts[1] != "join") {
		return
	}
	// Clients from before protocol 2 send event|host|CODE, and show this.
	if len(parts) == 3 {
		r.refuse("This game is out of date. Update it to play online", addr)
		return
	}
	intent, proto, code := parts[1], parts[2], parts[3]
	if !validProto(proto) {
		return
	}
	if !validCode(code) {
		r.refuse("Room codes are 1 to 16 letters or numbers", addr)
		return
	}
	if len(r.clients) >= r.maxPlayers {
		r.refuse("The server is full", addr)
		return
	}
	if r.perIP[addr.IP.String()] >= maxPerIP {
		r.refuse("Too many connections from your address", addr)
		return
	}

	switch intent {
	case "host":
		if _, taken := r.rooms[code]; taken {
			r.refuse("That room code is taken", addr)
			return
		}
		room := &Room{Code: code, Proto: proto, Since: r.now()}
		r.rooms[code] = room
		r.tell(r.seat(room, 1, addr))
		r.event("[HOST] %v created room %q", addr, code)
	case "join":
		room, found := r.rooms[code]
		if !found {
			r.refuse("No room with that code", addr)
			return
		}
		if room.Proto != proto {
			r.refuse("That room is on a different version of the game", addr)
			return
		}
		if room.Locked {
			r.refuse("That race has already started", addr)
			return
		}
		for slot := 1; slot <= maxRoomPlayers; slot++ {
			if room.Seats[slot-1] == nil {
				r.seat(room, slot, addr)
				r.event("[JOIN] %v joined room %q in seat %d", addr, code, slot)
				r.announce(room)
				return
			}
		}
		r.refuse("That room is full", addr)
	}
}

func (r *Relay) forget(client *Client) {
	key := client.Addr.String()
	if r.clients[key] != client {
		return
	}
	delete(r.clients, key)
	ip := client.Addr.IP.String()
	if r.perIP[ip]--; r.perIP[ip] <= 0 {
		delete(r.perIP, ip)
	}
	client.Room.Seats[client.Slot-1] = nil
}

// closeRoom empties a room, telling everyone in it why.
func (r *Relay) closeRoom(room *Room, reason string) {
	for _, member := range room.members() {
		r.send([]byte("event|closed|"+reason), member.Addr)
		r.forget(member)
	}
	delete(r.rooms, room.Code)
}

// remove takes one client out. A lobby can't go on without its host, because
// the race is the host's to set. A locked room can: everything needed to race
// again is already with the others.
func (r *Relay) remove(client *Client) {
	room := client.Room
	r.forget(client)
	if client.Slot == 1 && !room.Locked {
		r.closeRoom(room, "The host left the room")
		return
	}
	if len(room.members()) == 0 {
		delete(r.rooms, room.Code)
		return
	}
	r.announce(room)
}

// Sweep runs once a second. It drops clients that have gone quiet, giving
// someone alone in a room longer, works out the traffic rates, and repeats each
// room's state, so a lost update heals and clients know the relay is alive.
func (r *Relay) Sweep(racing, waiting time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.perSecond = r.total.minus(r.sampled)
	r.sampled = r.total

	now := r.now()
	for _, client := range r.clients {
		limit := waiting
		if len(client.Room.members()) > 1 {
			limit = racing
		}
		if now.Sub(client.LastSeen) > limit {
			r.event("[TIMEOUT] %v", client.Addr)
			r.remove(client)
		}
	}
	for _, room := range r.rooms {
		r.announce(room)
	}
	for ip, bucket := range r.buckets {
		if now.Sub(bucket.last) > 10*time.Second {
			delete(r.buckets, ip)
		}
	}
}

// Close removes the room the client at addr is in, with everyone in it.
func (r *Relay) Close(addr string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	client := r.clients[addr]
	if client == nil {
		return false
	}
	r.event("[CLOSE] room %q", client.Room.Code)
	r.closeRoom(client.Room, "Room closed by the server")
	return true
}

// Ban ignores an IP until Unban or a restart, and removes its clients now.
// Anyone else in their rooms carries on without them.
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
			r.send([]byte("event|closed|Removed by the server"), client.Addr)
			r.remove(client)
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

// Shutdown tells everyone the relay is going away.
func (r *Relay) Shutdown() {
	r.mu.Lock()
	defer r.mu.Unlock()

	for _, room := range r.rooms {
		r.closeRoom(room, "The server is restarting")
	}
}

// Driver is one seat in a room, for the dashboard.
type Driver struct {
	Slot int
	Addr string
	IP   string
}

// RoomView is a room as the dashboard shows it.
type RoomView struct {
	Code    string
	Drivers []Driver
	First   string // any address in the room, which is what /close takes
	Age     time.Duration
}

// Snapshot is a copy of the relay's state, safe to read without the lock.
type Snapshot struct {
	Uptime  time.Duration
	Players int
	Rooms   []RoomView // still open to join
	Races   []RoomView // locked and racing
	Banned  []string
	Events  []Event // newest first
	Total   Traffic
	Rate    Traffic
	Dropped uint64
}

func (r *Relay) Snapshot() Snapshot {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := r.now()
	snap := Snapshot{
		Uptime:  now.Sub(r.started),
		Players: len(r.clients),
		Total:   r.total,
		Rate:    r.perSecond,
		Dropped: r.dropped,
	}
	for code, room := range r.rooms {
		view := RoomView{Code: code, Age: now.Sub(room.Since)}
		for _, member := range room.members() {
			view.Drivers = append(view.Drivers, Driver{Slot: member.Slot, Addr: member.Addr.String(), IP: member.Addr.IP.String()})
		}
		if len(view.Drivers) > 0 {
			view.First = view.Drivers[0].Addr
		}
		if room.Locked {
			snap.Races = append(snap.Races, view)
		} else {
			snap.Rooms = append(snap.Rooms, view)
		}
	}
	for ip := range r.banned {
		snap.Banned = append(snap.Banned, ip)
	}
	sort.Slice(snap.Rooms, func(i, j int) bool { return snap.Rooms[i].Code < snap.Rooms[j].Code })
	sort.Slice(snap.Races, func(i, j int) bool { return snap.Races[i].Code < snap.Races[j].Code })
	sort.Strings(snap.Banned)
	for i := len(r.events) - 1; i >= 0; i-- {
		snap.Events = append(snap.Events, r.events[i])
	}
	return snap
}

func main() {
	listen := flag.String("addr", ":8080", "UDP address to listen on")
	racing := flag.Duration("race-timeout", 5*time.Second, "drop a driver in a shared room after this long without packets")
	waiting := flag.Duration("wait-timeout", 60*time.Second, "drop someone alone in a room after this long without packets")
	rate := flag.Float64("rate", 300, "packets a second allowed from one IP, 0 for no limit")
	players := flag.Int("max-players", 2000, "players the relay takes at once")
	dashboard := flag.String("dashboard", "", "HTTP address for the dashboard (off if empty)")
	token := flag.String("dashboard-token", os.Getenv("SPPPD_DASHBOARD_TOKEN"), "password for the dashboard; without one it only answers on loopback")
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
	relay.rate = *rate
	relay.maxPlayers = *players

	if *dashboard != "" {
		go func() {
			log.Printf("Dashboard listening on %s", *dashboard)
			log.Fatalf("Dashboard stopped: %v", http.ListenAndServe(*dashboard, newDashboard(relay, *token)))
		}()
	}

	go func() {
		for range time.Tick(time.Second) {
			relay.Sweep(*racing, *waiting)
		}
	}()

	stop, _ := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	go func() {
		<-stop.Done()
		relay.Shutdown()
		log.Print("Relay server stopped")
		os.Exit(0)
	}()

	// One byte over the limit, so an oversized packet is seen rather than cut.
	buffer := make([]byte, maxPacketBytes+1)
	for {
		n, remote, err := conn.ReadFromUDP(buffer)
		if err != nil || n == 0 {
			continue
		}
		relay.Handle(buffer[:n], remote)
	}
}
