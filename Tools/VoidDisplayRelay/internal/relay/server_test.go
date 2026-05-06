package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

func TestRoomForwardRTPFansOutOnePublisherPacketToViewers(t *testing.T) {
	room := newRoomForTest("2", nil)
	first := &recordingSink{}
	second := &recordingSink{}
	room.subscribers["first"] = newViewerRTPWriter("2", "first", first, nil)
	room.subscribers["second"] = newViewerRTPWriter("2", "second", second, nil)
	defer room.Close()

	packet := &rtp.Packet{
		Header:  rtp.Header{Timestamp: 42, SequenceNumber: 7},
		Payload: []byte{1, 2, 3},
	}
	room.ForwardRTP(packet)

	waitFor(t, func() bool { return first.count() == 1 && second.count() == 1 })
	firstPacket := first.onlyPacket(t)
	secondPacket := second.onlyPacket(t)
	if firstPacket.Timestamp != 42 || secondPacket.Timestamp != 42 {
		t.Fatalf("timestamp fanout mismatch: first=%d second=%d", firstPacket.Timestamp, secondPacket.Timestamp)
	}
	firstPacket.Payload[0] = 99
	if secondPacket.Payload[0] == 99 {
		t.Fatal("viewer packet payloads share backing storage")
	}
	if got := room.forwardedPacketCount.Load(); got != 2 {
		t.Fatalf("forwarded packet count = %d, want 2", got)
	}
}

func TestRoomRemoveViewerStopsFutureRTPForThatViewer(t *testing.T) {
	room := newRoomForTest("2", nil)
	removed := &recordingSink{}
	active := &recordingSink{}
	room.subscribers["removed"] = newViewerRTPWriter("2", "removed", removed, nil)
	room.subscribers["active"] = newViewerRTPWriter("2", "active", active, nil)
	room.viewers["removed"] = &viewerSession{pc: &fakePeerConnection{}}
	room.pendingViewerICE["removed"] = []webrtc.ICECandidateInit{{Candidate: "candidate:removed"}}
	defer room.Close()

	room.RemoveViewer("removed")
	room.ForwardRTP(&rtp.Packet{Header: rtp.Header{Timestamp: 99}, Payload: []byte{1}})

	waitFor(t, func() bool { return active.count() == 1 })
	if got := removed.count(); got != 0 {
		t.Fatalf("removed viewer received %d packets, want 0", got)
	}
	if got := active.count(); got != 1 {
		t.Fatalf("active viewer received %d packets, want 1", got)
	}
	if _, ok := room.pendingViewerICE["removed"]; ok {
		t.Fatal("removed viewer kept pending ICE candidates")
	}
}

func TestRoomIgnoresStalePublisherCandidate(t *testing.T) {
	room := newRoomForTest("2", nil)
	pc := &fakePeerConnection{}
	room.publisher = &publisherSession{id: "current", pc: pc}

	if err := room.AddPublisherCandidate("stale", webrtc.ICECandidateInit{Candidate: "candidate:publisher"}); err != nil {
		t.Fatalf("AddPublisherCandidate returned error: %v", err)
	}

	if got := len(pc.addedCandidates()); got != 0 {
		t.Fatalf("added stale publisher ICE count = %d, want 0", got)
	}
}

func TestRoomBuffersViewerCandidateBeforeViewerExists(t *testing.T) {
	room := newRoomForTest("2", nil)

	if err := room.AddViewerCandidate("viewer-1", webrtc.ICECandidateInit{Candidate: "candidate:viewer"}); err != nil {
		t.Fatalf("AddViewerCandidate returned error: %v", err)
	}

	if got := len(room.pendingViewerICE["viewer-1"]); got != 1 {
		t.Fatalf("pending viewer ICE count = %d, want 1", got)
	}
}

func TestRoomApplyPendingICECandidates(t *testing.T) {
	room := newRoomForTest("2", nil)
	pc := &fakePeerConnection{}
	candidates := []webrtc.ICECandidateInit{
		{Candidate: "candidate:1"},
		{Candidate: "candidate:2"},
	}

	room.applyICECandidates("viewer-1", pc, candidates)

	added := pc.addedCandidates()
	if len(added) != 2 {
		t.Fatalf("added ICE candidate count = %d, want 2", len(added))
	}
	if added[0].Candidate != "candidate:1" || added[1].Candidate != "candidate:2" {
		t.Fatalf("added ICE candidates = %#v", added)
	}
}

func TestRoomForwardFeedbackRetargetsPLIAndFIRToPublisherSSRC(t *testing.T) {
	pc := &fakePeerConnection{}
	room := newRoomForTest("2", nil)
	room.publisher = &publisherSession{id: "publisher-1", pc: pc}
	room.publisherSSRC = 1234

	room.forwardFeedback([]rtcp.Packet{
		&rtcp.PictureLossIndication{SenderSSRC: 1, MediaSSRC: 55},
		&rtcp.FullIntraRequest{
			SenderSSRC: 2,
			MediaSSRC:  56,
			FIR:        []rtcp.FIREntry{{SSRC: 56, SequenceNumber: 9}},
		},
	})

	packets := pc.writtenRTCP()
	if len(packets) != 2 {
		t.Fatalf("written RTCP count = %d, want 2", len(packets))
	}
	pli, ok := packets[0].(*rtcp.PictureLossIndication)
	if !ok || pli.MediaSSRC != 1234 {
		t.Fatalf("PLI retarget mismatch: %#v", packets[0])
	}
	fir, ok := packets[1].(*rtcp.FullIntraRequest)
	if !ok || fir.MediaSSRC != 1234 || fir.FIR[0].SSRC != 1234 {
		t.Fatalf("FIR retarget mismatch: %#v", packets[1])
	}
	if got := room.pliForwardCount.Load(); got != 1 {
		t.Fatalf("PLI count = %d, want 1", got)
	}
	if got := room.firForwardCount.Load(); got != 1 {
		t.Fatalf("FIR count = %d, want 1", got)
	}
}

func TestRoomStalePublisherStopAndRTPDoNotAffectCurrentPublisher(t *testing.T) {
	room := newRoomForTest("2", nil)
	pc := &fakePeerConnection{}
	sink := &recordingSink{}
	room.publisher = &publisherSession{id: "current", pc: pc}
	room.subscribers["viewer"] = newViewerRTPWriter("2", "viewer", sink, nil)
	defer room.Close()

	room.StopPublisher("stale")
	forwarded := room.ForwardRTPFromPublisher("stale", &rtp.Packet{
		Header:  rtp.Header{Timestamp: 77},
		Payload: []byte{1},
	})

	if forwarded {
		t.Fatal("stale publisher RTP was forwarded")
	}
	if pc.isClosed() {
		t.Fatal("stale publisher stop closed current publisher")
	}
	if got := sink.count(); got != 0 {
		t.Fatalf("stale publisher packet count = %d, want 0", got)
	}
}

func TestRoomSlowViewerDropsOnlyThatViewer(t *testing.T) {
	room := newRoomForTest("2", nil)
	slow := newBlockingSink()
	active := &recordingSink{}
	room.subscribers["slow"] = newViewerRTPWriter("2", "slow", slow, nil)
	room.subscribers["active"] = newViewerRTPWriter("2", "active", active, nil)
	defer room.Close()

	for index := 0; index < subscriberRTPQueueSize+20; index++ {
		room.ForwardRTP(&rtp.Packet{
			Header:  rtp.Header{Timestamp: uint32(index)},
			Payload: []byte{1},
		})
	}

	waitFor(t, func() bool { return active.count() > 0 })
	snapshot := room.Snapshot()
	if snapshot.DroppedPacketCount == 0 {
		t.Fatal("slow viewer did not record dropped packets")
	}
	if snapshot.SlowSubscriberCount != 1 {
		t.Fatalf("slow subscriber count = %d, want 1", snapshot.SlowSubscriberCount)
	}
	if active.count() == 0 {
		t.Fatal("active viewer did not receive RTP while slow viewer queue was full")
	}
	slow.release()
}

func TestViewerWriterRejectsEnqueueAfterClose(t *testing.T) {
	sink := &recordingSink{}
	writer := newViewerRTPWriter("2", "viewer", sink, nil)
	writer.close()

	if writer.enqueue(&rtp.Packet{Header: rtp.Header{Timestamp: 10}, Payload: []byte{1}}) {
		t.Fatal("closed writer accepted RTP")
	}
	if got := sink.count(); got != 0 {
		t.Fatalf("closed writer wrote %d packets, want 0", got)
	}
}

func TestRoomConcurrentRemoveAndForwardDoesNotRace(t *testing.T) {
	room := newRoomForTest("2", nil)
	sink := &recordingSink{}
	room.subscribers["viewer"] = newViewerRTPWriter("2", "viewer", sink, nil)
	room.viewers["viewer"] = &viewerSession{pc: &fakePeerConnection{}, writer: room.subscribers["viewer"]}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for index := 0; index < 200; index++ {
			room.ForwardRTP(&rtp.Packet{Header: rtp.Header{Timestamp: uint32(index)}, Payload: []byte{1}})
		}
	}()
	go func() {
		defer wg.Done()
		room.RemoveViewer("viewer")
	}()
	wg.Wait()
	room.Close()
}

func TestRoomInvalidViewerOfferDoesNotStoreSubscriber(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)

	if _, err := room.SetViewerOffer("viewer", "invalid-sdp"); err == nil {
		t.Fatal("SetViewerOffer succeeded for invalid SDP")
	}
	snapshot := room.Snapshot()
	if snapshot.SubscriberCount != 0 {
		t.Fatalf("subscriber count = %d, want 0", snapshot.SubscriberCount)
	}
}

func TestRoomInvalidPublisherOfferPreservesCurrentPublisher(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	current := &fakePeerConnection{}
	room.publisher = &publisherSession{id: "current", pc: current}
	room.publisherSSRC = 1234

	if _, err := room.SetPublisherOffer("invalid-sdp"); err == nil {
		t.Fatal("SetPublisherOffer succeeded for invalid SDP")
	}

	if room.publisher == nil || room.publisher.id != "current" {
		t.Fatalf("current publisher was not preserved: %#v", room.publisher)
	}
	if room.publisherSSRC != 1234 {
		t.Fatalf("publisher SSRC = %d, want 1234", room.publisherSSRC)
	}
	if current.isClosed() {
		t.Fatal("current publisher was closed")
	}
}

func TestServerListenUDPBindsSocketAndEventsExposeAddress(t *testing.T) {
	loopback, stopServer := startTestServer(t)
	defer stopServer()

	request, err := http.NewRequest(http.MethodGet, loopback+"/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-Control-Token", "token")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("events status = %d, want 200", response.StatusCode)
	}
	var snapshot Snapshot
	if err := json.NewDecoder(response.Body).Decode(&snapshot); err != nil {
		t.Fatal(err)
	}
	if len(snapshot.UDPListenAddresses) == 0 {
		t.Fatal("events did not include UDP listen addresses")
	}
}

func TestPublisherOfferReturnsPublisherID(t *testing.T) {
	loopback, stopServer := startTestServer(t)
	defer stopServer()
	offerSDP := createPublisherOffer(t)
	body, err := json.Marshal(offerRequest{Type: "offer", SDP: offerSDP})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, loopback+"/room/2/publisher", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-Control-Token", "token")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("publisher offer status = %d, want 200", response.StatusCode)
	}
	var result publisherSignalResponse
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if result.Type != "answer" {
		t.Fatalf("publisher response type = %q, want answer", result.Type)
	}
	if result.SDP == "" {
		t.Fatal("publisher response SDP is empty")
	}
	if result.PublisherID == "" {
		t.Fatal("publisher response publisherID is empty")
	}
}

type recordingSink struct {
	mu      sync.Mutex
	packets []*rtp.Packet
}

func (s *recordingSink) WriteRTP(packet *rtp.Packet) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.packets = append(s.packets, packet)
	return nil
}

func (s *recordingSink) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.packets)
}

func (s *recordingSink) onlyPacket(t *testing.T) *rtp.Packet {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.packets) != 1 {
		t.Fatalf("packet count = %d, want 1", len(s.packets))
	}
	return s.packets[0]
}

type blockingSink struct {
	releaseCh chan struct{}
	once      sync.Once
}

func newBlockingSink() *blockingSink {
	return &blockingSink{releaseCh: make(chan struct{})}
}

func (s *blockingSink) WriteRTP(packet *rtp.Packet) error {
	<-s.releaseCh
	return nil
}

func (s *blockingSink) release() {
	s.once.Do(func() {
		close(s.releaseCh)
	})
}

type fakePeerConnection struct {
	mu     sync.Mutex
	rtcp   []rtcp.Packet
	closed bool
	added  []webrtc.ICECandidateInit
}

func (p *fakePeerConnection) AddICECandidate(candidate webrtc.ICECandidateInit) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.added = append(p.added, candidate)
	return nil
}

func (p *fakePeerConnection) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.closed = true
	return nil
}

func (p *fakePeerConnection) WriteRTCP(packets []rtcp.Packet) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.rtcp = append(p.rtcp, packets...)
	return nil
}

func (p *fakePeerConnection) writtenRTCP() []rtcp.Packet {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]rtcp.Packet, len(p.rtcp))
	copy(out, p.rtcp)
	return out
}

func (p *fakePeerConnection) addedCandidates() []webrtc.ICECandidateInit {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]webrtc.ICECandidateInit, len(p.added))
	copy(out, p.added)
	return out
}

func (p *fakePeerConnection) isClosed() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.closed
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	if !condition() {
		t.Fatal("condition was not met")
	}
}

func startTestServer(t *testing.T) (string, func()) {
	t.Helper()
	server := NewServer(Config{
		ControlToken: "token",
		ListenUDP:    "127.0.0.1:0",
	})
	ctx, cancel := context.WithCancel(context.Background())
	ready := make(chan string, 1)
	errCh := make(chan error, 1)
	go func() {
		errCh <- server.ListenAndServe(ctx, "127.0.0.1:0", func(loopback string) {
			ready <- loopback
		})
	}()

	var loopback string
	select {
	case loopback = <-ready:
	case err := <-errCh:
		cancel()
		t.Fatalf("server stopped before ready: %v", err)
	case <-time.After(3 * time.Second):
		cancel()
		server.Close()
		t.Fatal("server did not become ready")
	}

	stop := func() {
		cancel()
		server.Close()
		select {
		case err := <-errCh:
			if err != nil {
				t.Fatalf("server stop returned error: %v", err)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("server did not stop")
		}
	}
	return loopback, stop
}

func createPublisherOffer(t *testing.T) string {
	t.Helper()
	pc, _ := createPublisherPeer(t)
	defer pc.Close()
	return pc.LocalDescription().SDP
}

func createPublisherPeer(t *testing.T) (*webrtc.PeerConnection, *webrtc.TrackLocalStaticRTP) {
	t.Helper()
	mediaEngine := &webrtc.MediaEngine{}
	if err := mediaEngine.RegisterDefaultCodecs(); err != nil {
		t.Fatal(err)
	}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(mediaEngine))
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	track, err := webrtc.NewTrackLocalStaticRTP(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8, ClockRate: 90000},
		"screen",
		"voiddisplay",
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pc.AddTrack(track); err != nil {
		t.Fatal(err)
	}
	offer, err := pc.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gatherComplete := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	<-gatherComplete
	localDescription := pc.LocalDescription()
	if localDescription == nil {
		t.Fatal("publisher local description missing")
	}
	return pc, track
}
