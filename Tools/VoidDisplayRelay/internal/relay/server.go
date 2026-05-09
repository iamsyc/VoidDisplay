package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	pionsdp "github.com/pion/sdp/v3"
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

type videoCodec string

const (
	videoCodecAV1 videoCodec = "av1"
)

var errSupportedVideoCodecMissing = errors.New("supported_video_codec_missing")
var errUnsupportedVideoCodecOffered = errors.New("unsupported_video_codec_offered")
var errPublisherCodecPending = errors.New("publisher_codec_pending")
var errPublisherCodecDuplicate = errors.New("publisher_video_codec_duplicate")

var av1RTCPFeedback = []webrtc.RTCPFeedback{
	{Type: "goog-remb"},
	{Type: "ccm", Parameter: "fir"},
	{Type: "nack"},
	{Type: "nack", Parameter: "pli"},
}

var av1CodecParameters = []webrtc.RTPCodecParameters{
	{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:     webrtc.MimeTypeAV1,
			ClockRate:    90000,
			RTCPFeedback: av1RTCPFeedback,
		},
		PayloadType: 45,
	},
	{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeRTX,
			ClockRate:   90000,
			SDPFmtpLine: "apt=45",
		},
		PayloadType: 46,
	},
}

func registerVideoCodecs(mediaEngine *webrtc.MediaEngine) error {
	for _, codec := range av1CodecParameters {
		if err := mediaEngine.RegisterCodec(codec, webrtc.RTPCodecTypeVideo); err != nil {
			return err
		}
	}
	return nil
}

func trackCapability(codec videoCodec) (webrtc.RTPCodecCapability, error) {
	if codec != videoCodecAV1 {
		return webrtc.RTPCodecCapability{}, errUnsupportedVideoCodecOffered
	}
	return webrtc.RTPCodecCapability{
		MimeType:     webrtc.MimeTypeAV1,
		ClockRate:    90000,
		RTCPFeedback: av1RTCPFeedback,
	}, nil
}

func codecParametersForVideoCodec(codec videoCodec) ([]webrtc.RTPCodecParameters, error) {
	if codec != videoCodecAV1 {
		return nil, errUnsupportedVideoCodecOffered
	}
	return append([]webrtc.RTPCodecParameters(nil), av1CodecParameters...), nil
}

func codecFromName(name string) (videoCodec, bool) {
	switch {
	case strings.EqualFold(name, "AV1"), strings.EqualFold(name, webrtc.MimeTypeAV1):
		return videoCodecAV1, true
	default:
		return "", false
	}
}

type videoMediaCodecSet struct {
	codecs                  map[videoCodec]struct{}
	unsupportedPrimaryCount int
}

func videoMediaCodecSets(sdp string) ([]videoMediaCodecSet, error) {
	var description pionsdp.SessionDescription
	if err := description.UnmarshalString(sdp); err != nil {
		return nil, err
	}
	mediaCodecSets := make([]videoMediaCodecSet, 0)
	payloadTypes := make(map[string]struct{})
	payloadNames := make(map[string]string)
	inVideo := false
	flush := func() {
		if !inVideo {
			return
		}
		codecSet := make(map[videoCodec]struct{})
		unsupportedPrimaryCount := 0
		for payloadType := range payloadTypes {
			name := payloadNames[payloadType]
			if videoCodec, ok := codecFromName(name); ok {
				codecSet[videoCodec] = struct{}{}
				continue
			}
			if !strings.EqualFold(name, "rtx") {
				unsupportedPrimaryCount++
			}
		}
		mediaCodecSets = append(mediaCodecSets, videoMediaCodecSet{
			codecs:                  codecSet,
			unsupportedPrimaryCount: unsupportedPrimaryCount,
		})
	}
	for _, line := range strings.Split(sdp, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "m=") {
			flush()
			inVideo = strings.HasPrefix(line, "m=video ")
			payloadTypes = make(map[string]struct{})
			payloadNames = make(map[string]string)
			if inVideo {
				parts := strings.Fields(line)
				for _, payloadType := range parts[3:] {
					payloadTypes[payloadType] = struct{}{}
				}
			}
			continue
		}
		if !inVideo || !strings.HasPrefix(line, "a=rtpmap:") {
			continue
		}
		parts := strings.Fields(strings.TrimPrefix(line, "a=rtpmap:"))
		if len(parts) < 2 {
			continue
		}
		payloadType := parts[0]
		payloadNames[payloadType] = strings.SplitN(parts[1], "/", 2)[0]
	}
	flush()
	return mediaCodecSets, nil
}

func publisherVideoCodecs(sdp string) ([]videoCodec, error) {
	mediaCodecSets, err := videoMediaCodecSets(sdp)
	if err != nil {
		return nil, err
	}
	codecs := make([]videoCodec, 0, len(mediaCodecSets))
	seen := make(map[videoCodec]struct{})
	for _, mediaCodecSet := range mediaCodecSets {
		if mediaCodecSet.unsupportedPrimaryCount > 0 {
			return nil, errUnsupportedVideoCodecOffered
		}
		if len(mediaCodecSet.codecs) == 0 {
			return nil, errSupportedVideoCodecMissing
		}
		if _, ok := mediaCodecSet.codecs[videoCodecAV1]; ok && len(mediaCodecSet.codecs) == 1 {
			if _, duplicate := seen[videoCodecAV1]; duplicate {
				return nil, errPublisherCodecDuplicate
			}
			seen[videoCodecAV1] = struct{}{}
			codecs = append(codecs, videoCodecAV1)
			continue
		}
		return nil, errUnsupportedVideoCodecOffered
	}
	if len(codecs) == 0 {
		return nil, errSupportedVideoCodecMissing
	}
	return codecs, nil
}

func codecSetFromList(codecs []videoCodec) map[videoCodec]struct{} {
	result := make(map[videoCodec]struct{}, len(codecs))
	for _, codec := range codecs {
		result[codec] = struct{}{}
	}
	return result
}

func codecListFromSet(codecSet map[videoCodec]struct{}) []videoCodec {
	codecs := make([]videoCodec, 0, len(codecSet))
	if _, ok := codecSet[videoCodecAV1]; ok {
		codecs = append(codecs, videoCodecAV1)
	}
	return codecs
}

func codecStrings(codecs []videoCodec) []string {
	result := make([]string, 0, len(codecs))
	for _, codec := range codecs {
		result = append(result, string(codec))
	}
	return result
}

func headerExtensionIDs(parameters []webrtc.RTPHeaderExtensionParameter) map[string]uint8 {
	result := make(map[string]uint8, len(parameters))
	for _, parameter := range parameters {
		if parameter.ID <= 0 || parameter.ID > 255 || parameter.URI == "" {
			continue
		}
		result[parameter.URI] = uint8(parameter.ID)
	}
	return result
}

func headerExtensionRewrites(
	publisherExtensions map[string]uint8,
	viewerExtensions map[string]uint8,
) map[uint8]uint8 {
	rewrites := make(map[uint8]uint8)
	for uri, publisherID := range publisherExtensions {
		viewerID, ok := viewerExtensions[uri]
		if !ok {
			rewrites[publisherID] = 0
			continue
		}
		rewrites[publisherID] = viewerID
	}
	return rewrites
}

func copyHeaderExtensionMap(input map[string]uint8) map[string]uint8 {
	output := make(map[string]uint8, len(input))
	for key, value := range input {
		output[key] = value
	}
	return output
}

func copyExtensionRewriteMap(input map[uint8]uint8) map[uint8]uint8 {
	output := make(map[uint8]uint8, len(input))
	for key, value := range input {
		output[key] = value
	}
	return output
}

func selectViewerCodec(sdp string, available map[videoCodec]struct{}) (videoCodec, error) {
	mediaCodecSets, err := videoMediaCodecSets(sdp)
	if err != nil {
		return "", err
	}
	if len(available) == 0 {
		return "", errPublisherCodecPending
	}
	offered := make(map[videoCodec]struct{})
	for _, mediaCodecSet := range mediaCodecSets {
		if mediaCodecSet.unsupportedPrimaryCount > 0 {
			return "", errUnsupportedVideoCodecOffered
		}
		if len(mediaCodecSet.codecs) == 0 {
			return "", errSupportedVideoCodecMissing
		}
		for codec := range mediaCodecSet.codecs {
			offered[codec] = struct{}{}
		}
	}
	if _, publisherHasAV1 := available[videoCodecAV1]; publisherHasAV1 {
		if _, viewerHasAV1 := offered[videoCodecAV1]; viewerHasAV1 {
			return videoCodecAV1, nil
		}
	}
	return "", errSupportedVideoCodecMissing
}

func NewServer(config Config) *Server {
	logger := config.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &Server{
		controlToken: config.ControlToken,
		listenUDP:    config.ListenUDP,
		logger:       logger,
		rooms:        make(map[string]*Room),
	}
}

func (s *Server) ListenAndServe(ctx context.Context, address string, ready func(string)) error {
	if address == "" {
		address = "127.0.0.1:0"
	}
	if err := s.startWebRTC(); err != nil {
		return err
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		s.Close()
		return err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/room/", s.handleRoom)
	mux.HandleFunc("/events", s.handleEvents)
	httpServer := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	s.mu.Lock()
	s.listener = listener
	s.httpServer = httpServer
	s.mu.Unlock()

	if ready != nil {
		ready("http://" + listener.Addr().String())
	}

	errCh := make(chan error, 1)
	go func() {
		errCh <- httpServer.Serve(listener)
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
		s.Close()
		return nil
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			s.Close()
			return nil
		}
		s.Close()
		return err
	}
}

func (s *Server) Close() {
	s.mu.Lock()
	httpServer := s.httpServer
	listener := s.listener
	udpMux := s.udpMux
	udpConn := s.udpConn
	rooms := make([]*Room, 0, len(s.rooms))
	for _, room := range s.rooms {
		rooms = append(rooms, room)
	}
	s.rooms = make(map[string]*Room)
	s.httpServer = nil
	s.listener = nil
	s.udpMux = nil
	s.udpConn = nil
	s.api = nil
	s.udpListenAddresses = nil
	s.mu.Unlock()

	if httpServer != nil {
		_ = httpServer.Close()
	}
	if listener != nil {
		_ = listener.Close()
	}
	for _, room := range rooms {
		room.Close()
	}
	if udpMux != nil {
		_ = udpMux.Close()
	}
	if udpConn != nil {
		_ = udpConn.Close()
	}
}

func (s *Server) Snapshot() Snapshot {
	s.mu.Lock()
	rooms := make([]*Room, 0, len(s.rooms))
	for _, room := range s.rooms {
		rooms = append(rooms, room)
	}
	udpListenAddresses := append([]string(nil), s.udpListenAddresses...)
	s.mu.Unlock()

	snapshot := Snapshot{
		UDPListenAddresses: udpListenAddresses,
		Rooms:              make([]RoomSnapshot, 0, len(rooms)),
	}
	for _, room := range rooms {
		snapshot.Rooms = append(snapshot.Rooms, room.Snapshot())
	}
	return snapshot
}

func (s *Server) startWebRTC() error {
	s.mu.Lock()
	if s.api != nil {
		s.mu.Unlock()
		return nil
	}
	listenUDP := s.listenUDP
	s.mu.Unlock()
	if listenUDP == "" {
		listenUDP = ":0"
	}

	udpAddress, err := net.ResolveUDPAddr("udp4", listenUDP)
	if err != nil {
		return err
	}
	udpConn, err := net.ListenUDP("udp4", udpAddress)
	if err != nil {
		return err
	}
	udpMux := ice.NewUDPMuxDefault(ice.UDPMuxParams{UDPConn: udpConn})
	mediaEngine := &webrtc.MediaEngine{}
	if err := registerVideoCodecs(mediaEngine); err != nil {
		_ = udpMux.Close()
		_ = udpConn.Close()
		return err
	}
	interceptorRegistry := &interceptor.Registry{}
	if err := webrtc.ConfigureNack(mediaEngine, interceptorRegistry); err != nil {
		_ = udpMux.Close()
		_ = udpConn.Close()
		return err
	}
	if err := webrtc.ConfigureRTCPReports(interceptorRegistry); err != nil {
		_ = udpMux.Close()
		_ = udpConn.Close()
		return err
	}
	if err := webrtc.ConfigureStatsInterceptor(interceptorRegistry); err != nil {
		_ = udpMux.Close()
		_ = udpConn.Close()
		return err
	}
	settingEngine := webrtc.SettingEngine{}
	settingEngine.SetICEUDPMux(udpMux)
	settingEngine.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	api := webrtc.NewAPI(
		webrtc.WithMediaEngine(mediaEngine),
		webrtc.WithSettingEngine(settingEngine),
		webrtc.WithInterceptorRegistry(interceptorRegistry),
	)

	listenAddresses := make([]string, 0)
	for _, address := range udpMux.GetListenAddresses() {
		listenAddresses = append(listenAddresses, address.String())
	}
	if len(listenAddresses) == 0 {
		listenAddresses = []string{udpConn.LocalAddr().String()}
	}

	s.mu.Lock()
	if s.api != nil {
		s.mu.Unlock()
		_ = udpMux.Close()
		_ = udpConn.Close()
		return nil
	}
	s.udpConn = udpConn
	s.udpMux = udpMux
	s.api = api
	s.udpListenAddresses = append([]string(nil), listenAddresses...)
	s.mu.Unlock()
	return nil
}

func (s *Server) newPeerConnection() (*webrtc.PeerConnection, error) {
	s.mu.Lock()
	api := s.api
	s.mu.Unlock()
	if api == nil {
		return nil, errors.New("webrtc_api_not_started")
	}
	return api.NewPeerConnection(webrtc.Configuration{})
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	writeJSON(w, http.StatusOK, s.Snapshot())
}

func (s *Server) handleRoom(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	parts := splitPath(strings.TrimPrefix(r.URL.Path, "/room/"))
	if len(parts) < 2 {
		http.NotFound(w, r)
		return
	}
	roomID := parts[0]
	switch {
	case len(parts) == 2 && parts[1] == "publisher" && r.Method == http.MethodPost:
		s.handlePublisherOffer(w, r, roomID)
	case len(parts) == 3 && parts[1] == "publisher" && r.Method == http.MethodDelete:
		s.room(roomID).StopPublisher(parts[2])
		w.WriteHeader(http.StatusNoContent)
	case len(parts) == 4 && parts[1] == "publisher" && parts[3] == "candidate" && r.Method == http.MethodPost:
		s.handlePublisherCandidate(w, r, roomID, parts[2])
	case len(parts) == 3 && parts[1] == "viewer" && r.Method == http.MethodPost:
		s.handleViewerOffer(w, r, roomID, parts[2])
	case len(parts) == 4 && parts[1] == "viewer" && parts[3] == "candidate" && r.Method == http.MethodPost:
		s.handleViewerCandidate(w, r, roomID, parts[2])
	case len(parts) == 3 && parts[1] == "viewer" && r.Method == http.MethodDelete:
		s.room(roomID).RemoveViewer(parts[2])
		w.WriteHeader(http.StatusNoContent)
	default:
		http.NotFound(w, r)
	}
}

func (s *Server) handlePublisherOffer(w http.ResponseWriter, r *http.Request, roomID string) {
	var request offerRequest
	if err := decodeJSON(r.Body, &request); err != nil {
		writeJSON(w, http.StatusBadRequest, publisherSignalResponse{Type: "error", Reason: "invalid_json"})
		return
	}
	result, err := s.room(roomID).SetPublisherOffer(request.SDP)
	if err != nil {
		s.logger.Warn("publisher offer failed", "room", roomID, "error", err)
		writeJSON(w, http.StatusBadRequest, publisherSignalResponse{Type: "error", Reason: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, publisherSignalResponse{
		Type:        "answer",
		SDP:         result.SDP,
		PublisherID: result.PublisherID,
	})
}

func (s *Server) handlePublisherCandidate(w http.ResponseWriter, r *http.Request, roomID string, publisherID string) {
	var request candidateRequest
	if err := decodeJSON(r.Body, &request); err != nil {
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: "invalid_json"})
		return
	}
	if err := s.room(roomID).AddPublisherCandidate(publisherID, request.toPion()); err != nil {
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: err.Error()})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleViewerOffer(w http.ResponseWriter, r *http.Request, roomID string, clientID string) {
	var request offerRequest
	if err := decodeJSON(r.Body, &request); err != nil {
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: "invalid_json"})
		return
	}
	answer, err := s.room(roomID).SetViewerOffer(clientID, request.SDP)
	if err != nil {
		s.logger.Warn("viewer offer failed", "room", roomID, "clientID", clientID, "error", err)
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, signalResponse{Type: "answer", SDP: answer.SDP, Codec: string(answer.Codec)})
}

func (s *Server) handleViewerCandidate(w http.ResponseWriter, r *http.Request, roomID string, clientID string) {
	var request candidateRequest
	if err := decodeJSON(r.Body, &request); err != nil {
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: "invalid_json"})
		return
	}
	if err := s.room(roomID).AddViewerCandidate(clientID, request.toPion()); err != nil {
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: err.Error()})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) room(id string) *Room {
	s.mu.Lock()
	defer s.mu.Unlock()
	if room := s.rooms[id]; room != nil {
		return room
	}
	room := NewRoom(id, s.logger, s.newPeerConnection)
	s.rooms[id] = room
	return room
}

func (s *Server) closeRoom(id string) {
	s.mu.Lock()
	room := s.rooms[id]
	delete(s.rooms, id)
	s.mu.Unlock()
	if room != nil {
		room.Close()
	}
}

func (s *Server) authorized(r *http.Request) bool {
	if s.controlToken == "" {
		return true
	}
	if r.Header.Get("X-Control-Token") == s.controlToken {
		return true
	}
	const bearer = "Bearer "
	if auth := r.Header.Get("Authorization"); strings.HasPrefix(auth, bearer) {
		return strings.TrimPrefix(auth, bearer) == s.controlToken
	}
	return r.URL.Query().Get("token") == s.controlToken
}

func (r candidateRequest) toPion() webrtc.ICECandidateInit {
	return webrtc.ICECandidateInit{
		Candidate:     r.Candidate,
		SDPMid:        r.SDPMid,
		SDPMLineIndex: r.SDPMLineIndex,
	}
}

func decodeJSON(body io.Reader, output any) error {
	decoder := json.NewDecoder(io.LimitReader(body, 2<<20))
	decoder.DisallowUnknownFields()
	return decoder.Decode(output)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if status == http.StatusNoContent {
		return
	}
	_ = json.NewEncoder(w).Encode(value)
}

func splitPath(path string) []string {
	rawParts := strings.Split(path, "/")
	parts := make([]string, 0, len(rawParts))
	for _, part := range rawParts {
		if part != "" {
			parts = append(parts, part)
		}
	}
	return parts
}

type Room struct {
	id                   string
	logger               *slog.Logger
	newPeerConnection    peerConnectionFactory
	mu                   sync.Mutex
	publisher            *publisherSession
	nextPublisherID      uint64
	viewers              map[string]*viewerSession
	subscribers          map[string]*viewerRTPWriter
	pendingViewerICE     map[string][]webrtc.ICECandidateInit
	publisherCodecs      map[videoCodec]struct{}
	publisherSSRCs       map[videoCodec]uint32
	publisherExtensions  map[videoCodec]map[string]uint8
	publisherPacketCount atomic.Uint64
	forwardedPacketCount atomic.Uint64
	pliForwardCount      atomic.Uint64
	firForwardCount      atomic.Uint64
	nackForwardCount     atomic.Uint64
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

type peerConnection interface {
	AddICECandidate(webrtc.ICECandidateInit) error
	Close() error
	WriteRTCP([]rtcp.Packet) error
}

const subscriberRTPQueueSize = 512

type viewerRTPWriter struct {
	roomID            string
	clientID          string
	codec             videoCodec
	logger            *slog.Logger
	sink              rtpSink
	queue             chan *rtp.Packet
	done              chan struct{}
	mu                sync.Mutex
	closed            bool
	viewerExtensions  map[string]uint8
	extensionRewrites map[uint8]uint8
	written           atomic.Uint64
	dropped           atomic.Uint64
}

func newViewerRTPWriter(roomID string, clientID string, codec videoCodec, sink rtpSink, logger *slog.Logger) *viewerRTPWriter {
	if logger == nil {
		logger = slog.Default()
	}
	writer := &viewerRTPWriter{
		roomID:            roomID,
		clientID:          clientID,
		codec:             codec,
		logger:            logger,
		sink:              sink,
		queue:             make(chan *rtp.Packet, subscriberRTPQueueSize),
		done:              make(chan struct{}),
		viewerExtensions:  make(map[string]uint8),
		extensionRewrites: make(map[uint8]uint8),
	}
	go writer.run()
	return writer
}

func (w *viewerRTPWriter) enqueue(packet *rtp.Packet) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return false
	}
	packetCopy := packet.Clone()
	w.rewriteHeaderExtensions(packetCopy)
	select {
	case w.queue <- packetCopy:
		return true
	default:
		w.dropped.Add(1)
		w.logger.Debug("viewer RTP queue full", "room", w.roomID, "clientID", w.clientID)
		return false
	}
}

func (w *viewerRTPWriter) setViewerExtensions(extensions map[string]uint8) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.viewerExtensions = copyHeaderExtensionMap(extensions)
}

func (w *viewerRTPWriter) setExtensionRewrites(rewrites map[uint8]uint8) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.extensionRewrites = copyExtensionRewriteMap(rewrites)
}

func (w *viewerRTPWriter) setPublisherExtensions(extensions map[string]uint8) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.extensionRewrites = headerExtensionRewrites(extensions, w.viewerExtensions)
}

func (w *viewerRTPWriter) rewriteHeaderExtensions(packet *rtp.Packet) {
	type pendingRewrite struct {
		viewerID uint8
		payload  []byte
	}
	pendingRewrites := make([]pendingRewrite, 0, len(w.extensionRewrites))
	for publisherID, viewerID := range w.extensionRewrites {
		payload := packet.GetExtension(publisherID)
		if payload == nil {
			continue
		}
		payloadCopy := append([]byte(nil), payload...)
		_ = packet.DelExtension(publisherID)
		if viewerID != 0 {
			pendingRewrites = append(pendingRewrites, pendingRewrite{
				viewerID: viewerID,
				payload:  payloadCopy,
			})
		}
	}
	for _, rewrite := range pendingRewrites {
		_ = packet.SetExtension(rewrite.viewerID, rewrite.payload)
	}
}

func (w *viewerRTPWriter) run() {
	for {
		select {
		case <-w.done:
			return
		case packet := <-w.queue:
			if err := w.sink.WriteRTP(packet); err != nil && !errors.Is(err, io.ErrClosedPipe) {
				w.logger.Debug("viewer RTP write failed", "room", w.roomID, "clientID", w.clientID, "error", err)
			} else {
				w.written.Add(1)
			}
		}
	}
}

func (w *viewerRTPWriter) close() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return
	}
	w.closed = true
	close(w.done)
}

func (w *viewerRTPWriter) stats() (written uint64, dropped uint64) {
	return w.written.Load(), w.dropped.Load()
}

func NewRoom(id string, logger *slog.Logger, newPeerConnection peerConnectionFactory) *Room {
	if logger == nil {
		logger = slog.Default()
	}
	return &Room{
		id:                  id,
		logger:              logger,
		newPeerConnection:   newPeerConnection,
		viewers:             make(map[string]*viewerSession),
		subscribers:         make(map[string]*viewerRTPWriter),
		pendingViewerICE:    make(map[string][]webrtc.ICECandidateInit),
		publisherCodecs:     make(map[videoCodec]struct{}),
		publisherSSRCs:      make(map[videoCodec]uint32),
		publisherExtensions: make(map[videoCodec]map[string]uint8),
	}
}

func newRoomForTest(id string, logger *slog.Logger) *Room {
	if logger == nil {
		logger = slog.Default()
	}
	return &Room{
		id:                  id,
		logger:              logger,
		viewers:             make(map[string]*viewerSession),
		subscribers:         make(map[string]*viewerRTPWriter),
		pendingViewerICE:    make(map[string][]webrtc.ICECandidateInit),
		publisherCodecs:     make(map[videoCodec]struct{}),
		publisherSSRCs:      make(map[videoCodec]uint32),
		publisherExtensions: make(map[videoCodec]map[string]uint8),
	}
}

func (r *Room) Snapshot() RoomSnapshot {
	r.mu.Lock()
	publisherID := ""
	if r.publisher != nil {
		publisherID = r.publisher.id
	}
	publisherCodecs := codecStrings(codecListFromSet(r.publisherCodecs))
	writers := make([]*viewerRTPWriter, 0, len(r.subscribers))
	subscriberCodecCounts := make(map[string]int)
	for _, writer := range r.subscribers {
		writers = append(writers, writer)
		subscriberCodecCounts[string(writer.codec)]++
	}
	r.mu.Unlock()
	var writtenPacketCount uint64
	var droppedPacketCount uint64
	var slowSubscriberCount int
	for _, writer := range writers {
		written, dropped := writer.stats()
		writtenPacketCount += written
		droppedPacketCount += dropped
		if dropped > 0 {
			slowSubscriberCount++
		}
	}
	return RoomSnapshot{
		ID:                    r.id,
		HasPublisher:          publisherID != "",
		PublisherID:           publisherID,
		PublisherCodecs:       publisherCodecs,
		SubscriberCodecCounts: subscriberCodecCounts,
		SubscriberCount:       len(writers),
		PublisherPacketCount:  r.publisherPacketCount.Load(),
		ForwardedPacketCount:  r.forwardedPacketCount.Load(),
		WrittenPacketCount:    writtenPacketCount,
		DroppedPacketCount:    droppedPacketCount,
		SlowSubscriberCount:   slowSubscriberCount,
		PLIForwardCount:       r.pliForwardCount.Load(),
		FIRForwardCount:       r.firForwardCount.Load(),
		NACKForwardCount:      r.nackForwardCount.Load(),
	}
}

func (r *Room) SetPublisherOffer(sdp string) (publisherOfferResult, error) {
	if r.newPeerConnection == nil {
		return publisherOfferResult{}, errors.New("room_peer_connection_factory_missing")
	}
	if _, err := publisherVideoCodecs(sdp); err != nil {
		return publisherOfferResult{}, err
	}
	pc, err := r.newPeerConnection()
	if err != nil {
		return publisherOfferResult{}, err
	}
	publisherID := r.nextPublisherIdentifier()
	r.mu.Lock()
	previous := r.publisher
	previousCodecs := r.publisherCodecs
	previousSSRCs := r.publisherSSRCs
	previousExtensions := r.publisherExtensions
	r.publisher = &publisherSession{id: publisherID, pc: pc}
	r.publisherCodecs = make(map[videoCodec]struct{})
	r.publisherSSRCs = make(map[videoCodec]uint32)
	r.publisherExtensions = make(map[videoCodec]map[string]uint8)
	r.mu.Unlock()
	rollbackPublisher := func() {
		r.mu.Lock()
		if r.publisher != nil && r.publisher.id == publisherID {
			r.publisher = previous
			r.publisherCodecs = previousCodecs
			r.publisherSSRCs = previousSSRCs
			r.publisherExtensions = previousExtensions
		}
		r.mu.Unlock()
		_ = pc.Close()
	}
	pc.OnTrack(func(remote *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		r.publisherTrackStarted(publisherID, remote, receiver)
	})
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		if state == webrtc.PeerConnectionStateFailed ||
			state == webrtc.PeerConnectionStateClosed ||
			state == webrtc.PeerConnectionStateDisconnected {
			r.handlePublisherDisconnected(publisherID, state)
		}
	})
	offer := webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: sdp}
	if err := pc.SetRemoteDescription(offer); err != nil {
		rollbackPublisher()
		return publisherOfferResult{}, err
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		rollbackPublisher()
		return publisherOfferResult{}, err
	}
	gatherComplete := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(answer); err != nil {
		rollbackPublisher()
		return publisherOfferResult{}, err
	}
	<-gatherComplete
	localDescription := pc.LocalDescription()
	if localDescription == nil {
		rollbackPublisher()
		return publisherOfferResult{}, errors.New("publisher_local_description_missing")
	}
	negotiatedCodecs, err := publisherVideoCodecs(localDescription.SDP)
	if err != nil {
		rollbackPublisher()
		return publisherOfferResult{}, err
	}
	negotiatedCodecSet := codecSetFromList(negotiatedCodecs)
	r.mu.Lock()
	if r.publisher != nil && r.publisher.id == publisherID {
		r.publisherCodecs = negotiatedCodecSet
	}
	r.mu.Unlock()

	if previous != nil {
		_ = previous.pc.Close()
	}
	r.logger.Info("publisher ready", "room", r.id, "publisherID", publisherID, "codecs", codecStrings(negotiatedCodecs))
	return publisherOfferResult{SDP: localDescription.SDP, PublisherID: publisherID}, nil
}

func (r *Room) nextPublisherIdentifier() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.nextPublisherID++
	return fmt.Sprintf("%d", r.nextPublisherID)
}

func (r *Room) AddPublisherCandidate(publisherID string, candidate webrtc.ICECandidateInit) error {
	r.mu.Lock()
	publisher := r.publisher
	if publisher == nil || publisher.id != publisherID {
		r.mu.Unlock()
		r.logger.Debug("ignored stale publisher ICE candidate", "room", r.id, "publisherID", publisherID)
		return nil
	}
	r.mu.Unlock()
	return publisher.pc.AddICECandidate(candidate)
}

func (r *Room) SetViewerOffer(clientID string, sdp string) (viewerOfferResult, error) {
	if r.newPeerConnection == nil {
		return viewerOfferResult{}, errors.New("room_peer_connection_factory_missing")
	}
	r.mu.Lock()
	publisherCodecs := make(map[videoCodec]struct{}, len(r.publisherCodecs))
	for codec := range r.publisherCodecs {
		publisherCodecs[codec] = struct{}{}
	}
	r.mu.Unlock()
	selectedCodec, err := selectViewerCodec(sdp, publisherCodecs)
	if err != nil {
		return viewerOfferResult{}, err
	}
	pc, err := r.newPeerConnection()
	if err != nil {
		return viewerOfferResult{}, err
	}
	capability, err := trackCapability(selectedCodec)
	if err != nil {
		_ = pc.Close()
		return viewerOfferResult{}, err
	}
	track, err := webrtc.NewTrackLocalStaticRTP(
		capability,
		"screen-"+string(selectedCodec),
		"voiddisplay",
	)
	if err != nil {
		_ = pc.Close()
		return viewerOfferResult{}, err
	}
	transceiver, err := pc.AddTransceiverFromTrack(track, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionSendonly,
	})
	if err != nil {
		_ = pc.Close()
		return viewerOfferResult{}, err
	}
	codecParameters, err := codecParametersForVideoCodec(selectedCodec)
	if err != nil {
		_ = pc.Close()
		return viewerOfferResult{}, err
	}
	if err := transceiver.SetCodecPreferences(codecParameters); err != nil {
		_ = pc.Close()
		return viewerOfferResult{}, err
	}
	sender := transceiver.Sender()
	if sender == nil {
		_ = pc.Close()
		return viewerOfferResult{}, errors.New("viewer_sender_missing")
	}
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		if state == webrtc.PeerConnectionStateFailed ||
			state == webrtc.PeerConnectionStateClosed ||
			state == webrtc.PeerConnectionStateDisconnected {
			r.RemoveViewer(clientID)
		}
	})
	offer := webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: sdp}
	if err := pc.SetRemoteDescription(offer); err != nil {
		_ = pc.Close()
		return viewerOfferResult{}, err
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		_ = pc.Close()
		return viewerOfferResult{}, err
	}
	gatherComplete := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(answer); err != nil {
		_ = pc.Close()
		return viewerOfferResult{}, err
	}
	<-gatherComplete
	localDescription := pc.LocalDescription()
	if localDescription == nil {
		_ = pc.Close()
		return viewerOfferResult{}, errors.New("viewer_local_description_missing")
	}

	writer := newViewerRTPWriter(r.id, clientID, selectedCodec, track, r.logger)
	viewerExtensions := headerExtensionIDs(sender.GetParameters().HeaderExtensions)
	writer.setViewerExtensions(viewerExtensions)
	r.mu.Lock()
	previous := r.viewers[clientID]
	if publisherExtensions := r.publisherExtensions[selectedCodec]; len(publisherExtensions) > 0 {
		writer.setExtensionRewrites(headerExtensionRewrites(publisherExtensions, viewerExtensions))
	}
	r.viewers[clientID] = &viewerSession{pc: pc, sender: sender, writer: writer, codec: selectedCodec}
	r.subscribers[clientID] = writer
	pending := append([]webrtc.ICECandidateInit(nil), r.pendingViewerICE[clientID]...)
	delete(r.pendingViewerICE, clientID)
	subscriberCount := len(r.subscribers)
	r.mu.Unlock()
	if previous != nil {
		previous.close()
	}
	r.applyICECandidates(clientID, pc, pending)

	r.logger.Info("viewer ready", "room", r.id, "clientID", clientID, "codec", selectedCodec, "subscribers", subscriberCount)
	go r.readViewerRTCP(clientID, selectedCodec, sender)
	return viewerOfferResult{SDP: localDescription.SDP, Codec: selectedCodec}, nil
}

func (r *Room) AddViewerCandidate(clientID string, candidate webrtc.ICECandidateInit) error {
	r.mu.Lock()
	viewer := r.viewers[clientID]
	if viewer == nil {
		r.pendingViewerICE[clientID] = append(r.pendingViewerICE[clientID], candidate)
	}
	r.mu.Unlock()
	if viewer == nil {
		return nil
	}
	return viewer.pc.AddICECandidate(candidate)
}

func (r *Room) RemoveViewer(clientID string) {
	r.mu.Lock()
	viewer := r.viewers[clientID]
	delete(r.viewers, clientID)
	delete(r.subscribers, clientID)
	delete(r.pendingViewerICE, clientID)
	subscriberCount := len(r.subscribers)
	r.mu.Unlock()
	if viewer != nil {
		viewer.close()
		r.logger.Info("viewer removed", "room", r.id, "clientID", clientID, "subscribers", subscriberCount)
	}
}

func (r *Room) Close() {
	r.mu.Lock()
	publisher := r.publisher
	viewers := make([]*viewerSession, 0, len(r.viewers))
	for _, viewer := range r.viewers {
		viewers = append(viewers, viewer)
	}
	r.publisher = nil
	r.viewers = make(map[string]*viewerSession)
	r.subscribers = make(map[string]*viewerRTPWriter)
	r.pendingViewerICE = make(map[string][]webrtc.ICECandidateInit)
	r.publisherCodecs = make(map[videoCodec]struct{})
	r.publisherSSRCs = make(map[videoCodec]uint32)
	r.publisherExtensions = make(map[videoCodec]map[string]uint8)
	r.mu.Unlock()
	if publisher != nil {
		_ = publisher.pc.Close()
	}
	for _, viewer := range viewers {
		viewer.close()
	}
}

func (r *Room) StopPublisher(publisherID string) {
	var publisher *publisherSession
	r.mu.Lock()
	if r.publisher != nil && r.publisher.id == publisherID {
		publisher = r.publisher
		r.publisher = nil
		r.publisherCodecs = make(map[videoCodec]struct{})
		r.publisherSSRCs = make(map[videoCodec]uint32)
		r.publisherExtensions = make(map[videoCodec]map[string]uint8)
	}
	r.mu.Unlock()
	if publisher == nil {
		r.logger.Debug("ignored stale publisher stop", "room", r.id, "publisherID", publisherID)
		return
	}
	_ = publisher.pc.Close()
	r.logger.Info("publisher stopped", "room", r.id, "publisherID", publisherID)
}

func (v *viewerSession) close() {
	if v.writer != nil {
		v.writer.close()
	}
	if v.pc != nil {
		_ = v.pc.Close()
	}
}

func (r *Room) applyICECandidates(clientID string, pc peerConnection, candidates []webrtc.ICECandidateInit) {
	for _, candidate := range candidates {
		if err := pc.AddICECandidate(candidate); err != nil {
			r.logger.Debug("pending ICE candidate failed", "room", r.id, "clientID", clientID, "error", err)
		}
	}
}

func (r *Room) handlePublisherDisconnected(publisherID string, state webrtc.PeerConnectionState) {
	r.mu.Lock()
	isCurrent := r.publisher != nil && r.publisher.id == publisherID
	r.mu.Unlock()
	if !isCurrent {
		r.logger.Debug(
			"ignored stale publisher disconnect",
			"room",
			r.id,
			"publisherID",
			publisherID,
			"state",
			state.String(),
		)
		return
	}
	r.logger.Info("publisher disconnected", "room", r.id, "publisherID", publisherID, "state", state.String())
	r.Close()
}

func (r *Room) publisherTrackStarted(publisherID string, remote *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
	codec, ok := codecFromName(remote.Codec().MimeType)
	if !ok {
		r.logger.Warn("publisher track ignored unsupported codec", "room", r.id, "publisherID", publisherID, "codec", remote.Codec().MimeType)
		return
	}
	r.mu.Lock()
	if r.publisher == nil || r.publisher.id != publisherID {
		r.mu.Unlock()
		r.logger.Debug("ignored stale publisher track", "room", r.id, "publisherID", publisherID)
		return
	}
	ssrc := uint32(remote.SSRC())
	r.publisherSSRCs[codec] = ssrc
	publisherExtensions := headerExtensionIDs(receiver.GetParameters().HeaderExtensions)
	r.publisherExtensions[codec] = publisherExtensions
	writers := make([]*viewerRTPWriter, 0, len(r.subscribers))
	for _, writer := range r.subscribers {
		if writer.codec == codec {
			writers = append(writers, writer)
		}
	}
	r.mu.Unlock()
	for _, writer := range writers {
		writer.setPublisherExtensions(publisherExtensions)
	}
	r.logger.Info(
		"publisher track started",
		"room",
		r.id,
		"publisherID",
		publisherID,
		"codec",
		remote.Codec().MimeType,
		"ssrc",
		ssrc,
	)
	defer r.publisherTrackStopped(publisherID, codec, ssrc)
	for {
		packet, _, err := remote.ReadRTP()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				r.logger.Warn("publisher RTP read failed", "room", r.id, "error", err)
			}
			return
		}
		if !r.ForwardRTPFromPublisher(publisherID, codec, packet) {
			return
		}
		r.publisherPacketCount.Add(1)
	}
}

func (r *Room) publisherTrackStopped(publisherID string, codec videoCodec, ssrc uint32) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.publisher == nil || r.publisher.id != publisherID {
		return
	}
	if r.publisherSSRCs[codec] != ssrc {
		return
	}
	delete(r.publisherSSRCs, codec)
	delete(r.publisherExtensions, codec)
}

func (r *Room) ForwardRTP(packet *rtp.Packet) {
	r.forwardRTPToSubscribers("", packet)
}

func (r *Room) ForwardRTPForCodec(codec videoCodec, packet *rtp.Packet) {
	r.forwardRTPToSubscribers(codec, packet)
}

func (r *Room) ForwardRTPFromPublisher(publisherID string, codec videoCodec, packet *rtp.Packet) bool {
	r.mu.Lock()
	isCurrent := r.publisher != nil && r.publisher.id == publisherID
	r.mu.Unlock()
	if !isCurrent {
		r.logger.Debug("ignored stale publisher RTP", "room", r.id, "publisherID", publisherID)
		return false
	}
	r.forwardRTPToSubscribers(codec, packet)
	return true
}

func (r *Room) forwardRTPToSubscribers(codec videoCodec, packet *rtp.Packet) {
	r.mu.Lock()
	subscribers := make([]*viewerRTPWriter, 0, len(r.subscribers))
	for _, subscriber := range r.subscribers {
		if codec != "" && subscriber.codec != codec {
			continue
		}
		subscribers = append(subscribers, subscriber)
	}
	r.mu.Unlock()
	for _, subscriber := range subscribers {
		if subscriber.enqueue(packet) {
			r.forwardedPacketCount.Add(1)
		}
	}
}

func (r *Room) readViewerRTCP(clientID string, codec videoCodec, sender *webrtc.RTPSender) {
	for {
		packets, _, err := sender.ReadRTCP()
		if err != nil {
			if !errors.Is(err, io.ErrClosedPipe) {
				r.logger.Debug("viewer RTCP read stopped", "room", r.id, "clientID", clientID, "error", err)
			}
			return
		}
		r.forwardFeedback(codec, packets)
	}
}

func (r *Room) forwardFeedback(codec videoCodec, packets []rtcp.Packet) {
	r.mu.Lock()
	publisher := r.publisher
	publisherSSRC := r.publisherSSRCs[codec]
	r.mu.Unlock()
	if publisher == nil || publisherSSRC == 0 {
		return
	}

	forwarded := make([]rtcp.Packet, 0, len(packets))
	for _, packet := range packets {
		switch value := packet.(type) {
		case *rtcp.PictureLossIndication:
			r.pliForwardCount.Add(1)
			forwarded = append(forwarded, &rtcp.PictureLossIndication{
				SenderSSRC: value.SenderSSRC,
				MediaSSRC:  publisherSSRC,
			})
		case *rtcp.FullIntraRequest:
			r.firForwardCount.Add(1)
			entries := make([]rtcp.FIREntry, len(value.FIR))
			copy(entries, value.FIR)
			for index := range entries {
				entries[index].SSRC = publisherSSRC
			}
			forwarded = append(forwarded, &rtcp.FullIntraRequest{
				SenderSSRC: value.SenderSSRC,
				MediaSSRC:  publisherSSRC,
				FIR:        entries,
			})
		case *rtcp.TransportLayerNack:
			r.nackForwardCount.Add(1)
			nacks := make([]rtcp.NackPair, len(value.Nacks))
			copy(nacks, value.Nacks)
			forwarded = append(forwarded, &rtcp.TransportLayerNack{
				SenderSSRC: value.SenderSSRC,
				MediaSSRC:  publisherSSRC,
				Nacks:      nacks,
			})
		}
	}
	if len(forwarded) == 0 {
		return
	}
	if err := publisher.pc.WriteRTCP(forwarded); err != nil {
		r.logger.Debug("publisher RTCP write failed", "room", r.id, "error", err)
	}
}

func ReadyJSON(loopback string) string {
	data, err := json.Marshal(readyEvent{Type: "ready", Loopback: loopback})
	if err != nil {
		return fmt.Sprintf(`{"type":"ready","loopback":%q}`, loopback)
	}
	return string(data)
}
