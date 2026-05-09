package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

func TestRoomForwardRTPFansOutOnePublisherPacketToViewers(t *testing.T) {
	room := newRoomForTest("2", nil)
	first := &recordingSink{}
	second := &recordingSink{}
	room.subscribers["first"] = newViewerRTPWriter("2", "first", videoCodecAV1, first, nil)
	room.subscribers["second"] = newViewerRTPWriter("2", "second", videoCodecAV1, second, nil)
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
	room.subscribers["removed"] = newViewerRTPWriter("2", "removed", videoCodecAV1, removed, nil)
	room.subscribers["active"] = newViewerRTPWriter("2", "active", videoCodecAV1, active, nil)
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

func TestRoomSnapshotCountsSubscriberCodecs(t *testing.T) {
	room := newRoomForTest("2", nil)
	room.subscribers["av1-a"] = newViewerRTPWriter("2", "av1-a", videoCodecAV1, &recordingSink{}, nil)
	room.subscribers["av1-b"] = newViewerRTPWriter("2", "av1-b", videoCodecAV1, &recordingSink{}, nil)
	room.subscribers["av1-c"] = newViewerRTPWriter("2", "av1-c", videoCodecAV1, &recordingSink{}, nil)
	defer room.Close()

	snapshot := room.Snapshot()

	if snapshot.SubscriberCodecCounts["av1"] != 3 {
		t.Fatalf("AV1 subscriber count = %d, want 3", snapshot.SubscriberCodecCounts["av1"])
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

func TestRoomPublisherTrackStoppedClearsOnlyMatchingActiveCodec(t *testing.T) {
	room := newRoomForTest("2", nil)
	room.publisher = &publisherSession{id: "publisher-1", pc: &fakePeerConnection{}}
	room.publisherSSRCs[videoCodecAV1] = 1234
	room.publisherExtensions[videoCodecAV1] = map[string]uint8{"av1-extension": 3}

	room.publisherTrackStopped("publisher-1", videoCodecAV1, 9999)
	if room.publisherSSRCs[videoCodecAV1] != 1234 {
		t.Fatalf("AV1 SSRC cleared for nonmatching SSRC")
	}

	room.publisherTrackStopped("publisher-1", videoCodecAV1, 1234)
	if _, ok := room.publisherSSRCs[videoCodecAV1]; ok {
		t.Fatal("AV1 SSRC kept after matching track stopped")
	}
	if _, ok := room.publisherExtensions[videoCodecAV1]; ok {
		t.Fatal("AV1 extensions kept after matching track stopped")
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

func TestRoomForwardFeedbackRetargetsPLIAndFIRAndNACKToPublisherSSRC(t *testing.T) {
	pc := &fakePeerConnection{}
	room := newRoomForTest("2", nil)
	room.publisher = &publisherSession{id: "publisher-1", pc: pc}
	room.publisherSSRCs[videoCodecAV1] = 1234

	room.forwardFeedback(videoCodecAV1, []rtcp.Packet{
		&rtcp.PictureLossIndication{SenderSSRC: 1, MediaSSRC: 55},
		&rtcp.FullIntraRequest{
			SenderSSRC: 2,
			MediaSSRC:  56,
			FIR:        []rtcp.FIREntry{{SSRC: 56, SequenceNumber: 9}},
		},
		&rtcp.TransportLayerNack{
			SenderSSRC: 3,
			MediaSSRC:  57,
			Nacks:      []rtcp.NackPair{{PacketID: 100}},
		},
	})

	packets := pc.writtenRTCP()
	if len(packets) != 3 {
		t.Fatalf("written RTCP count = %d, want 3", len(packets))
	}
	pli, ok := packets[0].(*rtcp.PictureLossIndication)
	if !ok || pli.MediaSSRC != 1234 {
		t.Fatalf("PLI retarget mismatch: %#v", packets[0])
	}
	fir, ok := packets[1].(*rtcp.FullIntraRequest)
	if !ok || fir.MediaSSRC != 1234 || fir.FIR[0].SSRC != 1234 {
		t.Fatalf("FIR retarget mismatch: %#v", packets[1])
	}
	nack, ok := packets[2].(*rtcp.TransportLayerNack)
	if !ok || nack.MediaSSRC != 1234 || nack.Nacks[0].PacketID != 100 {
		t.Fatalf("NACK retarget mismatch: %#v", packets[2])
	}
	if got := room.pliForwardCount.Load(); got != 1 {
		t.Fatalf("PLI count = %d, want 1", got)
	}
	if got := room.firForwardCount.Load(); got != 1 {
		t.Fatalf("FIR count = %d, want 1", got)
	}
	if got := room.nackForwardCount.Load(); got != 1 {
		t.Fatalf("NACK count = %d, want 1", got)
	}
}

func TestRoomStalePublisherStopAndRTPDoNotAffectCurrentPublisher(t *testing.T) {
	room := newRoomForTest("2", nil)
	pc := &fakePeerConnection{}
	sink := &recordingSink{}
	room.publisher = &publisherSession{id: "current", pc: pc}
	room.subscribers["viewer"] = newViewerRTPWriter("2", "viewer", videoCodecAV1, sink, nil)
	defer room.Close()

	room.StopPublisher("stale")
	forwarded := room.ForwardRTPFromPublisher("stale", videoCodecAV1, &rtp.Packet{
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
	defer slow.release()
	active := &recordingSink{}
	room.subscribers["slow"] = newViewerRTPWriter("2", "slow", videoCodecAV1, slow, nil)
	room.subscribers["active"] = newViewerRTPWriter("2", "active", videoCodecAV1, active, nil)
	defer room.Close()

	for index := 0; index < subscriberRTPQueueSize+20; index++ {
		room.ForwardRTP(&rtp.Packet{
			Header:  rtp.Header{Timestamp: uint32(index)},
			Payload: []byte{1},
		})
		expectedActivePackets := index + 1
		waitFor(t, func() bool { return active.count() >= expectedActivePackets })
	}

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
}

func TestViewerWriterRejectsEnqueueAfterClose(t *testing.T) {
	sink := &recordingSink{}
	writer := newViewerRTPWriter("2", "viewer", videoCodecAV1, sink, nil)
	writer.close()

	if writer.enqueue(&rtp.Packet{Header: rtp.Header{Timestamp: 10}, Payload: []byte{1}}) {
		t.Fatal("closed writer accepted RTP")
	}
	if got := sink.count(); got != 0 {
		t.Fatalf("closed writer wrote %d packets, want 0", got)
	}
}

func TestViewerWriterRewritesHeaderExtensionIDs(t *testing.T) {
	sink := &recordingSink{}
	writer := newViewerRTPWriter("2", "viewer", videoCodecAV1, sink, nil)
	defer writer.close()
	writer.setExtensionRewrites(map[uint8]uint8{3: 4, 4: 0})
	packet := &rtp.Packet{
		Header:  rtp.Header{Timestamp: 10},
		Payload: []byte{1},
	}
	if err := packet.SetExtension(3, []byte{9, 8}); err != nil {
		t.Fatal(err)
	}
	if err := packet.SetExtension(4, []byte{7, 6}); err != nil {
		t.Fatal(err)
	}

	if !writer.enqueue(packet) {
		t.Fatal("writer rejected RTP")
	}

	waitFor(t, func() bool { return sink.count() == 1 })
	forwarded := sink.onlyPacket(t)
	if got := forwarded.GetExtension(4); !bytes.Equal(got, []byte{9, 8}) {
		t.Fatalf("viewer extension 4 = %v, want [9 8]", got)
	}
	if got := forwarded.GetExtension(3); got != nil {
		t.Fatalf("publisher extension 3 was not removed: %v", got)
	}
}

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
	pc, _ := createPublisherPeerWithCodec(t, webrtc.MimeTypeAV1)
	defer pc.Close()
	return pc.LocalDescription().SDP
}

func createPublisherOfferWithCodec(t *testing.T, mimeType string) string {
	t.Helper()
	pc, _ := createPublisherPeerWithCodec(t, mimeType)
	defer pc.Close()
	return pc.LocalDescription().SDP
}

func appendUnsupportedVideoCodecForTest(sdp string, payloadType string, codecName string) string {
	lines := strings.Split(sdp, "\n")
	output := make([]string, 0, len(lines)+1)
	insertedRTPMap := false
	inFirstVideo := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "m=video ") && !insertedRTPMap {
			line = strings.TrimRight(line, "\r") + " " + payloadType
			inFirstVideo = true
		} else if strings.HasPrefix(trimmed, "m=") {
			inFirstVideo = false
		}
		output = append(output, line)
		if inFirstVideo && !insertedRTPMap && strings.HasPrefix(trimmed, "m=video ") {
			output = append(output, "a=rtpmap:"+payloadType+" "+codecName+"/90000")
			insertedRTPMap = true
		}
	}
	return strings.Join(output, "\n")
}

func createPublisherOfferWithCodecs(t *testing.T, codecs []videoCodec) string {
	t.Helper()
	mediaEngine := &webrtc.MediaEngine{}
	if err := registerVideoCodecs(mediaEngine); err != nil {
		t.Fatal(err)
	}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(mediaEngine))
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	for _, codec := range codecs {
		track, err := webrtc.NewTrackLocalStaticRTP(
			mustTrackCapability(t, codec),
			"screen-"+string(codec),
			"voiddisplay",
		)
		if err != nil {
			t.Fatal(err)
		}
		transceiver, err := pc.AddTransceiverFromTrack(track, webrtc.RTPTransceiverInit{
			Direction: webrtc.RTPTransceiverDirectionSendonly,
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := transceiver.SetCodecPreferences(mustCodecParameters(t, codec)); err != nil {
			t.Fatal(err)
		}
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
	return filterVideoMediaCodecsForTest(t, localDescription.SDP, codecs)
}

func createPublisherPeerWithCodec(t *testing.T, mimeType string) (*webrtc.PeerConnection, *webrtc.TrackLocalStaticRTP) {
	t.Helper()
	mediaEngine := &webrtc.MediaEngine{}
	var codec webrtc.RTPCodecCapability
	var err error
	switch mimeType {
	case webrtc.MimeTypeH264:
		err = registerH264CodecsForRejectedOfferTest(mediaEngine)
		codec = webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264, ClockRate: 90000}
	case webrtc.MimeTypeAV1:
		err = registerCodecParametersForTest(mediaEngine, av1CodecParameters)
		codec = mustTrackCapability(t, videoCodecAV1)
	case webrtc.MimeTypeVP8:
		err = registerVP8CodecsForTest(mediaEngine)
		codec = webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8, ClockRate: 90000}
	case webrtc.MimeTypeH265:
		err = registerH265CodecsForTest(mediaEngine)
		codec = webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH265, ClockRate: 90000}
	default:
		t.Fatalf("unsupported test codec: %s", mimeType)
	}
	if err != nil {
		t.Fatal(err)
	}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(mediaEngine))
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	track, err := webrtc.NewTrackLocalStaticRTP(
		codec,
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

func createViewerOfferWithCodec(t *testing.T, codec videoCodec) string {
	t.Helper()
	return createViewerOfferWithCodecs(t, []videoCodec{codec})
}

func createViewerOfferWithCodecs(t *testing.T, codecs []videoCodec) string {
	t.Helper()
	mediaEngine := &webrtc.MediaEngine{}
	codecParams := make([]webrtc.RTPCodecParameters, 0)
	for _, codec := range codecs {
		codecParams = append(codecParams, mustCodecParameters(t, codec)...)
	}
	for _, codec := range codecParams {
		if err := mediaEngine.RegisterCodec(codec, webrtc.RTPCodecTypeVideo); err != nil {
			t.Fatal(err)
		}
	}
	return createViewerOfferWithCodecParameters(t, mediaEngine, codecParams)
}

func createViewerOfferWithMimeType(t *testing.T, mimeType string) string {
	t.Helper()
	mediaEngine := &webrtc.MediaEngine{}
	var codecParams []webrtc.RTPCodecParameters
	switch mimeType {
	case webrtc.MimeTypeAV1:
		codecParams = mustCodecParameters(t, videoCodecAV1)
	case webrtc.MimeTypeH264:
		if err := registerH264CodecsForRejectedOfferTest(mediaEngine); err != nil {
			t.Fatal(err)
		}
		codecParams = []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:  webrtc.MimeTypeH264,
				ClockRate: 90000,
			},
			PayloadType: 96,
		}}
	case webrtc.MimeTypeVP8:
		if err := registerVP8CodecsForTest(mediaEngine); err != nil {
			t.Fatal(err)
		}
		codecParams = []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:  webrtc.MimeTypeVP8,
				ClockRate: 90000,
			},
			PayloadType: 96,
		}}
	case webrtc.MimeTypeH265:
		if err := registerH265CodecsForTest(mediaEngine); err != nil {
			t.Fatal(err)
		}
		codecParams = []webrtc.RTPCodecParameters{{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:  webrtc.MimeTypeH265,
				ClockRate: 90000,
			},
			PayloadType: 116,
		}}
	default:
		t.Fatalf("unsupported viewer mime type: %s", mimeType)
	}
	return createViewerOfferWithCodecParameters(t, mediaEngine, codecParams)
}

func createViewerOfferWithCodecParameters(
	t *testing.T,
	mediaEngine *webrtc.MediaEngine,
	codecParams []webrtc.RTPCodecParameters,
) string {
	t.Helper()
	api := webrtc.NewAPI(webrtc.WithMediaEngine(mediaEngine))
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	transceiver, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := transceiver.SetCodecPreferences(codecParams); err != nil {
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
		t.Fatal("viewer local description missing")
	}
	return localDescription.SDP
}

func filterVideoMediaCodecsForTest(t *testing.T, sdp string, targetCodecs []videoCodec) string {
	t.Helper()
	lines := strings.Split(sdp, "\n")
	sections := make([][]string, 0)
	current := make([]string, 0)
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "m=") && len(current) > 0 {
			sections = append(sections, current)
			current = nil
		}
		current = append(current, line)
	}
	if len(current) > 0 {
		sections = append(sections, current)
	}

	videoIndex := 0
	filteredSections := make([]string, 0, len(sections))
	for _, section := range sections {
		if len(section) == 0 || !strings.HasPrefix(strings.TrimSpace(section[0]), "m=video ") {
			filteredSections = append(filteredSections, strings.Join(section, "\n"))
			continue
		}
		if videoIndex >= len(targetCodecs) {
			t.Fatalf("SDP has more video media sections than target codecs:\n%s", sdp)
		}
		filteredSections = append(filteredSections, strings.Join(
			filterVideoMediaSectionForTest(section, targetCodecs[videoIndex]),
			"\n",
		))
		videoIndex++
	}
	if videoIndex != len(targetCodecs) {
		t.Fatalf("SDP video media sections = %d, want %d:\n%s", videoIndex, len(targetCodecs), sdp)
	}
	return strings.Join(filteredSections, "\n")
}

func filterVideoMediaSectionForTest(lines []string, targetCodec videoCodec) []string {
	formats := strings.Fields(strings.TrimSpace(lines[0]))
	payloadNames := make(map[string]string)
	rtxApt := make(map[string]string)
	for _, line := range lines[1:] {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "a=rtpmap:") {
			parts := strings.Fields(strings.TrimPrefix(trimmed, "a=rtpmap:"))
			if len(parts) >= 2 {
				payloadNames[parts[0]] = strings.ToLower(strings.SplitN(parts[1], "/", 2)[0])
			}
			continue
		}
		if strings.HasPrefix(trimmed, "a=fmtp:") {
			parts := strings.Fields(strings.TrimPrefix(trimmed, "a=fmtp:"))
			if len(parts) >= 2 && strings.Contains(parts[1], "apt=") {
				payloadType := parts[0]
				for _, parameter := range strings.Split(parts[1], ";") {
					parameter = strings.TrimSpace(parameter)
					if strings.HasPrefix(parameter, "apt=") {
						rtxApt[payloadType] = strings.TrimPrefix(parameter, "apt=")
					}
				}
			}
		}
	}
	keptPrimary := make(map[string]struct{})
	keptPayloads := make(map[string]struct{})
	for _, payloadType := range formats[3:] {
		if payloadNames[payloadType] == string(targetCodec) {
			keptPrimary[payloadType] = struct{}{}
			keptPayloads[payloadType] = struct{}{}
		}
	}
	for payloadType, apt := range rtxApt {
		if _, ok := keptPrimary[apt]; ok {
			keptPayloads[payloadType] = struct{}{}
		}
	}

	filtered := make([]string, 0, len(lines))
	mline := append([]string(nil), formats[:3]...)
	for _, payloadType := range formats[3:] {
		if _, ok := keptPayloads[payloadType]; ok {
			mline = append(mline, payloadType)
		}
	}
	filtered = append(filtered, strings.Join(mline, " "))
	for _, line := range lines[1:] {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "a=rtpmap:") ||
			strings.HasPrefix(trimmed, "a=fmtp:") ||
			strings.HasPrefix(trimmed, "a=rtcp-fb:") {
			payloadType := strings.Fields(strings.TrimPrefix(strings.TrimPrefix(strings.TrimPrefix(trimmed, "a=rtpmap:"), "a=fmtp:"), "a=rtcp-fb:"))
			if len(payloadType) > 0 {
				if _, ok := keptPayloads[payloadType[0]]; !ok {
					continue
				}
			}
		}
		filtered = append(filtered, line)
	}
	return filtered
}

func registerVP8CodecsForTest(mediaEngine *webrtc.MediaEngine) error {
	videoRTCPFeedback := []webrtc.RTCPFeedback{
		{Type: "goog-remb"},
		{Type: "ccm", Parameter: "fir"},
		{Type: "nack"},
		{Type: "nack", Parameter: "pli"},
	}
	for _, codec := range []webrtc.RTPCodecParameters{
		{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:     webrtc.MimeTypeVP8,
				ClockRate:    90000,
				RTCPFeedback: videoRTCPFeedback,
			},
			PayloadType: 96,
		},
		{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:    webrtc.MimeTypeRTX,
				ClockRate:   90000,
				SDPFmtpLine: "apt=96",
			},
			PayloadType: 97,
		},
	} {
		if err := mediaEngine.RegisterCodec(codec, webrtc.RTPCodecTypeVideo); err != nil {
			return err
		}
	}
	return nil
}

func registerCodecParametersForTest(mediaEngine *webrtc.MediaEngine, codecs []webrtc.RTPCodecParameters) error {
	for _, codec := range codecs {
		if err := mediaEngine.RegisterCodec(codec, webrtc.RTPCodecTypeVideo); err != nil {
			return err
		}
	}
	return nil
}

func registerH264CodecsForRejectedOfferTest(mediaEngine *webrtc.MediaEngine) error {
	videoRTCPFeedback := []webrtc.RTCPFeedback{
		{Type: "goog-remb"},
		{Type: "ccm", Parameter: "fir"},
		{Type: "nack"},
		{Type: "nack", Parameter: "pli"},
	}
	for _, codec := range []webrtc.RTPCodecParameters{
		{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:     webrtc.MimeTypeH264,
				ClockRate:    90000,
				RTCPFeedback: videoRTCPFeedback,
			},
			PayloadType: 96,
		},
		{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:    webrtc.MimeTypeRTX,
				ClockRate:   90000,
				SDPFmtpLine: "apt=96",
			},
			PayloadType: 97,
		},
	} {
		if err := mediaEngine.RegisterCodec(codec, webrtc.RTPCodecTypeVideo); err != nil {
			return err
		}
	}
	return nil
}

func registerH265CodecsForTest(mediaEngine *webrtc.MediaEngine) error {
	videoRTCPFeedback := []webrtc.RTCPFeedback{
		{Type: "goog-remb"},
		{Type: "ccm", Parameter: "fir"},
		{Type: "nack"},
		{Type: "nack", Parameter: "pli"},
	}
	for _, codec := range []webrtc.RTPCodecParameters{
		{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:     webrtc.MimeTypeH265,
				ClockRate:    90000,
				RTCPFeedback: videoRTCPFeedback,
			},
			PayloadType: 116,
		},
		{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:    webrtc.MimeTypeRTX,
				ClockRate:   90000,
				SDPFmtpLine: "apt=116",
			},
			PayloadType: 117,
		},
	} {
		if err := mediaEngine.RegisterCodec(codec, webrtc.RTPCodecTypeVideo); err != nil {
			return err
		}
	}
	return nil
}

func mustTrackCapability(t *testing.T, codec videoCodec) webrtc.RTPCodecCapability {
	t.Helper()
	capability, err := trackCapability(codec)
	if err != nil {
		t.Fatal(err)
	}
	return capability
}

func mustCodecParameters(t *testing.T, codec videoCodec) []webrtc.RTPCodecParameters {
	t.Helper()
	codecs, err := codecParametersForVideoCodec(codec)
	if err != nil {
		t.Fatal(err)
	}
	return codecs
}

func assertVideoSDPOnlyCodec(t *testing.T, sdp string, expected videoCodec) {
	t.Helper()
	assertNoVideoExtmap(t, sdp)
	codecs := videoCodecNamesFromSDP(sdp)
	if len(codecs) == 0 {
		t.Fatalf("SDP video codecs empty:\n%s", sdp)
	}
	hasExpected := false
	for _, codec := range codecs {
		switch strings.ToLower(codec) {
		case string(expected):
			hasExpected = true
		case "rtx":
		default:
			t.Fatalf("SDP contains unexpected video codec %q in codecs %v:\n%s", codec, codecs, sdp)
		}
	}
	if !hasExpected {
		t.Fatalf("SDP did not contain %s in video codecs %v:\n%s", expected, codecs, sdp)
	}
}

func assertNoVideoExtmap(t *testing.T, sdp string) {
	t.Helper()
	inVideo := false
	for _, line := range strings.Split(sdp, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "m=") {
			inVideo = strings.HasPrefix(line, "m=video ")
			continue
		}
		if inVideo && strings.HasPrefix(line, "a=extmap:") {
			t.Fatalf("SDP contains video extmap line %q:\n%s", line, sdp)
		}
	}
}

func videoCodecNamesFromSDP(sdp string) []string {
	byMedia := videoCodecNamesByVideoMediaFromSDP(sdp)
	if len(byMedia) == 0 {
		return nil
	}
	return byMedia[len(byMedia)-1]
}

func videoCodecNamesFromAllVideoSDP(sdp string) []string {
	byMedia := videoCodecNamesByVideoMediaFromSDP(sdp)
	codecs := make([]string, 0)
	for _, mediaCodecs := range byMedia {
		codecs = append(codecs, mediaCodecs...)
	}
	return codecs
}

func videoCodecNamesByVideoMediaFromSDP(sdp string) [][]string {
	var byMedia [][]string
	var payloadTypes []string
	payloadNames := make(map[string]string)
	inVideo := false
	flush := func() {
		if !inVideo {
			return
		}
		codecs := make([]string, 0, len(payloadTypes))
		for _, payloadType := range payloadTypes {
			if codecName, ok := payloadNames[payloadType]; ok {
				codecs = append(codecs, codecName)
			}
		}
		byMedia = append(byMedia, codecs)
	}
	for _, line := range strings.Split(sdp, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "m=") {
			flush()
			inVideo = strings.HasPrefix(line, "m=video ")
			if inVideo {
				parts := strings.Fields(line)
				if len(parts) > 3 {
					payloadTypes = append([]string(nil), parts[3:]...)
				}
				payloadNames = make(map[string]string)
			}
			continue
		}
		if !inVideo || !strings.HasPrefix(line, "a=rtpmap:") {
			continue
		}
		mapping := strings.TrimPrefix(line, "a=rtpmap:")
		parts := strings.Fields(mapping)
		if len(parts) < 2 {
			continue
		}
		payloadType := parts[0]
		codecName := strings.SplitN(parts[1], "/", 2)[0]
		payloadNames[payloadType] = codecName
	}
	flush()
	return byMedia
}

type capturingTrackLocalWriter struct {
	mu      sync.Mutex
	headers []rtp.Header
}

func (w *capturingTrackLocalWriter) WriteRTP(header *rtp.Header, payload []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	headerCopy := *header
	w.headers = append(w.headers, headerCopy)
	return len(payload), nil
}

func (w *capturingTrackLocalWriter) Write(payload []byte) (int, error) {
	return len(payload), nil
}

func (w *capturingTrackLocalWriter) count() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.headers)
}

func (w *capturingTrackLocalWriter) onlyHeader(t *testing.T) rtp.Header {
	t.Helper()
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.headers) != 1 {
		t.Fatalf("captured header count = %d, want 1", len(w.headers))
	}
	return w.headers[0]
}

type fakeTrackLocalContext struct {
	codecs      []webrtc.RTPCodecParameters
	ssrc        webrtc.SSRC
	writeStream webrtc.TrackLocalWriter
}

func (c fakeTrackLocalContext) CodecParameters() []webrtc.RTPCodecParameters {
	return c.codecs
}

func (c fakeTrackLocalContext) HeaderExtensions() []webrtc.RTPHeaderExtensionParameter {
	return nil
}

func (c fakeTrackLocalContext) SSRC() webrtc.SSRC {
	return c.ssrc
}

func (c fakeTrackLocalContext) SSRCRetransmission() webrtc.SSRC {
	return 0
}

func (c fakeTrackLocalContext) SSRCForwardErrorCorrection() webrtc.SSRC {
	return 0
}

func (c fakeTrackLocalContext) WriteStream() webrtc.TrackLocalWriter {
	return c.writeStream
}

func (c fakeTrackLocalContext) ID() string {
	return "fake-track-local-context"
}

func (c fakeTrackLocalContext) RTCPReader() interceptor.RTCPReader {
	return nil
}
