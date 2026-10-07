//go:build unix

package rtmps

import (
	"bytes"
	"errors"
	"io"
	"net"
	"syscall"
	"testing"
	"time"
)

// killSwitch：接続用のソケットを dup して持ち、外から shutdown で壊せること。dup した記述子は、この型だけが持ち、
// release のあとは、触らないこと。

func listenLoopback(t *testing.T) net.Listener {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	return listener
}

func dialWithKillSwitch(ks *killSwitch, address string) (net.Conn, error) {
	dialer := &net.Dialer{Timeout: 2 * time.Second, Control: ks.control}
	return dialer.Dial("tcp", address)
}

func (k *killSwitch) descriptors() []int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return append([]int(nil), k.fds...)
}

func isOpenDescriptor(fd int) bool {
	var stat syscall.Stat_t
	return syscall.Fstat(fd, &stat) == nil
}

func acceptOne(t *testing.T, listener net.Listener) net.Conn {
	t.Helper()
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			close(accepted)
			return
		}
		accepted <- conn
	}()
	select {
	case conn, ok := <-accepted:
		if !ok {
			t.Fatalf("accept failed")
		}
		t.Cleanup(func() { _ = conn.Close() })
		return conn
	case <-time.After(3 * time.Second):
		t.Fatalf("the listener did not accept")
		return nil
	}
}

// 相手が、読み取りの終わり（EOF）を見るまで、最大 timeout 待つ。見えたら true。
func peerSeesEOF(conn net.Conn, timeout time.Duration) bool {
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	buffer := make([]byte, 1)
	_, err := conn.Read(buffer)
	return err != nil && !isTimeout(err)
}

func isTimeout(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

func TestKillSwitchKeepsTheSocketAliveUntilReleased(t *testing.T) {
	listener := listenLoopback(t)
	ks := newKillSwitch()
	client, err := dialWithKillSwitch(ks, listener.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	server := acceptOne(t, listener)

	descriptors := ks.descriptors()
	if len(descriptors) != 1 || !isOpenDescriptor(descriptors[0]) {
		t.Fatalf("descriptors = %v, want one open duplicate", descriptors)
	}

	// 接続を閉じても、複製が残る間は、ソケットは生きている（相手には、切断が届かない）
	if err := client.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if peerSeesEOF(server, 150*time.Millisecond) {
		t.Fatalf("the peer saw the close although the duplicate descriptor is still open")
	}
	// 解放すると、最後の参照が閉じ、相手に切断が届く
	ks.release()
	if !peerSeesEOF(server, 2*time.Second) {
		t.Fatalf("the peer did not see the close after the release")
	}
	if isOpenDescriptor(descriptors[0]) {
		t.Errorf("the duplicate descriptor %d is still open after the release", descriptors[0])
	}
	if got := ks.descriptors(); len(got) != 0 {
		t.Errorf("descriptors after the release = %v, want none", got)
	}
}

func TestKillSwitchShutdownBreaksTheConnectionAndReleasesABlockedReader(t *testing.T) {
	listener := listenLoopback(t)
	ks := newKillSwitch()
	client, err := dialWithKillSwitch(ks, listener.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	server := acceptOne(t, listener)

	readReturned := make(chan error, 1)
	go func() {
		buffer := make([]byte, 1)
		_, err := client.Read(buffer) // 相手が何も書かないので、止まる
		readReturned <- err
	}()
	select {
	case err := <-readReturned:
		t.Fatalf("the read returned before the shutdown: %v", err)
	case <-time.After(100 * time.Millisecond):
	}

	ks.shutdown()
	select {
	case err := <-readReturned:
		if err == nil {
			t.Errorf("the blocked read returned without an error")
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("the blocked read was not released by the shutdown")
	}
	if !peerSeesEOF(server, 2*time.Second) {
		t.Errorf("the peer did not see the connection end after the shutdown")
	}
	ks.release()
}

// 接続できなかった試行（失敗した接続）の複製は、成功のあとで閉じる。成功した接続の複製だけが残る。
func TestKillSwitchClosesTheSocketsOfFailedAttempts(t *testing.T) {
	// 閉じたポート（接続は拒否される）
	closed := listenLoopback(t)
	closedAddress := closed.Addr().String()
	_ = closed.Close()

	good := listenLoopback(t)
	ks := newKillSwitch()
	if conn, err := dialWithKillSwitch(ks, closedAddress); err == nil {
		_ = conn.Close()
		t.Fatalf("dialing a closed port succeeded")
	}
	client, err := dialWithKillSwitch(ks, good.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	acceptOne(t, good)

	before := ks.descriptors()
	if len(before) != 2 {
		t.Fatalf("descriptors before closing the failed attempts = %v, want 2 (the failed attempt and the connected one)", before)
	}
	ks.closeUnconnected()
	after := ks.descriptors()
	if len(after) != 1 {
		t.Fatalf("descriptors after closing the failed attempts = %v, want only the connected one", after)
	}
	if !isOpenDescriptor(after[0]) {
		t.Errorf("the connected socket's duplicate was closed")
	}
	for _, fd := range before {
		if fd != after[0] && isOpenDescriptor(fd) {
			t.Errorf("the failed attempt's duplicate %d was not closed", fd)
		}
	}
	ks.release()
	if isOpenDescriptor(after[0]) {
		t.Errorf("the duplicate is still open after the release")
	}
}

// 解放したあとに、ソケットが作られたら（見放した試行が、まだ接続しようとしている）、接続を始めずに、エラーにする。
func TestKillSwitchRefusesNewSocketsAfterTheRelease(t *testing.T) {
	listener := listenLoopback(t)
	ks := newKillSwitch()
	ks.release()
	conn, err := dialWithKillSwitch(ks, listener.Addr().String())
	if err == nil {
		_ = conn.Close()
		t.Fatalf("a dial after the release succeeded")
	}
	if !errors.Is(err, errKillSwitchReleased) {
		t.Errorf("error = %v, want errKillSwitchReleased", err)
	}
	if got := ks.descriptors(); len(got) != 0 {
		t.Errorf("descriptors = %v, want none", got)
	}
}

// shutdown のあとも、新しいソケットは作らせない（見放した試行が、次のアドレスへ接続して、止まったまま残らない）。
func TestKillSwitchRefusesNewSocketsAfterTheShutdown(t *testing.T) {
	listener := listenLoopback(t)
	ks := newKillSwitch()
	ks.shutdown()
	conn, err := dialWithKillSwitch(ks, listener.Addr().String())
	if err == nil {
		_ = conn.Close()
		t.Fatalf("a dial after the shutdown succeeded")
	}
	if !errors.Is(err, errKillSwitchReleased) {
		t.Errorf("error = %v, want errKillSwitchReleased", err)
	}
	if got := ks.descriptors(); len(got) != 0 {
		t.Errorf("descriptors = %v, want none", got)
	}
	// 接続を受ける側にも、接続が届かない（Control が、接続の前に断る）
	accepted := make(chan struct{}, 1)
	go func() {
		if conn, err := listener.Accept(); err == nil {
			accepted <- struct{}{}
			_ = conn.Close()
		}
	}()
	select {
	case <-accepted:
		t.Errorf("a connection reached the listener after the shutdown")
	case <-time.After(150 * time.Millisecond):
	}
}

// 解放済みの killSwitch への shutdown・release は、害が無い（何度呼んでも）。
func TestKillSwitchIsSafeToUseAfterTheRelease(t *testing.T) {
	ks := newKillSwitch()
	ks.release()
	ks.release()
	ks.shutdown()
	ks.closeUnconnected()
}

// ---- finish：送り切ったあとの、おだやかな終わり ----
//
// ソケットを閉じるとき、読んでいない受信が残っていると、OS は、FIN ではなく RST を送り、送信キューに残っていたものを捨てる。
// go-rtmp を使う試験で、配信の最後の部分が受け口へ届かないことが、実際に起きた（相手が、確認応答などを送ってくる）。

// クライアントのソケットに、相手が送ったデータが届くまで待つ。読まないので、届いたデータは、読まれないまま残る（MSG_PEEK）。
func waitForUnreadData(t *testing.T, conn net.Conn) {
	t.Helper()
	tcp, ok := conn.(*net.TCPConn)
	if !ok {
		t.Fatalf("the connection is %T, want *net.TCPConn", conn)
	}
	raw, err := tcp.SyscallConn()
	if err != nil {
		t.Fatalf("SyscallConn: %v", err)
	}
	if err := conn.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatalf("SetReadDeadline: %v", err)
	}
	defer func() { _ = conn.SetReadDeadline(time.Time{}) }()
	probe := make([]byte, 1)
	var peekErr error
	if err := raw.Read(func(fd uintptr) bool {
		n, _, recvErr := syscall.Recvfrom(int(fd), probe, syscall.MSG_PEEK|syscall.MSG_DONTWAIT)
		switch {
		case recvErr == nil && n > 0:
			return true
		case recvErr == nil:
			peekErr = io.EOF
			return true
		case errors.Is(recvErr, syscall.EAGAIN), errors.Is(recvErr, syscall.EWOULDBLOCK):
			return false
		default:
			peekErr = recvErr
			return true
		}
	}); err != nil {
		t.Fatalf("waiting for the peer's data: %v", err)
	}
	if peekErr != nil {
		t.Fatalf("peeking the peer's data: %v", peekErr)
	}
}

// 相手が読まない間に、書けるだけ書く（相手の受信と自分の送信のバッファが埋まり、送信キューに、送り切れないものが残る）。
// 書けたバイト数を返す。
func fillTheSendQueue(t *testing.T, conn net.Conn) int {
	t.Helper()
	chunk := bytes.Repeat([]byte{'x'}, 64<<10)
	const hardLimit = 256 << 20
	written := 0
	for {
		if err := conn.SetWriteDeadline(time.Now().Add(150 * time.Millisecond)); err != nil {
			t.Fatalf("SetWriteDeadline: %v", err)
		}
		n, err := conn.Write(chunk)
		written += n
		if err != nil {
			if !isTimeout(err) {
				t.Fatalf("write: %v", err)
			}
			break
		}
		if written > hardLimit {
			t.Fatalf("%d bytes were written and the writes never blocked", written)
		}
	}
	if err := conn.SetWriteDeadline(time.Time{}); err != nil {
		t.Fatalf("SetWriteDeadline: %v", err)
	}
	return written
}

// EOF まで読み、読んだバイト数と、終わりの原因を返す（EOF なら nil。RST なら、ECONNRESET）。
func readUntilEOF(conn net.Conn, timeout time.Duration) (int, error) {
	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		return 0, err
	}
	buffer := make([]byte, 32<<10)
	total := 0
	for {
		n, err := conn.Read(buffer)
		total += n
		if errors.Is(err, io.EOF) {
			return total, nil
		}
		if err != nil {
			return total, err
		}
	}
}

// 読まれていない受信が残り、送信キューに送り切れないものがあっても、finish のあとで、相手は、書いたすべてを受け取り、
// 終わりは EOF になる（RST で、最後の部分が捨てられない）。
func TestKillSwitchFinishDeliversEverythingThatWasWritten(t *testing.T) {
	listener := listenLoopback(t)
	ks := newKillSwitch()
	client, err := dialWithKillSwitch(ks, listener.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	server := acceptOne(t, listener)

	// クライアントが読まない受信を作る。この状態で、最後の参照を閉じると、RST が出る
	if _, err := server.Write([]byte("unread")); err != nil {
		t.Fatalf("the peer's write: %v", err)
	}
	waitForUnreadData(t, client)
	written := fillTheSendQueue(t, client)
	if written == 0 {
		t.Fatalf("nothing could be written")
	}
	if err := client.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	finished := make(chan struct{})
	go func() {
		ks.finish(5 * time.Second)
		close(finished)
	}()

	received, readErr := readUntilEOF(server, 10*time.Second)
	if readErr != nil {
		t.Errorf("the peer's read ended with %v, want EOF (the connection was reset)", readErr)
	}
	if received != written {
		t.Errorf("the peer received %d of %d bytes", received, written)
	}

	// 相手が閉じる（FIN）と、finish は、待ちを終えて、記述子を解放する。linger（5 秒）の満了を待たない
	_ = server.Close()
	select {
	case <-finished:
	case <-time.After(3 * time.Second):
		t.Fatalf("finish did not return after the peer closed (it should not wait for the linger to run out)")
	}
	if got := ks.descriptors(); len(got) != 0 {
		t.Errorf("descriptors after finish = %v, want none", got)
	}
}

// 相手が閉じなければ、linger の分だけ待って、解放する（待ちは有限）。
func TestKillSwitchFinishWaitsForThePeerOnlyUpToTheLinger(t *testing.T) {
	listener := listenLoopback(t)
	ks := newKillSwitch()
	client, err := dialWithKillSwitch(ks, listener.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	acceptOne(t, listener) // 相手は、閉じない
	if err := client.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	const linger = 150 * time.Millisecond
	start := time.Now()
	ks.finish(linger)
	elapsed := time.Since(start)
	if elapsed < linger {
		t.Errorf("finish returned after %v, before the linger %v: it did not wait for the peer", elapsed, linger)
	}
	if elapsed > linger+2*time.Second {
		t.Errorf("finish took %v with a linger of %v", elapsed, linger)
	}
	if got := ks.descriptors(); len(got) != 0 {
		t.Errorf("descriptors after finish = %v, want none", got)
	}
}

// 相手が閉じていれば、linger を待たずに終わる。
func TestKillSwitchFinishReturnsAsSoonAsThePeerCloses(t *testing.T) {
	listener := listenLoopback(t)
	ks := newKillSwitch()
	client, err := dialWithKillSwitch(ks, listener.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	server := acceptOne(t, listener)
	if err := client.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	// 相手は、FIN（クライアントの送信側の終わり）を見たら、閉じる
	go func() {
		_, _ = readUntilEOF(server, 5*time.Second)
		_ = server.Close()
	}()
	start := time.Now()
	ks.finish(8 * time.Second)
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Errorf("finish took %v although the peer closed at once", elapsed)
	}
}

// 相手がリセット（RST）したら、もう待つものが無いので、linger を待たずに終わる。
func TestKillSwitchFinishStopsWaitingWhenTheConnectionIsReset(t *testing.T) {
	listener := listenLoopback(t)
	ks := newKillSwitch()
	client, err := dialWithKillSwitch(ks, listener.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	server := acceptOne(t, listener)
	if err := client.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	tcp, ok := server.(*net.TCPConn)
	if !ok {
		t.Fatalf("the accepted connection is %T, want *net.TCPConn", server)
	}
	if err := tcp.SetLinger(0); err != nil { // 閉じると、FIN ではなく RST を送る
		t.Fatalf("SetLinger: %v", err)
	}
	if err := server.Close(); err != nil {
		t.Fatalf("server Close: %v", err)
	}
	start := time.Now()
	ks.finish(8 * time.Second)
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Errorf("finish took %v although the connection was reset", elapsed)
	}
	if got := ks.descriptors(); len(got) != 0 {
		t.Errorf("descriptors after finish = %v, want none", got)
	}
}

// 強制の終わり（shutdown のあと）は、待たずに解放する。
func TestKillSwitchFinishDoesNotWaitAfterAShutdown(t *testing.T) {
	listener := listenLoopback(t)
	ks := newKillSwitch()
	client, err := dialWithKillSwitch(ks, listener.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	acceptOne(t, listener) // 相手は、閉じない
	ks.shutdown()
	if err := client.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	start := time.Now()
	ks.finish(10 * time.Second)
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Errorf("finish took %v after a shutdown", elapsed)
	}
	if got := ks.descriptors(); len(got) != 0 {
		t.Errorf("descriptors after finish = %v, want none", got)
	}
}

// 待っている finish は、ロックを持たない。shutdown（中断）は、直ちに通り、待ちを終わらせる。
func TestKillSwitchShutdownIsNotBlockedByAFinishThatIsWaiting(t *testing.T) {
	listener := listenLoopback(t)
	ks := newKillSwitch()
	client, err := dialWithKillSwitch(ks, listener.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	acceptOne(t, listener) // 相手は、閉じない
	if err := client.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	finished := make(chan struct{})
	go func() {
		ks.finish(30 * time.Second)
		close(finished)
	}()
	select {
	case <-finished:
		t.Fatalf("finish returned although the peer is still open")
	case <-time.After(150 * time.Millisecond): // 待ちに入っている
	}

	shutdownReturned := make(chan struct{})
	go func() {
		ks.shutdown()
		close(shutdownReturned)
	}()
	select {
	case <-shutdownReturned:
	case <-time.After(2 * time.Second):
		t.Fatalf("shutdown was blocked by the finish that is waiting")
	}
	select {
	case <-finished:
	case <-time.After(3 * time.Second):
		t.Fatalf("finish kept waiting after the shutdown")
	}
}

// 何度呼んでもよく、解放のあとは、新しいソケットを作らせない。
func TestKillSwitchFinishIsSafeToCallRepeatedly(t *testing.T) {
	listener := listenLoopback(t)
	ks := newKillSwitch()
	ks.finish(10 * time.Millisecond) // ソケットが無くても、よい
	ks.finish(10 * time.Millisecond)
	ks.release()
	ks.shutdown()
	conn, err := dialWithKillSwitch(ks, listener.Addr().String())
	if err == nil {
		_ = conn.Close()
		t.Fatalf("a dial after finish succeeded")
	}
	if !errors.Is(err, errKillSwitchReleased) {
		t.Errorf("error = %v, want errKillSwitchReleased", err)
	}
}
