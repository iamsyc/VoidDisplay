package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"voiddisplay-relay/internal/relay"
)

func main() {
	var controlTokenStdin bool
	var loopbackHTTP string
	var listenUDP string
	var parentPID int
	flag.BoolVar(&controlTokenStdin, "control-token-stdin", false, "read the shared control token from standard input")
	flag.StringVar(&loopbackHTTP, "loopback-http", "127.0.0.1:0", "loopback HTTP listen address")
	flag.StringVar(&listenUDP, "listen-udp", ":0", "UDP4 listen address for WebRTC traffic")
	flag.IntVar(&parentPID, "parent-pid", 0, "parent process identifier to monitor")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if !controlTokenStdin {
		logger.Error("control token input is required")
		os.Exit(2)
	}
	controlToken, err := readControlToken(os.Stdin)
	if err != nil {
		logger.Error("failed to read control token", "error", err)
		os.Exit(2)
	}
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

	err = server.ListenAndServe(ctx, loopbackHTTP, func(loopback string) {
		fmt.Fprintln(os.Stdout, relay.ReadyJSON(loopback))
	})
	if err != nil {
		logger.Error("relay stopped with error", "error", err)
		os.Exit(1)
	}
}

const maxControlTokenBytes = 256

func readControlToken(reader io.Reader) (string, error) {
	buffered := bufio.NewReaderSize(io.LimitReader(reader, maxControlTokenBytes+2), maxControlTokenBytes+2)
	line, err := buffered.ReadString('\n')
	if err != nil {
		return "", errors.New("control_token_line_missing")
	}
	token := line[:len(line)-1]
	if len(token) > 0 && token[len(token)-1] == '\r' {
		token = token[:len(token)-1]
	}
	if token == "" {
		return "", errors.New("control_token_empty")
	}
	if len(token) > maxControlTokenBytes {
		return "", errors.New("control_token_too_large")
	}
	return token, nil
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
