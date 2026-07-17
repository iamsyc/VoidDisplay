package relay

import (
	"errors"
	"fmt"
	"io"
	"log/slog"

	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

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
