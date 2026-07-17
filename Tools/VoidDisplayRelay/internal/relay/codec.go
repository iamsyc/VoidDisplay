package relay

import (
	"errors"
	"strings"

	pionsdp "github.com/pion/sdp/v3"
	"github.com/pion/webrtc/v4"
)

type videoCodec string

const (
	videoCodecAV1 videoCodec = "av1"
)

var errSupportedVideoCodecMissing = errors.New("supported_video_codec_missing")
var errUnsupportedVideoCodecOffered = errors.New("unsupported_video_codec_offered")
var errPublisherCodecPending = errors.New("publisher_codec_pending")
var errPublisherCodecDuplicate = errors.New("publisher_video_codec_duplicate")

var av1RTCPFeedback = []webrtc.RTCPFeedback{
	{Type: "goog-remb"},
	{Type: "ccm", Parameter: "fir"},
	{Type: "nack"},
	{Type: "nack", Parameter: "pli"},
}

var av1CodecParameters = []webrtc.RTPCodecParameters{
	{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:     webrtc.MimeTypeAV1,
			ClockRate:    90000,
			RTCPFeedback: av1RTCPFeedback,
		},
		PayloadType: 45,
	},
	{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeRTX,
			ClockRate:   90000,
			SDPFmtpLine: "apt=45",
		},
		PayloadType: 46,
	},
}

func registerVideoCodecs(mediaEngine *webrtc.MediaEngine) error {
	for _, codec := range av1CodecParameters {
		if err := mediaEngine.RegisterCodec(codec, webrtc.RTPCodecTypeVideo); err != nil {
			return err
		}
	}
	return nil
}

func trackCapability(codec videoCodec) (webrtc.RTPCodecCapability, error) {
	if codec != videoCodecAV1 {
		return webrtc.RTPCodecCapability{}, errUnsupportedVideoCodecOffered
	}
	return webrtc.RTPCodecCapability{
		MimeType:     webrtc.MimeTypeAV1,
		ClockRate:    90000,
		RTCPFeedback: av1RTCPFeedback,
	}, nil
}

func codecParametersForVideoCodec(codec videoCodec) ([]webrtc.RTPCodecParameters, error) {
	if codec != videoCodecAV1 {
		return nil, errUnsupportedVideoCodecOffered
	}
	return append([]webrtc.RTPCodecParameters(nil), av1CodecParameters...), nil
}

func codecFromName(name string) (videoCodec, bool) {
	switch {
	case strings.EqualFold(name, "AV1"), strings.EqualFold(name, webrtc.MimeTypeAV1):
		return videoCodecAV1, true
	default:
		return "", false
	}
}

type videoMediaCodecSet struct {
	codecs                  map[videoCodec]struct{}
	unsupportedPrimaryCount int
}

func videoMediaCodecSets(sdp string) ([]videoMediaCodecSet, error) {
	var description pionsdp.SessionDescription
	if err := description.UnmarshalString(sdp); err != nil {
		return nil, err
	}
	mediaCodecSets := make([]videoMediaCodecSet, 0)
	payloadTypes := make(map[string]struct{})
	payloadNames := make(map[string]string)
	inVideo := false
	flush := func() {
		if !inVideo {
			return
		}
		codecSet := make(map[videoCodec]struct{})
		unsupportedPrimaryCount := 0
		for payloadType := range payloadTypes {
			name := payloadNames[payloadType]
			if videoCodec, ok := codecFromName(name); ok {
				codecSet[videoCodec] = struct{}{}
				continue
			}
			if !strings.EqualFold(name, "rtx") {
				unsupportedPrimaryCount++
			}
		}
		mediaCodecSets = append(mediaCodecSets, videoMediaCodecSet{
			codecs:                  codecSet,
			unsupportedPrimaryCount: unsupportedPrimaryCount,
		})
	}
	for _, line := range strings.Split(sdp, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "m=") {
			flush()
			inVideo = strings.HasPrefix(line, "m=video ")
			payloadTypes = make(map[string]struct{})
			payloadNames = make(map[string]string)
			if inVideo {
				parts := strings.Fields(line)
				for _, payloadType := range parts[3:] {
					payloadTypes[payloadType] = struct{}{}
				}
			}
			continue
		}
		if !inVideo || !strings.HasPrefix(line, "a=rtpmap:") {
			continue
		}
		parts := strings.Fields(strings.TrimPrefix(line, "a=rtpmap:"))
		if len(parts) < 2 {
			continue
		}
		payloadType := parts[0]
		payloadNames[payloadType] = strings.SplitN(parts[1], "/", 2)[0]
	}
	flush()
	return mediaCodecSets, nil
}

func publisherVideoCodecs(sdp string) ([]videoCodec, error) {
	mediaCodecSets, err := videoMediaCodecSets(sdp)
	if err != nil {
		return nil, err
	}
	codecs := make([]videoCodec, 0, len(mediaCodecSets))
	seen := make(map[videoCodec]struct{})
	for _, mediaCodecSet := range mediaCodecSets {
		if mediaCodecSet.unsupportedPrimaryCount > 0 {
			return nil, errUnsupportedVideoCodecOffered
		}
		if len(mediaCodecSet.codecs) == 0 {
			return nil, errSupportedVideoCodecMissing
		}
		if _, ok := mediaCodecSet.codecs[videoCodecAV1]; ok && len(mediaCodecSet.codecs) == 1 {
			if _, duplicate := seen[videoCodecAV1]; duplicate {
				return nil, errPublisherCodecDuplicate
			}
			seen[videoCodecAV1] = struct{}{}
			codecs = append(codecs, videoCodecAV1)
			continue
		}
		return nil, errUnsupportedVideoCodecOffered
	}
	if len(codecs) == 0 {
		return nil, errSupportedVideoCodecMissing
	}
	return codecs, nil
}

func codecSetFromList(codecs []videoCodec) map[videoCodec]struct{} {
	result := make(map[videoCodec]struct{}, len(codecs))
	for _, codec := range codecs {
		result[codec] = struct{}{}
	}
	return result
}

func codecListFromSet(codecSet map[videoCodec]struct{}) []videoCodec {
	codecs := make([]videoCodec, 0, len(codecSet))
	if _, ok := codecSet[videoCodecAV1]; ok {
		codecs = append(codecs, videoCodecAV1)
	}
	return codecs
}

func codecStrings(codecs []videoCodec) []string {
	result := make([]string, 0, len(codecs))
	for _, codec := range codecs {
		result = append(result, string(codec))
	}
	return result
}

func headerExtensionIDs(parameters []webrtc.RTPHeaderExtensionParameter) map[string]uint8 {
	result := make(map[string]uint8, len(parameters))
	for _, parameter := range parameters {
		if parameter.ID <= 0 || parameter.ID > 255 || parameter.URI == "" {
			continue
		}
		result[parameter.URI] = uint8(parameter.ID)
	}
	return result
}

func headerExtensionRewrites(
	publisherExtensions map[string]uint8,
	viewerExtensions map[string]uint8,
) map[uint8]uint8 {
	rewrites := make(map[uint8]uint8)
	for uri, publisherID := range publisherExtensions {
		viewerID, ok := viewerExtensions[uri]
		if !ok {
			rewrites[publisherID] = 0
			continue
		}
		rewrites[publisherID] = viewerID
	}
	return rewrites
}

func copyHeaderExtensionMap(input map[string]uint8) map[string]uint8 {
	output := make(map[string]uint8, len(input))
	for key, value := range input {
		output[key] = value
	}
	return output
}

func copyExtensionRewriteMap(input map[uint8]uint8) map[uint8]uint8 {
	output := make(map[uint8]uint8, len(input))
	for key, value := range input {
		output[key] = value
	}
	return output
}

func selectViewerCodec(sdp string, available map[videoCodec]struct{}) (videoCodec, error) {
	mediaCodecSets, err := videoMediaCodecSets(sdp)
	if err != nil {
		return "", err
	}
	if len(available) == 0 {
		return "", errPublisherCodecPending
	}
	offered := make(map[videoCodec]struct{})
	for _, mediaCodecSet := range mediaCodecSets {
		if mediaCodecSet.unsupportedPrimaryCount > 0 {
			return "", errUnsupportedVideoCodecOffered
		}
		if len(mediaCodecSet.codecs) == 0 {
			return "", errSupportedVideoCodecMissing
		}
		for codec := range mediaCodecSet.codecs {
			offered[codec] = struct{}{}
		}
	}
	if _, publisherHasAV1 := available[videoCodecAV1]; publisherHasAV1 {
		if _, viewerHasAV1 := offered[videoCodecAV1]; viewerHasAV1 {
			return videoCodecAV1, nil
		}
	}
	return "", errSupportedVideoCodecMissing
}
