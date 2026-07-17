package relay

import (
	"encoding/json"
	"fmt"
)

func ReadyJSON(loopback string) string {
	data, err := json.Marshal(readyEvent{Type: "ready", Loopback: loopback})
	if err != nil {
		return fmt.Sprintf(`{"type":"ready","loopback":%q}`, loopback)
	}
	return string(data)
}
