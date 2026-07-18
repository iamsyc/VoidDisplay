package relay

import (
	"log/slog"
	"sync"
	"sync/atomic"

	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

type Room struct {
	id                      string
	logger                  *slog.Logger
	newPeerConnection       peerConnectionFactory
	onClosed                func(*Room)
	publisherOfferMu        sync.Mutex
	mu                      sync.Mutex
	closed                  bool
	publisherOffersInFlight int
	publisher               *publisherSession
	nextPublisherID         uint64
	viewers                 map[string]*viewerSession
	viewerAdmissions        map[string]*viewerAdmission
	subscribers             map[string]*viewerRTPWriter
	pendingViewerICE        map[string][]webrtc.ICECandidateInit
	publisherCodecs         map[videoCodec]struct{}
	publisherSSRCs          map[videoCodec]uint32
	publisherExtensions     map[videoCodec]map[string]uint8
	publisherPacketCount    atomic.Uint64
	forwardedPacketCount    atomic.Uint64
	pliForwardCount         atomic.Uint64
	firForwardCount         atomic.Uint64
	nackForwardCount        atomic.Uint64
}

type rtpSink interface {
	WriteRTP(*rtp.Packet) error
}

type peerConnectionFactory func() (*webrtc.PeerConnection, error)

type peerCloser interface {
	Close() error
}

type publisherOfferResult struct {
	SDP         string
	PublisherID string
}

type viewerOfferResult struct {
	SDP   string
	Codec videoCodec
}

type publisherSession struct {
	id string
	pc peerConnection
}

type viewerSession struct {
	pc     peerConnection
	sender *webrtc.RTPSender
	writer *viewerRTPWriter
	codec  videoCodec
}

type viewerAdmission struct {
	offerInFlight bool
}

type peerConnection interface {
	AddICECandidate(webrtc.ICECandidateInit) error
	Close() error
	WriteRTCP([]rtcp.Packet) error
}

const (
	subscriberRTPQueueSize = 512
	maxViewersPerRoom      = 32
)
