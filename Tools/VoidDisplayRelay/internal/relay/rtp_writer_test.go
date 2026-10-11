package relay

import (
	"bytes"
	"fmt"
	"io"
	"log/slog"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/pion/rtp"
)

type rtpSinkFunc func(*rtp.Packet) error

func (f rtpSinkFunc) WriteRTP(packet *rtp.Packet) error { return f(packet) }

func TestViewerWriterCountsOnlySuccessfulWrites(t *testing.T) {
	results := []error{nil, io.ErrClosedPipe, fmt.Errorf("wrapped: %w", io.ErrClosedPipe), io.ErrUnexpectedEOF, nil}
	writer := &viewerRTPWriter{
		queue: make(chan *rtp.Packet, len(results)), done: make(chan struct{}), logger: slog.Default(),
	}
	attempts := 0
	writer.sink = rtpSinkFunc(func(_ *rtp.Packet) error {
		err := results[attempts]
		attempts++
		if attempts == len(results) {
			writer.close()
		}
		return err
	})
	for range results {
		writer.queue <- &rtp.Packet{}
	}
	writer.run()
	written, dropped := writer.stats()
	if written != 2 || dropped != 0 {
		t.Fatalf("written=%d queue-dropped=%d, want 2 and 0; failed writes are not successful writes or queue overflow", written, dropped)
	}
}

func TestViewerWriterFullQueuePreservesQueuedPacketAndRecovers(t *testing.T) {
	writer := &viewerRTPWriter{queue: make(chan *rtp.Packet, 1), logger: slog.Default()}
	first := &rtp.Packet{Header: rtp.Header{SequenceNumber: 1}, Payload: []byte{1}}
	second := &rtp.Packet{Header: rtp.Header{SequenceNumber: 2}, Payload: []byte{2}}
	if !writer.enqueue(first) || writer.enqueue(second) {
		t.Fatal("queue must accept the first packet and reject overflow")
	}
	if got := <-writer.queue; got.SequenceNumber != 1 {
		t.Fatalf("overflow replaced queued packet with %d", got.SequenceNumber)
	}
	if !writer.enqueue(second) {
		t.Fatal("queue did not recover after draining")
	}
	second.Payload[0] = 99
	if got := <-writer.queue; got.SequenceNumber != 2 || got.Payload[0] != 2 {
		t.Fatalf("queued packet changed: %+v", got)
	}
	written, dropped := writer.stats()
	if written != 0 || dropped != 1 {
		t.Fatalf("written=%d dropped=%d, want 0 and 1", written, dropped)
	}
}

func BenchmarkViewerWriterFullQueue(b *testing.B) {
	writer := &viewerRTPWriter{queue: make(chan *rtp.Packet, 1), logger: slog.Default()}
	packet := &rtp.Packet{Payload: make([]byte, 1200)}
	writer.queue <- packet
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		writer.enqueue(packet)
	}
}

func BenchmarkViewerWriterAvailableQueue(b *testing.B) {
	writer := &viewerRTPWriter{queue: make(chan *rtp.Packet, 1), logger: slog.Default()}
	packet := &rtp.Packet{Payload: make([]byte, 1200)}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		writer.enqueue(packet)
		<-writer.queue
	}
}

func TestViewerWriterConcurrentProducersRespectCapacity(t *testing.T) {
	writer := &viewerRTPWriter{queue: make(chan *rtp.Packet, 8), done: make(chan struct{}), logger: slog.Default()}
	var producers sync.WaitGroup
	for producer := 0; producer < 4; producer++ {
		producers.Add(1)
		go func() {
			defer producers.Done()
			for i := 0; i < 16; i++ {
				writer.enqueue(&rtp.Packet{Payload: []byte{1}})
			}
		}()
	}
	finished := make(chan struct{})
	go func() { producers.Wait(); close(finished) }()
	select {
	case <-finished:
	case <-time.After(3 * time.Second):
		t.Fatal("concurrent producers blocked on a full queue")
	}
	if queued := len(writer.queue); queued != 8 {
		t.Fatalf("queued %d packets, want 8", queued)
	}
	if _, dropped := writer.stats(); dropped != 56 {
		t.Fatalf("dropped %d packets, want 56", dropped)
	}
	writer.close()
	if writer.enqueue(&rtp.Packet{}) {
		t.Fatal("closed writer accepted a packet")
	}
}

func TestViewerWriterRejectsEnqueueAfterClose(t *testing.T) {
	sink := &recordingSink{}
	writer := newViewerRTPWriter("2", "viewer", videoCodecH265, sink, nil)
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
	writer := newViewerRTPWriter("2", "viewer", videoCodecH265, sink, nil)
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
			writer := newViewerRTPWriter("playout", "viewer", videoCodecH265, sink, nil)
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
	writer := newViewerRTPWriter("playout", "viewer", videoCodecH265, sink, nil)
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
