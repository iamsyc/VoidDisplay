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
	room.subscribers["viewer"] = newViewerRTPWriter("2", "viewer", videoCodecH265, sink, nil)
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
	room.publisherCodecs[videoCodecH265] = struct{}{}
	room.publisherSSRCs[videoCodecH265] = 1234

	if _, err := room.SetPublisherOffer("invalid-sdp"); err == nil {
		t.Fatal("SetPublisherOffer succeeded for invalid SDP")
	}

	if room.publisher == nil || room.publisher.id != "current" {
		t.Fatalf("current publisher was not preserved: %#v", room.publisher)
	}
	if room.publisherSSRCs[videoCodecH265] != 1234 {
		t.Fatalf("publisher H265 SSRC = %d, want 1234", room.publisherSSRCs[videoCodecH265])
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
	room.publisherCodecs[videoCodecH265] = struct{}{}
	room.publisherSSRCs[videoCodecH265] = 1234

	result, err := room.SetPublisherOffer(createPublisherOfferWithCodec(t, webrtc.MimeTypeH265))
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
	if _, exists := room.publisherSSRCs[videoCodecH265]; exists {
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
	offer := createPublisherOfferWithCodec(t, webrtc.MimeTypeH265)
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

func TestRoomPublisherRejectsAV1OnlyOffer(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)

	if _, err := room.SetPublisherOffer(createPublisherOfferWithCodec(t, webrtc.MimeTypeAV1)); err == nil {
		t.Fatal("SetPublisherOffer accepted AV1-only SDP")
	}
}

func TestRoomPublisherRejectsH264OnlyOffer(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)

	if _, err := room.SetPublisherOffer(createPublisherOfferWithCodec(t, webrtc.MimeTypeH264)); err == nil {
		t.Fatal("SetPublisherOffer accepted H264-only SDP")
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
		createPublisherOfferWithCodec(t, webrtc.MimeTypeH265),
		"96",
		"VP8",
	)

	_, err := room.SetPublisherOffer(offer)

	if !errors.Is(err, errUnsupportedVideoCodecOffered) {
		t.Fatalf("SetPublisherOffer error = %v, want unsupported codec", err)
	}
}

func TestRoomPublisherAcceptsH265Offer(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)

	result, err := room.SetPublisherOffer(createPublisherOfferWithCodec(t, webrtc.MimeTypeH265))
	if err != nil {
		t.Fatalf("SetPublisherOffer returned error: %v", err)
	}
	assertVideoSDPOnlyCodec(t, result.SDP, videoCodecH265)
	if !strings.Contains(result.SDP, "level-id=180") {
		t.Fatal("publisher answer did not retain HEVC Main Level 6")
	}
	snapshot := room.Snapshot()
	if strings.Join(snapshot.PublisherCodecs, ",") != "h265" {
		t.Fatalf("publisher codecs = %v, want [h265]", snapshot.PublisherCodecs)
	}
}

func TestHEVCOffersRespectMainLevel6Contract(t *testing.T) {
	offer := createPublisherOfferWithCodec(t, webrtc.MimeTypeH265)
	for _, test := range []struct {
		name      string
		fmtp      string
		publisher bool
		viewer    bool
	}{
		{"main-level-6", "level-id=180;profile-id=1;tier-flag=0;tx-mode=SRST", true, true},
		{"default-profile", "level-id=180", true, true},
		{"higher-level", "level-id=183;profile-id=1;tier-flag=0;tx-mode=SRST", false, true},
		{"lower-level", "level-id=153;profile-id=1;tier-flag=0;tx-mode=SRST", false, false},
		{"main10", "level-id=180;profile-id=2;tier-flag=0;tx-mode=SRST", false, false},
		{"high-tier", "level-id=180;profile-id=1;tier-flag=1;tx-mode=SRST", false, false},
		{"multi-stream", "level-id=180;profile-id=1;tier-flag=0;tx-mode=MRST", false, false},
		{"invalid-level", "level-id=invalid;profile-id=1;tier-flag=0;tx-mode=SRST", false, false},
		{"default-level", "profile-id=1;tier-flag=0;tx-mode=SRST", false, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			sdp := strings.ReplaceAll(offer, h265CodecParameters[0].SDPFmtpLine, test.fmtp)
			_, publisherErr := publisherVideoCodecs(sdp)
			_, viewerErr := selectViewerCodec(sdp, codecSetFromList([]videoCodec{videoCodecH265}))
			if (publisherErr == nil) != test.publisher {
				t.Errorf("publisher error = %v, want supported=%v", publisherErr, test.publisher)
			}
			if (viewerErr == nil) != test.viewer {
				t.Errorf("viewer error = %v, want supported=%v", viewerErr, test.viewer)
			}
		})
	}
}

func TestRoomPublisherRejectsDuplicateCodecVideoMLine(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)

	_, err := room.SetPublisherOffer(createPublisherOfferWithCodecs(t, []videoCodec{videoCodecH265, videoCodecH265}))

	if !errors.Is(err, errPublisherCodecDuplicate) {
		t.Fatalf("SetPublisherOffer error = %v, want duplicate codec", err)
	}
}

func TestRoomViewerAnswerUsesOnlyH265(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	room.publisherCodecs[videoCodecH265] = struct{}{}
	room.publisherSSRCs[videoCodecH265] = 1234

	answer, err := room.SetViewerOffer("viewer", createViewerOfferWithCodec(t, videoCodecH265))
	if err != nil {
		t.Fatalf("SetViewerOffer returned error: %v", err)
	}
	assertVideoSDPOnlyCodec(t, answer.SDP, videoCodecH265)
	if answer.Codec != videoCodecH265 {
		t.Fatalf("viewer answer codec = %s, want h265", answer.Codec)
	}
	if room.viewers["viewer"].codec != videoCodecH265 {
		t.Fatalf("viewer codec = %s, want h265", room.viewers["viewer"].codec)
	}
}

func TestRoomViewerRejectsOfferWhenViewerLacksH265(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	room.publisherCodecs[videoCodecH265] = struct{}{}
	room.publisherSSRCs[videoCodecH265] = 1234

	_, err := room.SetViewerOffer("viewer", createViewerOfferWithMimeType(t, webrtc.MimeTypeAV1))

	if !errors.Is(err, errUnsupportedVideoCodecOffered) && !errors.Is(err, errSupportedVideoCodecMissing) {
		t.Fatalf("SetViewerOffer error = %v, want unsupported or missing codec", err)
	}
}

func TestRoomViewerUsesNegotiatedH265BeforeH265RTPStarts(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	room.publisherCodecs[videoCodecH265] = struct{}{}
	room.publisherSSRCs[videoCodecH265] = 5678

	answer, err := room.SetViewerOffer("viewer", createViewerOfferWithCodec(t, videoCodecH265))
	if err != nil {
		t.Fatalf("SetViewerOffer returned error: %v", err)
	}
	assertVideoSDPOnlyCodec(t, answer.SDP, videoCodecH265)
	if answer.Codec != videoCodecH265 {
		t.Fatalf("viewer answer codec = %s, want h265", answer.Codec)
	}
	if room.viewers["viewer"].codec != videoCodecH265 {
		t.Fatalf("viewer codec = %s, want h265", room.viewers["viewer"].codec)
	}
}

func TestRoomViewerUsesNegotiatedCodecsBeforePublisherRTPStarts(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	room.publisherCodecs[videoCodecH265] = struct{}{}

	answer, err := room.SetViewerOffer("viewer", createViewerOfferWithCodec(t, videoCodecH265))
	if err != nil {
		t.Fatalf("SetViewerOffer returned error: %v", err)
	}
	assertVideoSDPOnlyCodec(t, answer.SDP, videoCodecH265)
	if answer.Codec != videoCodecH265 {
		t.Fatalf("viewer answer codec = %s, want h265", answer.Codec)
	}
	if room.viewers["viewer"].codec != videoCodecH265 {
		t.Fatalf("viewer codec = %s, want h265", room.viewers["viewer"].codec)
	}
}

func TestRoomViewerReturnsCodecPendingUntilPublisherCodecsAreNegotiated(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)

	_, err := room.SetViewerOffer("viewer", createViewerOfferWithCodecs(t, []videoCodec{videoCodecH265, videoCodecH265}))

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
	room.publisherCodecs[videoCodecH265] = struct{}{}
	room.publisherSSRCs[videoCodecH265] = 1234

	if _, err := room.SetViewerOffer("viewer-vp8", createViewerOfferWithMimeType(t, webrtc.MimeTypeVP8)); err == nil {
		t.Fatal("SetViewerOffer accepted VP8-only SDP")
	}
	if _, err := room.SetViewerOffer("viewer-h264", createViewerOfferWithMimeType(t, webrtc.MimeTypeH264)); err == nil {
		t.Fatal("SetViewerOffer accepted H264-only SDP")
	}
}

func TestRoomViewerRejectsMixedSupportedAndUnsupportedVideoOffer(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("2", nil, server.newPeerConnection)
	room.publisherCodecs[videoCodecH265] = struct{}{}
	room.publisherSSRCs[videoCodecH265] = 1234
	offer := appendUnsupportedVideoCodecForTest(
		createViewerOfferWithCodec(t, videoCodecH265),
		"116",
		"H264",
	)

	_, err := room.SetViewerOffer("viewer", offer)

	if !errors.Is(err, errUnsupportedVideoCodecOffered) {
		t.Fatalf("SetViewerOffer error = %v, want unsupported codec", err)
	}
}

func TestRoomForwardRTPRewritesViewerPayloadTypeFromNegotiatedH265Binding(t *testing.T) {
	room := newRoomForTest("2", nil)
	track, err := webrtc.NewTrackLocalStaticRTP(mustTrackCapability(t, videoCodecH265), "screen", "voiddisplay")
	if err != nil {
		t.Fatal(err)
	}
	stream := &capturingTrackLocalWriter{}
	_, err = track.Bind(fakeTrackLocalContext{
		codecs: []webrtc.RTPCodecParameters{{
			RTPCodecCapability: mustTrackCapability(t, videoCodecH265),
			PayloadType:        124,
		}},
		ssrc:        5678,
		writeStream: stream,
	})
	if err != nil {
		t.Fatal(err)
	}
	room.subscribers["viewer"] = newViewerRTPWriter("2", "viewer", videoCodecH265, track, nil)
	defer room.Close()

	room.ForwardRTPForCodec(videoCodecH265, &rtp.Packet{
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

func TestRoomForwardRTPForCodecSendsH265PacketsToH265Viewers(t *testing.T) {
	room := newRoomForTest("2", nil)
	first := &recordingSink{}
	second := &recordingSink{}
	room.subscribers["first"] = newViewerRTPWriter("2", "first", videoCodecH265, first, nil)
	room.subscribers["second"] = newViewerRTPWriter("2", "second", videoCodecH265, second, nil)
	defer room.Close()

	room.ForwardRTPForCodec(videoCodecH265, &rtp.Packet{
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

const testPlayoutDelayURI = "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"

func TestViewerAnswerNegotiatesImmediatePlayout(t *testing.T) {
	server := NewServer(Config{ListenUDP: "127.0.0.1:0"})
	if err := server.startWebRTC(); err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	room := NewRoom("playout", nil, server.newPeerConnection)
	defer room.Close()
	room.publisherCodecs[videoCodecH265] = struct{}{}
	room.publisherSSRCs[videoCodecH265] = 1234

	offer := createViewerOfferWithCodec(t, videoCodecH265)
	offer = strings.Replace(offer, "a=recvonly", "a=recvonly\r\na=extmap:5 "+testPlayoutDelayURI, 1)
	if !strings.Contains(offer, "a=extmap:5 "+testPlayoutDelayURI) {
		t.Fatal("test offer did not include the browser's playout-delay extension")
	}
	answer, err := room.SetViewerOffer("viewer", offer)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(answer.SDP, "a=extmap:5 "+testPlayoutDelayURI) {
		t.Fatal("relay answer omitted the offered playout-delay extension")
	}
	if got := room.viewers["viewer"].writer.viewerExtensions[testPlayoutDelayURI]; got != 5 {
		t.Fatalf("writer playout-delay ID = %d, want negotiated ID 5", got)
	}
}
