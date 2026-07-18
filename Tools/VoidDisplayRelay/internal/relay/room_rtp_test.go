package relay

import (
	"fmt"
	"testing"

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

func TestRoomViewerAdmissionIsBounded(t *testing.T) {
	room := newRoomForTest("2", nil)
	for index := 0; index < maxViewersPerRoom; index++ {
		clientID := fmt.Sprintf("viewer-%d", index)
		if err := room.AddViewerCandidate(clientID, webrtc.ICECandidateInit{Candidate: "candidate:1"}); err != nil {
			t.Fatalf("AddViewerCandidate %d returned error: %v", index, err)
		}
	}
	if err := room.AddViewerCandidate("overflow", webrtc.ICECandidateInit{Candidate: "candidate:1"}); err == nil || err.Error() != "viewer_limit_reached" {
		t.Fatalf("overflow candidate error = %v, want viewer_limit_reached", err)
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
