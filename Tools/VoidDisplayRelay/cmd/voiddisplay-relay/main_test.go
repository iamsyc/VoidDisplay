package main

import (
	"context"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestReadControlTokenRequiresBoundedNewlineTerminatedValue(t *testing.T) {
	token, err := readControlToken(strings.NewReader("secret-token\n"))
	if err != nil {
		t.Fatal(err)
	}
	if token != "secret-token" {
		t.Fatalf("token = %q, want secret-token", token)
	}

	invalid := []string{
		"",
		"missing-newline",
		"\n",
		strings.Repeat("x", maxControlTokenBytes+1) + "\n",
	}
	for _, input := range invalid {
		if _, err := readControlToken(strings.NewReader(input)); err == nil {
			t.Fatalf("readControlToken accepted invalid input of length %d", len(input))
		}
	}
}

func TestMonitorParentProcessCancelsWhenParentMissing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	go monitorParentProcess(ctx, cancel, 1<<30, logger)

	select {
	case <-ctx.Done():
	case <-time.After(2500 * time.Millisecond):
		t.Fatal("expected missing parent process to cancel relay context")
	}
}
