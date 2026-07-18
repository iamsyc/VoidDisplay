package relay

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

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
	mu                sync.Mutex
	rtcp              []rtcp.Packet
	closed            bool
	added             []webrtc.ICECandidateInit
	addCandidateError error
}

func (p *fakePeerConnection) AddICECandidate(candidate webrtc.ICECandidateInit) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.addCandidateError != nil {
		return p.addCandidateError
	}
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
