package relay

import (
	"bytes"
	"strconv"
	"testing"

	"github.com/pion/rtp"
)

func TestViewerWriterRejectsEnqueueAfterClose(t *testing.T) {
	sink := &recordingSink{}
	writer := newViewerRTPWriter("2", "viewer", videoCodecH264, sink, nil)
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
	writer := newViewerRTPWriter("2", "viewer", videoCodecH264, sink, nil)
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

func TestViewerWriterUsesNegotiatedPlayoutDelayID(t *testing.T) {
	cases := []struct {
		id       uint8
		existing bool
	}{{5, false}, {14, true}, {32, false}, {32, true}}
	for _, test := range cases {
		t.Run(strconv.Itoa(int(test.id))+"/existing="+strconv.FormatBool(test.existing), func(t *testing.T) {
			id := test.id
			sink := &recordingSink{}
			writer := newViewerRTPWriter("playout", "viewer", videoCodecH264, sink, nil)
			defer writer.close()
			writer.setViewerExtensions(map[string]uint8{testPlayoutDelayURI: id})
			packet := &rtp.Packet{Header: rtp.Header{Timestamp: 100}, Payload: []byte{1, 2}}
			if test.existing {
				if err := packet.SetExtension(1, []byte{9}); err != nil {
					t.Fatal(err)
				}
			}
			if !writer.enqueue(packet) {
				t.Fatal("writer rejected packet")
			}
			waitFor(t, func() bool { return sink.count() == 1 })
			forwarded := sink.onlyPacket(t)
			if got := forwarded.GetExtension(id); !bytes.Equal(got, []byte{0, 0, 0}) {
				t.Fatalf("playout-delay payload = %v, want min=0 and max=0", got)
			}
			encoded, err := forwarded.Marshal()
			if err != nil {
				t.Fatal(err)
			}
			var received rtp.Packet
			if err := received.Unmarshal(encoded); err != nil {
				t.Fatal(err)
			}
			if got := received.GetExtension(id); !bytes.Equal(got, []byte{0, 0, 0}) {
				t.Fatalf("wire playout-delay payload at negotiated ID %d = %v", id, got)
			}
			if !bytes.Equal(received.GetExtension(1), packet.GetExtension(1)) {
				t.Fatal("playout extension changed an existing header extension")
			}
			if packet.GetExtension(id) != nil {
				t.Fatal("writer modified the shared publisher packet")
			}
			if forwarded.Timestamp != packet.Timestamp || !bytes.Equal(forwarded.Payload, packet.Payload) {
				t.Fatal("playout policy changed the media timestamp or payload")
			}
		})
	}
}

func TestViewerWriterOmitsUnnegotiatedPlayoutDelay(t *testing.T) {
	sink := &recordingSink{}
	writer := newViewerRTPWriter("playout", "viewer", videoCodecH264, sink, nil)
	defer writer.close()
	packet := &rtp.Packet{Header: rtp.Header{Timestamp: 100}, Payload: []byte{1}}
	if !writer.enqueue(packet) {
		t.Fatal("writer rejected packet")
	}
	waitFor(t, func() bool { return sink.count() == 1 })
	if len(sink.onlyPacket(t).GetExtensionIDs()) != 0 {
		t.Fatal("writer sent an extension that the viewer did not negotiate")
	}
}
