package relay

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

func TestServerAuthorizationAcceptsOnlyNonEmptyControlHeader(t *testing.T) {
	server := NewServer(Config{ControlToken: "token"})
	tests := []struct {
		name       string
		header     string
		authorize  string
		query      string
		wantStatus int
	}{
		{name: "control header", header: "token", wantStatus: http.StatusOK},
		{name: "missing", wantStatus: http.StatusUnauthorized},
		{name: "wrong", header: "wrong", wantStatus: http.StatusUnauthorized},
		{name: "bearer disabled", authorize: "Bearer token", wantStatus: http.StatusUnauthorized},
		{name: "query disabled", query: "?token=token", wantStatus: http.StatusUnauthorized},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, "/events"+test.query, nil)
			if test.header != "" {
				request.Header.Set("X-Control-Token", test.header)
			}
			if test.authorize != "" {
				request.Header.Set("Authorization", test.authorize)
			}
			response := httptest.NewRecorder()

			server.handleEvents(response, request)

			if response.Code != test.wantStatus {
				t.Fatalf("status = %d, want %d", response.Code, test.wantStatus)
			}
		})
	}

	emptyTokenServer := NewServer(Config{})
	request := httptest.NewRequest(http.MethodGet, "/events", nil)
	request.Header.Set("X-Control-Token", "anything")
	response := httptest.NewRecorder()
	emptyTokenServer.handleEvents(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("empty-token server status = %d, want 401", response.Code)
	}
}

func TestValidateLoopbackHTTPAddressRejectsRemoteOrUnspecifiedBindings(t *testing.T) {
	for _, address := range []string{"127.0.0.1:0", "[::1]:0"} {
		if err := validateLoopbackHTTPAddress(address); err != nil {
			t.Fatalf("loopback address %q returned error: %v", address, err)
		}
	}
	for _, address := range []string{"0.0.0.0:0", "192.168.1.20:0", ":0", "invalid"} {
		if err := validateLoopbackHTTPAddress(address); err == nil || err.Error() != "loopback_http_address_required" {
			t.Fatalf("address %q error = %v, want loopback_http_address_required", address, err)
		}
	}
}

func TestServerRejectsOversizedSignalRequestBody(t *testing.T) {
	server := NewServer(Config{ControlToken: "token"})
	body := `{"type":"offer","sdp":"` + strings.Repeat("s", maxSignalRequestBodyBytes) + `"}`
	request := httptest.NewRequest(http.MethodPost, "/room/2/publisher", strings.NewReader(body))
	request.Header.Set("X-Control-Token", "token")
	response := httptest.NewRecorder()

	server.handleRoom(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", response.Code)
	}
}

func TestServerDoesNotExposePublisherCandidateLibraryError(t *testing.T) {
	server := NewServer(Config{ControlToken: "token"})
	room := newRoomForTest("room", nil)
	room.publisher = &publisherSession{
		id: "publisher",
		pc: &fakePeerConnection{addCandidateError: errors.New("pion internal candidate detail")},
	}
	server.rooms["room"] = room
	request := httptest.NewRequest(
		http.MethodPost,
		"/room/room/publisher/publisher/candidate",
		strings.NewReader(`{"candidate":"candidate:1"}`),
	)
	request.Header.Set("X-Control-Token", "token")
	response := httptest.NewRecorder()

	server.handleRoom(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", response.Code)
	}
	if body := response.Body.String(); !strings.Contains(body, `"reason":"invalid_candidate"`) {
		t.Fatalf("response body = %q, want stable invalid_candidate reason", body)
	} else if strings.Contains(body, "pion internal candidate detail") {
		t.Fatalf("response exposed library error: %q", body)
	}
}

func TestServerDoesNotExposeViewerCandidateLibraryError(t *testing.T) {
	server := NewServer(Config{ControlToken: "token"})
	room := newRoomForTest("room", nil)
	room.viewerAdmissions["viewer"] = &viewerAdmission{}
	room.viewers["viewer"] = &viewerSession{
		pc: &fakePeerConnection{addCandidateError: errors.New("pion internal candidate detail")},
	}
	server.rooms["room"] = room
	request := httptest.NewRequest(
		http.MethodPost,
		"/room/room/viewer/viewer/candidate",
		strings.NewReader(`{"candidate":"candidate:1"}`),
	)
	request.Header.Set("X-Control-Token", "token")
	response := httptest.NewRecorder()

	server.handleRoom(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", response.Code)
	}
	if body := response.Body.String(); !strings.Contains(body, `"reason":"invalid_candidate"`) {
		t.Fatalf("response body = %q, want stable invalid_candidate reason", body)
	} else if strings.Contains(body, "pion internal candidate detail") {
		t.Fatalf("response exposed library error: %q", body)
	}
}

func TestServerRoomRegistryIsBounded(t *testing.T) {
	server := NewServer(Config{ControlToken: "token"})
	for index := 0; index < maxRooms; index++ {
		if _, err := server.createRoom(string(rune('a' + index))); err != nil {
			t.Fatalf("createRoom %d returned error: %v", index, err)
		}
	}
	if _, err := server.createRoom("overflow"); err == nil || err.Error() != "room_limit_reached" {
		t.Fatalf("overflow createRoom error = %v, want room_limit_reached", err)
	}
}

func TestServerRoomRegistryReleasesCapacityWhenRoomCloses(t *testing.T) {
	server := NewServer(Config{ControlToken: "token"})
	var first *Room
	for index := 0; index < maxRooms; index++ {
		room, err := server.createRoom(string(rune('a' + index)))
		if err != nil {
			t.Fatalf("createRoom %d returned error: %v", index, err)
		}
		if index == 0 {
			first = room
		}
	}
	first.Close()
	if _, err := server.createRoom("replacement"); err != nil {
		t.Fatalf("createRoom after close returned error: %v", err)
	}
	if got := len(server.Snapshot().Rooms); got != maxRooms {
		t.Fatalf("room count = %d, want %d", got, maxRooms)
	}
}

func TestFailedPublisherOffersDoNotConsumeRoomCapacity(t *testing.T) {
	server := NewServer(Config{ControlToken: "token"})
	for index := 0; index <= maxRooms; index++ {
		body := strings.NewReader(`{"type":"offer","sdp":"invalid"}`)
		request := httptest.NewRequest(
			http.MethodPost,
			"/room/failed-"+strconv.Itoa(index)+"/publisher",
			body,
		)
		request.Header.Set("X-Control-Token", "token")
		response := httptest.NewRecorder()

		server.handleRoom(response, request)

		if response.Code != http.StatusBadRequest {
			t.Fatalf("failed offer %d status = %d, want 400", index, response.Code)
		}
	}
	if got := len(server.Snapshot().Rooms); got != 0 {
		t.Fatalf("room count after failed offers = %d, want 0", got)
	}
}

func TestServerListenUDPBindsSocketAndEventsExposeAddress(t *testing.T) {
	loopback, stopServer := startTestServer(t)
	defer stopServer()

	request, err := http.NewRequest(http.MethodGet, loopback+"/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-Control-Token", "token")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("events status = %d, want 200", response.StatusCode)
	}
	var snapshot Snapshot
	if err := json.NewDecoder(response.Body).Decode(&snapshot); err != nil {
		t.Fatal(err)
	}
	if len(snapshot.UDPListenAddresses) == 0 {
		t.Fatal("events did not include UDP listen addresses")
	}
}

func TestPublisherOfferReturnsPublisherID(t *testing.T) {
	loopback, stopServer := startTestServer(t)
	defer stopServer()
	offerSDP := createPublisherOffer(t)
	body, err := json.Marshal(offerRequest{Type: "offer", SDP: offerSDP})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, loopback+"/room/2/publisher", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-Control-Token", "token")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("publisher offer status = %d, want 200", response.StatusCode)
	}
	var result publisherSignalResponse
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if result.Type != "answer" {
		t.Fatalf("publisher response type = %q, want answer", result.Type)
	}
	if result.SDP == "" {
		t.Fatal("publisher response SDP is empty")
	}
	if result.PublisherID == "" {
		t.Fatal("publisher response publisherID is empty")
	}
}
