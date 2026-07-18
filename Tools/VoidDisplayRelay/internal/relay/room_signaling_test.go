package relay

import (
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

func TestRoomConcurrentRemoveAndForwardDoesNotRace(t *testing.T) {
	room := newRoomForTest("2", nil)
	sink := &recordingSink{}
	room.subscribers["viewer"] = newViewerRTPWriter("2", "viewer", videoCodecAV1, sink, nil)
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
	room.publisherCodecs[videoCodecAV1] = struct{}{}
	room.publisherSSRCs[videoCodecAV1] = 1234

	if _, err := room.SetPublisherOffer("invalid-sdp"); err == nil {
		t.Fatal("SetPublisherOffer succeeded for invalid SDP")
	}

	if room.publisher == nil || room.publisher.id != "current" {
		t.Fatalf("current publisher was not preserved: %#v", room.publisher)
	}
	if room.publisherSSRCs[videoCodecAV1] != 1234 {
		t.Fatalf("publisher AV1 SSRC = %d, want 1234", room.publisherSSRCs[videoCodecAV1])
	}
	if current.isClosed() {
		t.Fatal("current publisher was closed")
	}
}

func TestRoomSuccessfulPublisherOfferAtomicallyReplacesCurrentPublisher(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	current := &fakePeerConnection{}
	room.publisher = &publisherSession{id: "current", pc: current}
	room.publisherCodecs[videoCodecAV1] = struct{}{}
	room.publisherSSRCs[videoCodecAV1] = 1234

	result, err := room.SetPublisherOffer(createPublisherOfferWithCodec(t, webrtc.MimeTypeAV1))
	if err != nil {
		t.Fatalf("SetPublisherOffer returned error: %v", err)
	}

	if result.PublisherID == "" || result.PublisherID == "current" {
		t.Fatalf("replacement publisher ID = %q", result.PublisherID)
	}
	if room.publisher == nil || room.publisher.id != result.PublisherID {
		t.Fatalf("active publisher = %#v, want %q", room.publisher, result.PublisherID)
	}
	if !current.isClosed() {
		t.Fatal("replaced publisher remained open")
	}
	if _, exists := room.publisherSSRCs[videoCodecAV1]; exists {
		t.Fatal("replacement inherited previous publisher SSRC")
	}
}

func TestRoomDoesNotCloseWhilePublisherOfferIsInFlight(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	factoryEntered := make(chan struct{})
	releaseFactory := make(chan struct{})
	offer := createPublisherOfferWithCodec(t, webrtc.MimeTypeAV1)
	room := NewRoom("2", nil, func() (*webrtc.PeerConnection, error) {
		close(factoryEntered)
		<-releaseFactory
		return server.newPeerConnection()
	})
	result := make(chan error, 1)
	go func() {
		_, err := room.SetPublisherOffer(offer)
		result <- err
	}()

	<-factoryEntered
	if room.CloseIfNoPublisher() {
		t.Fatal("room closed while publisher offer was in flight")
	}
	close(releaseFactory)
	if err := <-result; err != nil {
		t.Fatalf("publisher offer failed after close check: %v", err)
	}
}

func TestRoomPublisherRejectsVP8OnlyOffer(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)

	if _, err := room.SetPublisherOffer(createPublisherOfferWithCodec(t, webrtc.MimeTypeVP8)); err == nil {
		t.Fatal("SetPublisherOffer accepted VP8-only SDP")
	}
}

func TestRoomPublisherRejectsH265OnlyOffer(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)

	if _, err := room.SetPublisherOffer(createPublisherOfferWithCodec(t, webrtc.MimeTypeH265)); err == nil {
		t.Fatal("SetPublisherOffer accepted H265-only SDP")
	}
}

func TestRoomPublisherRejectsMixedSupportedAndUnsupportedVideoOffer(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	offer := appendUnsupportedVideoCodecForTest(
		createPublisherOfferWithCodec(t, webrtc.MimeTypeAV1),
		"96",
		"VP8",
	)

	_, err := room.SetPublisherOffer(offer)

	if !errors.Is(err, errUnsupportedVideoCodecOffered) {
		t.Fatalf("SetPublisherOffer error = %v, want unsupported codec", err)
	}
}

func TestRoomPublisherAcceptsAV1Offer(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)

	result, err := room.SetPublisherOffer(createPublisherOfferWithCodec(t, webrtc.MimeTypeAV1))
	if err != nil {
		t.Fatalf("SetPublisherOffer returned error: %v", err)
	}
	assertVideoSDPOnlyCodec(t, result.SDP, videoCodecAV1)
	snapshot := room.Snapshot()
	if strings.Join(snapshot.PublisherCodecs, ",") != "av1" {
		t.Fatalf("publisher codecs = %v, want [av1]", snapshot.PublisherCodecs)
	}
}

func TestRoomPublisherRejectsDuplicateCodecVideoMLine(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)

	_, err := room.SetPublisherOffer(createPublisherOfferWithCodecs(t, []videoCodec{videoCodecAV1, videoCodecAV1}))

	if !errors.Is(err, errPublisherCodecDuplicate) {
		t.Fatalf("SetPublisherOffer error = %v, want duplicate codec", err)
	}
}

func TestRoomViewerAnswerUsesOnlyAV1(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	room.publisherCodecs[videoCodecAV1] = struct{}{}
	room.publisherSSRCs[videoCodecAV1] = 1234

	answer, err := room.SetViewerOffer("viewer", createViewerOfferWithCodec(t, videoCodecAV1))
	if err != nil {
		t.Fatalf("SetViewerOffer returned error: %v", err)
	}
	assertVideoSDPOnlyCodec(t, answer.SDP, videoCodecAV1)
	if answer.Codec != videoCodecAV1 {
		t.Fatalf("viewer answer codec = %s, want av1", answer.Codec)
	}
	if room.viewers["viewer"].codec != videoCodecAV1 {
		t.Fatalf("viewer codec = %s, want av1", room.viewers["viewer"].codec)
	}
}

func TestRoomViewerRejectsOfferWhenViewerLacksAV1(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	room.publisherCodecs[videoCodecAV1] = struct{}{}
	room.publisherSSRCs[videoCodecAV1] = 1234

	_, err := room.SetViewerOffer("viewer", createViewerOfferWithMimeType(t, webrtc.MimeTypeH264))

	if !errors.Is(err, errUnsupportedVideoCodecOffered) && !errors.Is(err, errSupportedVideoCodecMissing) {
		t.Fatalf("SetViewerOffer error = %v, want unsupported or missing codec", err)
	}
}

func TestRoomViewerUsesNegotiatedAV1BeforeAV1RTPStarts(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	room.publisherCodecs[videoCodecAV1] = struct{}{}
	room.publisherSSRCs[videoCodecAV1] = 5678

	answer, err := room.SetViewerOffer("viewer", createViewerOfferWithCodec(t, videoCodecAV1))
	if err != nil {
		t.Fatalf("SetViewerOffer returned error: %v", err)
	}
	assertVideoSDPOnlyCodec(t, answer.SDP, videoCodecAV1)
	if answer.Codec != videoCodecAV1 {
		t.Fatalf("viewer answer codec = %s, want av1", answer.Codec)
	}
	if room.viewers["viewer"].codec != videoCodecAV1 {
		t.Fatalf("viewer codec = %s, want av1", room.viewers["viewer"].codec)
	}
}

func TestRoomViewerUsesNegotiatedCodecsBeforePublisherRTPStarts(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	room.publisherCodecs[videoCodecAV1] = struct{}{}

	answer, err := room.SetViewerOffer("viewer", createViewerOfferWithCodec(t, videoCodecAV1))
	if err != nil {
		t.Fatalf("SetViewerOffer returned error: %v", err)
	}
	assertVideoSDPOnlyCodec(t, answer.SDP, videoCodecAV1)
	if answer.Codec != videoCodecAV1 {
		t.Fatalf("viewer answer codec = %s, want av1", answer.Codec)
	}
	if room.viewers["viewer"].codec != videoCodecAV1 {
		t.Fatalf("viewer codec = %s, want av1", room.viewers["viewer"].codec)
	}
}

func TestRoomViewerReturnsCodecPendingUntilPublisherCodecsAreNegotiated(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)

	_, err := room.SetViewerOffer("viewer", createViewerOfferWithCodecs(t, []videoCodec{videoCodecAV1, videoCodecAV1}))

	if !errors.Is(err, errPublisherCodecPending) {
		t.Fatalf("SetViewerOffer error = %v, want codec pending", err)
	}
}

func TestRoomViewerRejectsUnsupportedVideoCodecOffer(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	room.publisherCodecs[videoCodecAV1] = struct{}{}
	room.publisherSSRCs[videoCodecAV1] = 1234

	if _, err := room.SetViewerOffer("viewer-vp8", createViewerOfferWithMimeType(t, webrtc.MimeTypeVP8)); err == nil {
		t.Fatal("SetViewerOffer accepted VP8-only SDP")
	}
	if _, err := room.SetViewerOffer("viewer-h265", createViewerOfferWithMimeType(t, webrtc.MimeTypeH265)); err == nil {
		t.Fatal("SetViewerOffer accepted H265-only SDP")
	}
}

func TestRoomViewerRejectsMixedSupportedAndUnsupportedVideoOffer(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	room.publisherCodecs[videoCodecAV1] = struct{}{}
	room.publisherSSRCs[videoCodecAV1] = 1234
	offer := appendUnsupportedVideoCodecForTest(
		createViewerOfferWithCodec(t, videoCodecAV1),
		"116",
		"H265",
	)

	_, err := room.SetViewerOffer("viewer", offer)

	if !errors.Is(err, errUnsupportedVideoCodecOffered) {
		t.Fatalf("SetViewerOffer error = %v, want unsupported codec", err)
	}
}

func TestRoomForwardRTPRewritesViewerPayloadTypeFromNegotiatedAV1Binding(t *testing.T) {
	room := newRoomForTest("2", nil)
	track, err := webrtc.NewTrackLocalStaticRTP(mustTrackCapability(t, videoCodecAV1), "screen", "voiddisplay")
	if err != nil {
		t.Fatal(err)
	}
	stream := &capturingTrackLocalWriter{}
	_, err = track.Bind(fakeTrackLocalContext{
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: mustTrackCapability(t, videoCodecAV1),
			PayloadType:        124,
		}},
		ssrc:        5678,
		writeStream: stream,
	})
	if err != nil {
		t.Fatal(err)
	}
	room.subscribers["viewer"] = newViewerRTPWriter("2", "viewer", videoCodecAV1, track, nil)
	defer room.Close()

	room.ForwardRTPForCodec(videoCodecAV1, &rtp.Packet{
		Header: rtp.Header{
			PayloadType:    102,
			SSRC:           1234,
			Timestamp:      42,
			SequenceNumber: 7,
		},
		Payload: []byte{1, 2, 3},
	})

	waitFor(t, func() bool { return stream.count() == 1 })
	header := stream.onlyHeader(t)
	if header.PayloadType != 124 {
		t.Fatalf("viewer RTP payload type = %d, want 124", header.PayloadType)
	}
	if header.SSRC != 5678 {
		t.Fatalf("viewer RTP SSRC = %d, want 5678", header.SSRC)
	}
}

func TestRoomForwardRTPForCodecSendsAV1PacketsToAV1Viewers(t *testing.T) {
	room := newRoomForTest("2", nil)
	first := &recordingSink{}
	second := &recordingSink{}
	room.subscribers["first"] = newViewerRTPWriter("2", "first", videoCodecAV1, first, nil)
	room.subscribers["second"] = newViewerRTPWriter("2", "second", videoCodecAV1, second, nil)
	defer room.Close()

	room.ForwardRTPForCodec(videoCodecAV1, &rtp.Packet{
		Header:  rtp.Header{Timestamp: 11},
		Payload: []byte{1},
	})

	waitFor(t, func() bool { return first.count() == 1 && second.count() == 1 })
	if got := first.onlyPacket(t).Timestamp; got != 11 {
		t.Fatalf("first viewer timestamp = %d, want 11", got)
	}
	if got := second.onlyPacket(t).Timestamp; got != 11 {
		t.Fatalf("second viewer timestamp = %d, want 11", got)
	}
}
