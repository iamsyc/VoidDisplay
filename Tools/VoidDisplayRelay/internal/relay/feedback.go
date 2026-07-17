package relay

import (
	"errors"
	"io"

	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
)

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
