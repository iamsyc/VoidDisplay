package relay

import (
	"bytes"
	"testing"

	"github.com/pion/rtp"
)

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
