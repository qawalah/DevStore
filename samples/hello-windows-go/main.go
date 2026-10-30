// Minimal Go service used to verify the DevStore Windows pipeline for Go apps.
// Writes a heartbeat line every 5 seconds to
// %ProgramData%\hello-windows-go\heartbeat.log and exits cleanly on Ctrl+C / stop.
package main

import (
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

// Set at build time: -ldflags "-X main.version=1.2.3"
var version = "dev"

func logLine(path, msg string) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s hello-windows-go %s %s\n", time.Now().Format(time.RFC3339), version, msg)
}

func main() {
	base := os.Getenv("ProgramData")
	if base == "" {
		base, _ = os.UserHomeDir()
	}
	dir := filepath.Join(base, "hello-windows-go")
	_ = os.MkdirAll(dir, 0o755)
	logPath := filepath.Join(dir, "heartbeat.log")

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	logLine(logPath, "started")
	for {
		select {
		case <-tick.C:
			logLine(logPath, "alive")
		case <-stop:
			logLine(logPath, "stopped")
			return
		}
	}
}
