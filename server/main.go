// Relay server for SPPPD online races. One player hosts a room, another joins
// with its code, and from then on every packet is forwarded to the partner.
package main

import (
	"flag"
	"log"
	"net"
	"strings"
	"sync"
	"time"
)

const (
	maxCodeLength  = 16
	maxPacketBytes = 2048
)

// Sender delivers a packet to an address. Tests replace the real socket.
type Sender func(data []byte, to *net.UDPAddr)

type Client struct {
	Addr     *net.UDPAddr
	LastSeen time.Time
	RoomCode string
	Partner  *Client
}

type Relay struct {
	mu      sync.Mutex
	clients map[string]*Client
	rooms   map[string]*Client
	send    Sender
	now     func() time.Time
}

func NewRelay(send Sender) *Relay {
	return &Relay{
		clients: make(map[string]*Client),
		rooms:   make(map[string]*Client),
		send:    send,
		now:     time.Now,
	}
}

// Handle processes one packet from addr.
func (r *Relay) Handle(data []byte, addr *net.UDPAddr) {
	r.mu.Lock()
	defer r.mu.Unlock()

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
	if code == "" || len(code) > maxCodeLength {
		r.send([]byte("event|error|Room codes are 1 to 16 characters"), addr)
		return
	}

	client := &Client{Addr: addr, LastSeen: r.now(), RoomCode: code}
	switch intent {
	case "host":
		if _, taken := r.rooms[code]; taken {
			r.send([]byte("event|error|That room code is taken"), addr)
			return
		}
		r.rooms[code] = client
		r.clients[addr.String()] = client
		r.send([]byte("event|hosting|"+code), addr)
		log.Printf("[HOST] %v created room %s", addr, code)
	case "join":
		host, found := r.rooms[code]
		if !found {
			r.send([]byte("event|error|No room with that code"), addr)
			return
		}
		client.Partner = host
		host.Partner = client
		r.clients[addr.String()] = client
		delete(r.rooms, code)
		log.Printf("[JOIN] %v joined room %s with %v", addr, code, host.Addr)
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

// Sweep drops clients that have gone quiet. Waiting hosts get longer.
func (r *Relay) Sweep(racing, waiting time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := r.now()
	for _, client := range r.clients {
		limit := waiting
		if client.Partner != nil {
			limit = racing
		}
		if now.Sub(client.LastSeen) > limit {
			log.Printf("[TIMEOUT] %v", client.Addr)
			r.drop(client)
		}
	}
}

func main() {
	listen := flag.String("addr", ":8080", "UDP address to listen on")
	racing := flag.Duration("race-timeout", 5*time.Second, "drop a racer after this long without packets")
	waiting := flag.Duration("wait-timeout", 60*time.Second, "drop a waiting host after this long without packets")
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
