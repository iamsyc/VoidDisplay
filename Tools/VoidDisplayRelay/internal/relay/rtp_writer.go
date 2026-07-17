package relay

import (
	"errors"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"

	"github.com/pion/rtp"
)

type viewerRTPWriter struct {
	roomID            string
	clientID          string
	codec             videoCodec
	logger            *slog.Logger
	sink              rtpSink
	queue             chan *rtp.Packet
	done              chan struct{}
	mu                sync.Mutex
	closed            bool
	viewerExtensions  map[string]uint8
	extensionRewrites map[uint8]uint8
	written           atomic.Uint64
	dropped           atomic.Uint64
}

func newViewerRTPWriter(roomID string, clientID string, codec videoCodec, sink rtpSink, logger *slog.Logger) *viewerRTPWriter {
	if logger == nil {
		logger = slog.Default()
	}
	writer := &viewerRTPWriter{
		roomID:            roomID,
		clientID:          clientID,
		codec:             codec,
		logger:            logger,
		sink:              sink,
		queue:             make(chan *rtp.Packet, subscriberRTPQueueSize),
		done:              make(chan struct{}),
		viewerExtensions:  make(map[string]uint8),
		extensionRewrites: make(map[uint8]uint8),
	}
	go writer.run()
	return writer
}

func (w *viewerRTPWriter) enqueue(packet *rtp.Packet) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return false
	}
	packetCopy := packet.Clone()
	w.rewriteHeaderExtensions(packetCopy)
	select {
	case w.queue <- packetCopy:
		return true
	default:
		w.dropped.Add(1)
		w.logger.Debug("viewer RTP queue full", "room", w.roomID, "clientID", w.clientID)
		return false
	}
}

func (w *viewerRTPWriter) setViewerExtensions(extensions map[string]uint8) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.viewerExtensions = copyHeaderExtensionMap(extensions)
}

func (w *viewerRTPWriter) setExtensionRewrites(rewrites map[uint8]uint8) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.extensionRewrites = copyExtensionRewriteMap(rewrites)
}

func (w *viewerRTPWriter) setPublisherExtensions(extensions map[string]uint8) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.extensionRewrites = headerExtensionRewrites(extensions, w.viewerExtensions)
}

func (w *viewerRTPWriter) rewriteHeaderExtensions(packet *rtp.Packet) {
	type pendingRewrite struct {
		viewerID uint8
		payload  []byte
	}
	pendingRewrites := make([]pendingRewrite, 0, len(w.extensionRewrites))
	for publisherID, viewerID := range w.extensionRewrites {
		payload := packet.GetExtension(publisherID)
		if payload == nil {
			continue
		}
		payloadCopy := append([]byte(nil), payload...)
		_ = packet.DelExtension(publisherID)
		if viewerID != 0 {
			pendingRewrites = append(pendingRewrites, pendingRewrite{
				viewerID: viewerID,
				payload:  payloadCopy,
			})
		}
	}
	for _, rewrite := range pendingRewrites {
		_ = packet.SetExtension(rewrite.viewerID, rewrite.payload)
	}
}

func (w *viewerRTPWriter) run() {
	for {
		select {
		case <-w.done:
			return
		case packet := <-w.queue:
			if err := w.sink.WriteRTP(packet); err != nil && !errors.Is(err, io.ErrClosedPipe) {
				w.logger.Debug("viewer RTP write failed", "room", w.roomID, "clientID", w.clientID, "error", err)
			} else {
				w.written.Add(1)
			}
		}
	}
}

func (w *viewerRTPWriter) close() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return
	}
	w.closed = true
	close(w.done)
}

func (w *viewerRTPWriter) stats() (written uint64, dropped uint64) {
	return w.written.Load(), w.dropped.Load()
}
