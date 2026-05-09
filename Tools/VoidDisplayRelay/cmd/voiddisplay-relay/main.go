package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"voiddisplay-relay/internal/relay"
)

func main() {
	var controlToken string
	var loopbackHTTP string
	var listenUDP string
	var parentPID int
	flag.StringVar(&controlToken, "control-token", "", "shared control token for loopback requests")
	flag.StringVar(&loopbackHTTP, "loopback-http", "127.0.0.1:0", "loopback HTTP listen address")
	flag.StringVar(&listenUDP, "listen-udp", ":0", "UDP4 listen address for WebRTC traffic")
	flag.IntVar(&parentPID, "parent-pid", 0, "parent process identifier to monitor")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	server := relay.NewServer(relay.Config{
		ControlToken: controlToken,
		ListenUDP:    listenUDP,
		Logger:       logger,
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if parentPID > 1 {
		go monitorParentProcess(ctx, stop, parentPID, logger)
	}

	err := server.ListenAndServe(ctx, loopbackHTTP, func(loopback string) {
		fmt.Fprintln(os.Stdout, relay.ReadyJSON(loopback))
	})
	if err != nil {
		logger.Error("relay stopped with error", "error", err)
		os.Exit(1)
	}
}

func monitorParentProcess(ctx context.Context, cancel context.CancelFunc, parentPID int, logger *slog.Logger) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if os.Getppid() == 1 {
				logger.Info("relay parent process exited", "parent_pid", parentPID)
				cancel()
				return
			}
			err := syscall.Kill(parentPID, 0)
			if err == nil || err == syscall.EPERM {
				continue
			}
			if err == syscall.ESRCH {
				logger.Info("relay parent process is no longer alive", "parent_pid", parentPID)
				cancel()
				return
			}
			logger.Warn("relay parent process check failed", "parent_pid", parentPID, "error", err)
		}
	}
}
