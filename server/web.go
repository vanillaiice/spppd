package main

import (
	"errors"
	"net"
	"strings"
)

// Where a game finds the relay's web side: the track list and the way in for new
// tracks, at /api/tracks under the address. The game asks over UDP, because the
// SERVER setting names only the relay, and the web side may be somewhere else:
// spppd.xyz serves it over HTTPS on port 443, behind Caddy, while a relay run at
// home serves it itself, in plain HTTP on the -status port.
//
// The ask is event|web|padding, the answer event|web|ADDRESS. An address with no
// host, like http://:8081, means the host the game reached the relay at. An empty
// one means there's no track server here. A relay from before this answers
// nothing, and the game then tries https://HOST.

const maxWebAddress = 120

// webAddress is what the relay answers: the -web flag when it's set, else plain
// HTTP on the -status port, the only thing the relay serves itself.
func webAddress(flagged, statusAddr string, tracksOn bool) (string, error) {
	address := strings.TrimRight(strings.TrimSpace(flagged), "/")
	if address != "" {
		if !strings.HasPrefix(address, "http://") && !strings.HasPrefix(address, "https://") {
			return "", errors.New("-web must start with http:// or https://")
		}
		if len(address) > maxWebAddress || strings.ContainsAny(address, "| \t\r\n") {
			return "", errors.New("-web must be one address, at most 120 characters")
		}
		return address, nil
	}
	if !tracksOn {
		return "", nil
	}
	_, port, err := net.SplitHostPort(statusAddr)
	if err != nil || port == "" {
		return "", errors.New("-status needs a port, like :8081, for games to find /api/tracks")
	}
	return "http://:" + port, nil
}

// answerWeb tells a game where the web side is. The answer is never bigger than
// the ask, so nobody can use the relay to flood someone else's address.
func (r *Relay) answerWeb(size int, addr *net.UDPAddr) {
	answer := "event|web|" + r.web
	if size < minRegisterBytes || len(answer) > size {
		return
	}
	r.send([]byte(answer), addr)
}
