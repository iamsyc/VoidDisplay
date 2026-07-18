package relay

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/interceptor"
	"github.com/pion/webrtc/v4"
)

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
	if s.controlToken == "" {
		return errors.New("control_token_required")
	}
	if address == "" {
		address = "127.0.0.1:0"
	}
	if err := validateLoopbackHTTPAddress(address); err != nil {
		return err
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
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    16 * 1024,
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

func validateLoopbackHTTPAddress(address string) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return errors.New("loopback_http_address_required")
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return errors.New("loopback_http_address_required")
	}
	return nil
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
	if !validRelayIdentifier(roomID) || (len(parts) >= 3 && !validRelayIdentifier(parts[2])) {
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: "invalid_identifier"})
		return
	}
	switch {
	case len(parts) == 2 && parts[1] == "publisher" && r.Method == http.MethodPost:
		s.handlePublisherOffer(w, r, roomID)
	case len(parts) == 3 && parts[1] == "publisher" && r.Method == http.MethodDelete:
		if room := s.existingRoom(roomID); room != nil {
			room.StopPublisher(parts[2])
		}
		w.WriteHeader(http.StatusNoContent)
	case len(parts) == 4 && parts[1] == "publisher" && parts[3] == "candidate" && r.Method == http.MethodPost:
		s.handlePublisherCandidate(w, r, roomID, parts[2])
	case len(parts) == 3 && parts[1] == "viewer" && r.Method == http.MethodPost:
		s.handleViewerOffer(w, r, roomID, parts[2])
	case len(parts) == 4 && parts[1] == "viewer" && parts[3] == "candidate" && r.Method == http.MethodPost:
		s.handleViewerCandidate(w, r, roomID, parts[2])
	case len(parts) == 3 && parts[1] == "viewer" && r.Method == http.MethodDelete:
		if room := s.existingRoom(roomID); room != nil {
			room.RemoveViewer(parts[2])
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		http.NotFound(w, r)
	}
}

func (s *Server) handlePublisherOffer(w http.ResponseWriter, r *http.Request, roomID string) {
	var request offerRequest
	if err := decodeJSON(http.MaxBytesReader(w, r.Body, maxSignalRequestBodyBytes), &request); err != nil {
		writeJSON(w, http.StatusBadRequest, publisherSignalResponse{Type: "error", Reason: "invalid_json"})
		return
	}
	room, err := s.createRoom(roomID)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, publisherSignalResponse{Type: "error", Reason: err.Error()})
		return
	}
	result, err := room.SetPublisherOffer(request.SDP)
	if err != nil {
		room.CloseIfNoPublisher()
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
	if err := decodeJSON(http.MaxBytesReader(w, r.Body, maxSignalRequestBodyBytes), &request); err != nil {
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: "invalid_json"})
		return
	}
	room := s.existingRoom(roomID)
	if room == nil {
		writeJSON(w, http.StatusNotFound, signalResponse{Type: "error", Reason: "room_not_found"})
		return
	}
	if err := room.AddPublisherCandidate(publisherID, request.toPion()); err != nil {
		s.logger.Debug("publisher candidate rejected", "room", roomID, "error", err)
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: "invalid_candidate"})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleViewerOffer(w http.ResponseWriter, r *http.Request, roomID string, clientID string) {
	var request offerRequest
	if err := decodeJSON(http.MaxBytesReader(w, r.Body, maxSignalRequestBodyBytes), &request); err != nil {
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: "invalid_json"})
		return
	}
	room := s.existingRoom(roomID)
	if room == nil {
		writeJSON(w, http.StatusNotFound, signalResponse{Type: "error", Reason: "room_not_found"})
		return
	}
	answer, err := room.SetViewerOffer(clientID, request.SDP)
	if err != nil {
		s.logger.Warn("viewer offer failed", "room", roomID, "clientID", clientID, "error", err)
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, signalResponse{Type: "answer", SDP: answer.SDP, Codec: string(answer.Codec)})
}

func (s *Server) handleViewerCandidate(w http.ResponseWriter, r *http.Request, roomID string, clientID string) {
	var request candidateRequest
	if err := decodeJSON(http.MaxBytesReader(w, r.Body, maxSignalRequestBodyBytes), &request); err != nil {
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: "invalid_json"})
		return
	}
	room := s.existingRoom(roomID)
	if room == nil {
		writeJSON(w, http.StatusNotFound, signalResponse{Type: "error", Reason: "room_not_found"})
		return
	}
	if err := room.AddViewerCandidate(clientID, request.toPion()); err != nil {
		s.logger.Debug("viewer candidate rejected", "room", roomID, "clientID", clientID, "error", err)
		writeJSON(w, http.StatusBadRequest, signalResponse{Type: "error", Reason: "invalid_candidate"})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

const maxRooms = 32

func (s *Server) createRoom(id string) (*Room, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if room := s.rooms[id]; room != nil {
		if !room.isClosed() {
			return room, nil
		}
		delete(s.rooms, id)
	}
	if len(s.rooms) >= maxRooms {
		return nil, errors.New("room_limit_reached")
	}
	room := NewRoom(id, s.logger, s.newPeerConnection)
	room.onClosed = s.removeClosedRoom
	s.rooms[id] = room
	return room, nil
}

func (s *Server) existingRoom(id string) *Room {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.rooms[id]
}

func (s *Server) removeClosedRoom(room *Room) {
	s.mu.Lock()
	if s.rooms[room.id] == room {
		delete(s.rooms, room.id)
	}
	s.mu.Unlock()
}

func (s *Server) authorized(r *http.Request) bool {
	provided := r.Header.Get("X-Control-Token")
	if s.controlToken == "" || len(provided) != len(s.controlToken) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(provided), []byte(s.controlToken)) == 1
}

func (r candidateRequest) toPion() webrtc.ICECandidateInit {
	return webrtc.ICECandidateInit{
		Candidate:     r.Candidate,
		SDPMid:        r.SDPMid,
		SDPMLineIndex: r.SDPMLineIndex,
	}
}

const maxSignalRequestBodyBytes = 160 * 1024

func decodeJSON(body io.Reader, output any) error {
	decoder := json.NewDecoder(body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(output); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple_json_values")
		}
		return err
	}
	return nil
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

func validRelayIdentifier(value string) bool {
	if len(value) == 0 || len(value) > 64 {
		return false
	}
	for _, character := range value {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			character == '-' || character == '_' {
			continue
		}
		return false
	}
	return true
}
