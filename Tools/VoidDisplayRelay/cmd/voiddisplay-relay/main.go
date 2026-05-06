package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"voiddisplay-relay/internal/relay"
)

func main() {
	var controlToken string
	var loopbackHTTP string
	var listenUDP string
	flag.StringVar(&controlToken, "control-token", "", "shared control token for loopback requests")
	flag.StringVar(&loopbackHTTP, "loopback-http", "127.0.0.1:0", "loopback HTTP listen address")
	flag.StringVar(&listenUDP, "listen-udp", ":0", "UDP4 listen address for WebRTC traffic")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	server := relay.NewServer(relay.Config{
		ControlToken: controlToken,
		ListenUDP:    listenUDP,
		Logger:       logger,
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	err := server.ListenAndServe(ctx, loopbackHTTP, func(loopback string) {
		fmt.Fprintln(os.Stdout, relay.ReadyJSON(loopback))
	})
	if err != nil {
		logger.Error("relay stopped with error", "error", err)
		os.Exit(1)
	}
}
