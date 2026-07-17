package relay

import (
	"context"
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
