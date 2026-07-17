package relay

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
)

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
