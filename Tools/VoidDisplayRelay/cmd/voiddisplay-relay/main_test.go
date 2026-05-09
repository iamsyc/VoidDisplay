package main

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"
)

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
