//go:build unix

package main

import (
	"net/http"
	"syscall"
	"testing"
	"time"
)

// SIGTERM・SIGINT で、正常に停止し、終了コード 0 で終わる（実際の信号を、自分のプロセスへ送る）
func TestRunStopsOnSIGTERMAndSIGINT(t *testing.T) {
	for _, signal := range []syscall.Signal{syscall.SIGTERM, syscall.SIGINT} {
		t.Run(signal.String(), func(t *testing.T) {
			port := freePort(t)
			var stdout, stderr syncBuffer
			code := make(chan int, 1)
			go func() { code <- run(lookupFrom(fullEnv("test", port)), &stdout, &stderr) }()
			base := "http://127.0.0.1:" + port
			waitForHealth(t, base) // 起動した（信号の処理は、起動の前に登録済み）

			if err := syscall.Kill(syscall.Getpid(), signal); err != nil {
				t.Fatalf("send %v: %v", signal, err)
			}
			select {
			case got := <-code:
				if got != 0 {
					t.Fatalf("run() = %d after %v; want 0 (stderr: %s)", got, signal, stderr.String())
				}
			case <-time.After(10 * time.Second):
				t.Fatalf("run did not return after %v", signal)
			}
			if _, err := http.Get(base + "/health"); err == nil {
				t.Error("the server still accepts connections after the stop")
			}
		})
	}
}
