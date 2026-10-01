package relay

import (
	"errors"
	"strconv"
	"strings"

	pionsdp "github.com/pion/sdp/v3"
	"github.com/pion/webrtc/v4"
)

type videoCodec string

const (
	videoCodecH265  videoCodec = "h265"
	playoutDelayURI            = "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"
)

var errSupportedVideoCodecMissing = errors.New("supported_video_codec_missing")
var errUnsupportedVideoCodecOffered = errors.New("unsupported_video_codec_offered")
var errPublisherCodecPending = errors.New("publisher_codec_pending")
var errPublisherCodecDuplicate = errors.New("publisher_video_codec_duplicate")

var h265RTCPFeedback = []webrtc.RTCPFeedback{
	{Type: "goog-remb"},
	{Type: "ccm", Parameter: "fir"},
	{Type: "nack"},
	{Type: "nack", Parameter: "pli"},
}

// Match the native HEVC Main Level 6 output bounds and single RTP stream.
var h265CodecParameters = []webrtc.RTPCodecParameters{
	{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:     webrtc.MimeTypeH265,
			ClockRate:    90000,
			SDPFmtpLine:  "level-id=180;profile-id=1;tier-flag=0;tx-mode=SRST",
			RTCPFeedback: h265RTCPFeedback,
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
	for _, codec := range h265CodecParameters {
		if err := mediaEngine.RegisterCodec(codec, webrtc.RTPCodecTypeVideo); err != nil {
			return err
		}
	}
	return mediaEngine.RegisterHeaderExtension(
		webrtc.RTPHeaderExtensionCapability{URI: playoutDelayURI},
		webrtc.RTPCodecTypeVideo,
		webrtc.RTPTransceiverDirectionSendonly,
	)
}

func trackCapability(codec videoCodec) (webrtc.RTPCodecCapability, error) {
	if codec != videoCodecH265 {
		return webrtc.RTPCodecCapability{}, errUnsupportedVideoCodecOffered
	}
	return h265CodecParameters[0].RTPCodecCapability, nil
}

func codecParametersForVideoCodec(codec videoCodec) ([]webrtc.RTPCodecParameters, error) {
	if codec != videoCodecH265 {
		return nil, errUnsupportedVideoCodecOffered
	}
	return append([]webrtc.RTPCodecParameters(nil), h265CodecParameters...), nil
}

func codecFromName(name string) (videoCodec, bool) {
	switch {
	case strings.EqualFold(name, "H265"), strings.EqualFold(name, webrtc.MimeTypeH265):
		return videoCodecH265, true
	default:
		return "", false
	}
}

type videoMediaCodecSet struct {
	codecs                  map[videoCodec]struct{}
	unsupportedPrimaryCount int
}

func h265MainLevel(fmtp string) int {
	// RFC 7798 defaults. Pion's generic H265 matching does not enforce these.
	parameters := map[string]string{
		"profile-space": "0", "profile-id": "1", "tier-flag": "0", "level-id": "93", "tx-mode": "SRST",
	}
	for _, part := range strings.Split(fmtp, ";") {
		if key, value, ok := strings.Cut(part, "="); ok {
			parameters[strings.ToLower(strings.TrimSpace(key))] = strings.TrimSpace(value)
		}
	}
	level, err := strconv.Atoi(parameters["level-id"])
	if err != nil || level < 0 || level > 255 || parameters["profile-space"] != "0" ||
		parameters["profile-id"] != "1" || parameters["tier-flag"] != "0" ||
		!strings.EqualFold(parameters["tx-mode"], "SRST") {
		return 0
	}
	return level
}

func videoMediaCodecSets(sdp string, isViewerOffer bool) ([]videoMediaCodecSet, error) {
	var description pionsdp.SessionDescription
	if err := description.UnmarshalString(sdp); err != nil {
		return nil, err
	}
	mediaCodecSets := make([]videoMediaCodecSet, 0)
	for _, media := range description.MediaDescriptions {
		if media.MediaName.Media != "video" {
			continue
		}
		payloadNames := make(map[string]string)
		payloadFormats := make(map[string]string)
		for _, attribute := range media.Attributes {
			parts := strings.SplitN(attribute.Value, " ", 2)
			if len(parts) != 2 {
				continue
			}
			switch attribute.Key {
			case "rtpmap":
				payloadNames[parts[0]] = strings.SplitN(strings.TrimSpace(parts[1]), "/", 2)[0]
			case "fmtp":
				payloadFormats[parts[0]] = parts[1]
			}
		}
		codecSet := make(map[videoCodec]struct{})
		unsupportedPrimaryCount := 0
		for _, payloadType := range media.MediaName.Formats {
			name := payloadNames[payloadType]
			if videoCodec, ok := codecFromName(name); ok {
				level := h265MainLevel(payloadFormats[payloadType])
				// The publisher is bounded to Level 6; viewers may support more.
				if level == 180 || (isViewerOffer && level > 180) {
					codecSet[videoCodec] = struct{}{}
					continue
				}
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
	return mediaCodecSets, nil
}

func publisherVideoCodecs(sdp string) ([]videoCodec, error) {
	mediaCodecSets, err := videoMediaCodecSets(sdp, false)
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
		if _, ok := mediaCodecSet.codecs[videoCodecH265]; ok && len(mediaCodecSet.codecs) == 1 {
			if _, duplicate := seen[videoCodecH265]; duplicate {
				return nil, errPublisherCodecDuplicate
			}
			seen[videoCodecH265] = struct{}{}
			codecs = append(codecs, videoCodecH265)
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
	if _, ok := codecSet[videoCodecH265]; ok {
		codecs = append(codecs, videoCodecH265)
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
	mediaCodecSets, err := videoMediaCodecSets(sdp, true)
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
	if _, publisherHasH265 := available[videoCodecH265]; publisherHasH265 {
		if _, viewerHasH265 := offered[videoCodecH265]; viewerHasH265 {
			return videoCodecH265, nil
		}
	}
	return "", errSupportedVideoCodecMissing
}
