package relay

import (
	"log/slog"
	"net"
	"net/http"
	"sync"

	"github.com/pion/ice/v4"
	"github.com/pion/webrtc/v4"
)

type Config struct {
	ControlToken string
	ListenUDP    string
	Logger       *slog.Logger
}

type Server struct {
	controlToken       string
	listenUDP          string
	logger             *slog.Logger
	rooms              map[string]*Room
	mu                 sync.Mutex
	httpServer         *http.Server
	listener           net.Listener
	udpConn            *net.UDPConn
	udpMux             ice.UDPMux
	api                *webrtc.API
	udpListenAddresses []string
}

type offerRequest struct {
	Type string `json:"type"`
	SDP  string `json:"sdp"`
}

type candidateRequest struct {
	Candidate     string  `json:"candidate"`
	SDPMid        *string `json:"sdpMid"`
	SDPMLineIndex *uint16 `json:"sdpMLineIndex"`
}

type signalResponse struct {
	Type   string `json:"type"`
	SDP    string `json:"sdp,omitempty"`
	Codec  string `json:"codec,omitempty"`
	Reason string `json:"reason,omitempty"`
}

type publisherSignalResponse struct {
	Type        string `json:"type"`
	SDP         string `json:"sdp,omitempty"`
	PublisherID string `json:"publisherID,omitempty"`
	Reason      string `json:"reason,omitempty"`
}

type readyEvent struct {
	Type     string `json:"type"`
	Loopback string `json:"loopback"`
}

type Snapshot struct {
	UDPListenAddresses []string       `json:"udpListenAddresses"`
	Rooms              []RoomSnapshot `json:"rooms"`
}

type RoomSnapshot struct {
	ID                    string         `json:"id"`
	HasPublisher          bool           `json:"hasPublisher"`
	PublisherID           string         `json:"publisherID,omitempty"`
	PublisherCodecs       []string       `json:"publisherCodecs,omitempty"`
	SubscriberCodecCounts map[string]int `json:"subscriberCodecCounts,omitempty"`
	SubscriberCount       int            `json:"subscriberCount"`
	PublisherPacketCount  uint64         `json:"publisherPacketCount"`
	ForwardedPacketCount  uint64         `json:"forwardedPacketCount"`
	WrittenPacketCount    uint64         `json:"writtenPacketCount"`
	DroppedPacketCount    uint64         `json:"droppedPacketCount"`
	SlowSubscriberCount   int            `json:"slowSubscriberCount"`
	PLIForwardCount       uint64         `json:"pliForwardCount"`
	FIRForwardCount       uint64         `json:"firForwardCount"`
	NACKForwardCount      uint64         `json:"nackForwardCount"`
}
