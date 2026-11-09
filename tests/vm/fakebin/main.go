// Copyright (c) 2026 InfAI (CC SES)

// fakebin stands in for a host binary in the VM tests: it ignores its arguments, runs until SIGTERM
// and then exits after the delay in the environment variable FAKEBIN_STOP_DELAY (a Go duration,
// e.g. "3s"), to simulate the core-manager stopping its containers. It has to be a real executable:
// the process matching compares the first entry of /proc/<pid>/cmdline with the binary's path, which
// for a script would be its interpreter.
package main

import (
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	if d, err := time.ParseDuration(os.Getenv("FAKEBIN_STOP_DELAY")); err == nil {
		time.Sleep(d)
	}
}
