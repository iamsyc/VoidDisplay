package relay

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

func TestRecreatedRoomIgnoresPreviousPublisherDelete(t *testing.T) {
	server := NewServer(Config{ControlToken: "token", ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	createPublisher := func() (*Room, string) {
		t.Helper()
		room, err := server.createRoom("2")
		if err != nil {
			t.Fatal(err)
		}
		result, err := room.SetPublisherOffer(createPublisherOffer(t))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := strconv.ParseUint(result.PublisherID, 10, 64); err != nil {
			t.Fatalf("publisher ID must remain a decimal uint64: %q", result.PublisherID)
		}
		return room, result.PublisherID
	}
	previous, previousID := createPublisher()
	previous.StopPublisher(previousID)
	current, currentID := createPublisher()
	if previousID == currentID {
		t.Errorf("recreated room reused publisher ID %s", currentID)
	}
	request := httptest.NewRequest(http.MethodDelete, "/room/2/publisher/"+previousID, nil)
	request.Header.Set("X-Control-Token", "token")
	response := httptest.NewRecorder()
	server.handleRoom(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("DELETE status = %d, want 204", response.Code)
	}
	if current.isClosed() || current.Snapshot().PublisherID != currentID || server.existingRoom("2") != current {
		t.Fatal("old DELETE removed the new publisher or room")
	}
}

func TestPublisherDisconnectInterleavedWithReplacementPreservesNewSession(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	barrier := &disconnectLogBarrier{entered: make(chan struct{}), release: make(chan struct{})}
	defer barrier.unblock()
	room := NewRoom("2", slog.New(barrier), server.newPeerConnection)
	defer room.Close()
	room.publisher = &publisherSession{id: "previous", pc: &fakePeerConnection{}}
	viewer := &fakePeerConnection{}
	room.viewers["viewer"] = &viewerSession{pc: viewer}
	done := make(chan struct{})
	go func() {
		defer close(done)
		room.handlePublisherDisconnected("previous", webrtc.PeerConnectionStateDisconnected)
	}()
	select {
	case <-barrier.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("disconnect did not reach the synchronization barrier")
	}
	replacement, err := room.SetPublisherOffer(createPublisherOffer(t))
	if err != nil {
		t.Fatal(err)
	}
	barrier.unblock()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("disconnect callback did not complete")
	}
	if room.isClosed() || room.Snapshot().PublisherID != replacement.PublisherID || viewer.isClosed() {
		t.Fatal("old disconnect closed the replacement publisher or its viewers")
	}
}

func TestPublisherDisconnectOnlyClosesCurrentSession(t *testing.T) {
	for _, state := range []webrtc.PeerConnectionState{
		webrtc.PeerConnectionStateDisconnected, webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed,
	} {
		t.Run(state.String(), func(t *testing.T) {
			room := newRoomForTest("2", nil)
			current := &fakePeerConnection{}
			viewer := &fakePeerConnection{}
			room.publisher = &publisherSession{id: "current", pc: current}
			room.viewers["viewer"] = &viewerSession{pc: viewer}
			defer room.Close()
			room.handlePublisherDisconnected("previous", state)
			if err := room.AddPublisherCandidate("previous", webrtc.ICECandidateInit{Candidate: "stale"}); err != nil {
				t.Fatal(err)
			}
			if room.ForwardRTPFromPublisher("previous", videoCodecAV1, &rtp.Packet{}) {
				t.Fatal("stale RTP was forwarded")
			}
			if room.isClosed() || current.isClosed() || viewer.isClosed() || len(current.addedCandidates()) != 0 {
				t.Fatal("stale callback or ICE affected the current session")
			}
			room.handlePublisherDisconnected("current", state)
			if !room.isClosed() || !current.isClosed() || !viewer.isClosed() || room.Snapshot().HasPublisher {
				t.Fatal("current disconnect did not release the session")
			}
		})
	}
}

// Pause exactly at the disconnect log, between the old identity check and Close.
type disconnectLogBarrier struct {
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (h *disconnectLogBarrier) Enabled(context.Context, slog.Level) bool { return true }
func (h *disconnectLogBarrier) WithAttrs([]slog.Attr) slog.Handler       { return h }
func (h *disconnectLogBarrier) WithGroup(string) slog.Handler            { return h }
func (h *disconnectLogBarrier) unblock()                                 { h.once.Do(func() { close(h.release) }) }
func (h *disconnectLogBarrier) Handle(_ context.Context, record slog.Record) error {
	if record.Message == "publisher disconnected" {
		previous := false
		record.Attrs(func(attr slog.Attr) bool {
			previous = previous || (attr.Key == "publisherID" && attr.Value.String() == "previous")
			return true
		})
		if previous {
			close(h.entered)
			<-h.release
		}
	}
	return nil
}
