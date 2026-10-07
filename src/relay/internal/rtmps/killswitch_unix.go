//go:build unix

package rtmps

import (
	"errors"
	"fmt"
	"sync"
	"syscall"
	"time"
)

const (
	// lingerPollInterval は、おだやかに閉じるとき、相手が閉じるのを待つ間の、受信の確認の間隔。
	lingerPollInterval = 2 * time.Millisecond
	// lingerReadBytes は、おだやかに閉じるとき、捨てながら読む、1 回の大きさ（バイト）。
	lingerReadBytes = 4096
	// lingerMaxReads は、1 回の確認で、受信を捨てる回数の上限（相手が送り続けても、確認が終わらないようにする）。
	lingerMaxReads = 64
)

// killSwitch は、go-rtmp の接続を、外から直ちに壊すための仕掛け。
//
// go-rtmp は、接続（net.Conn）を外へ出さない（Dial 系は ClientConn だけを返し、context も取らない）。そのため、
//   - RTMP のハンドシェイクに応じない受け口へ、Dial が止まったままになる（タイムアウトが無い）
//   - 回線が詰まって書き込みが止まっているときに、Close が数秒かかる（書き込み中のものを待ち、TLS の close_notify を書く）
//
// という状況で、接続を閉じる手段が無い。そこで、接続用のソケットの記述子を、net.Dialer の Control で、dup して持ち、
// 必要なときに shutdown（SHUT_RDWR）する。dup した記述子は、この型だけが持つので、閉じた記述子の番号が別の用途へ再利用されて、
// 無関係のソケットを shutdown する事故は起きない（release のあとは、触らない）。shutdown は、読み書きで止まっているゴルーチンを、
// 直ちに失敗させる（Dial の失敗・Stream.Write のエラー）。
//
// 1 回の Dial につき 1 つ。ゴルーチンから並行に呼んでよい。
type killSwitch struct {
	mu       sync.Mutex
	fds      []int
	broken   bool // shutdown 済み。以後、新しいソケットを作らせない
	released bool // release 済み
}

// errKillSwitchReleased は、shutdown・release 済みの killSwitch へ、接続用のソケットが作られようとした（見放した試行が、
// 次のアドレスへ接続しようとした）。接続を始めさせずに、エラーにする。
const errKillSwitchReleased Error = "rtmps: dial was abandoned"

func newKillSwitch() *killSwitch {
	return &killSwitch{}
}

// control は、net.Dialer.Control に渡す関数。作られたソケットの記述子を dup して持つ（接続の前に呼ばれる）。
// dup できなければ、接続を始めずに、エラーを返す（見張りの無い接続を、黙って続けない）。
func (k *killSwitch) control(_, _ string, raw syscall.RawConn) error {
	if k.refuses() {
		return errKillSwitchReleased
	}
	var dupErr error
	controlErr := raw.Control(func(fd uintptr) {
		duplicate, err := syscall.Dup(int(fd))
		if err != nil {
			dupErr = fmt.Errorf("rtmps: duplicate the socket descriptor: %w", err)
			return
		}
		syscall.CloseOnExec(duplicate)
		k.mu.Lock()
		defer k.mu.Unlock()
		if k.broken || k.released {
			_ = syscall.Close(duplicate)
			dupErr = errKillSwitchReleased
			return
		}
		k.fds = append(k.fds, duplicate)
	})
	if controlErr != nil {
		return controlErr
	}
	return dupErr
}

// refuses は、新しいソケットを作らせないか（shutdown・release のあと）。
func (k *killSwitch) refuses() bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.broken || k.released
}

// shutdown は、持っているソケットを、読み書きとも shutdown する。以後、新しいソケットは、作らせない（見放した試行が、
// 次のアドレスへ接続して、止まったまま残ることを防ぐ）。接続していないソケット（失敗した試行・すでに閉じた接続）は、
// ENOTCONN になるが、害は無く、直すこともできないので、結果は見ない。release のあとは、何もしない。
func (k *killSwitch) shutdown() {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.broken = true
	for _, fd := range k.fds {
		_ = syscall.Shutdown(fd, syscall.SHUT_RDWR)
	}
}

// closeUnconnected は、接続できなかった試行のソケット（複数のアドレスを順に試したときの、失敗した分）の記述子を閉じる。
// 接続に成功したあとに呼ぶ（成功した 1 つだけが、残る）。
func (k *killSwitch) closeUnconnected() {
	k.mu.Lock()
	defer k.mu.Unlock()
	kept := k.fds[:0]
	for _, fd := range k.fds {
		if _, err := syscall.Getpeername(fd); err != nil {
			_ = syscall.Close(fd)
			continue
		}
		kept = append(kept, fd)
	}
	k.fds = kept
}

// finish は、接続を、おだやかに終えて、記述子を解放する（送り切ったあとの Close）。
//
// go-rtmp が接続を閉じても、この型の複製が、ソケットの最後の参照なので、ソケットは、まだ閉じていない。そこで、
//  1. shutdown の SHUT_WR で、送信キューに残っているものを送り切ったあとに、FIN を送る
//  2. 相手が閉じる（FIN。読み取りが 0 バイト）まで、受信を捨てながら待つ（上限は linger）
//  3. 記述子を閉じる
//
// の順にする。送り残しがあるまま、または、読んでいない受信が残ったまま、ソケットを閉じると、OS は、FIN ではなく RST を送り、
// 送信キューに残っていたものを捨てる（受け口は、配信の最後の部分を受け取れない。go-rtmp を使う試験で、実際に起きた）。
// 相手が閉じたことは、FIN より前のすべてを、相手が受け取ったことの証明にもなる。shutdown 済み（強制の終わり）なら、待たずに、
// 解放する。待つ間は、ロックを持たない（shutdown が、直ちに通り、待ちを終わらせる）。記述子を閉じるのは、この関数の最後の release
// だけなので、待つ間に、番号が別の用途へ再利用されることはない。
func (k *killSwitch) finish(linger time.Duration) {
	deadline := time.Now().Add(linger)
	if k.closeWrite() {
		for k.peerStillOpen() && time.Now().Before(deadline) {
			time.Sleep(lingerPollInterval)
		}
	}
	k.release()
}

// closeWrite は、持っているソケットの送信側を閉じる（送信キューが空になってから、FIN が出る）。強制の終わり・解放済みなら、
// 何もせず false を返す。接続していないソケットは ENOTCONN になるが、害は無く、直すこともできないので、結果は見ない。
func (k *killSwitch) closeWrite() bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.broken || k.released {
		return false
	}
	for _, fd := range k.fds {
		_ = syscall.Shutdown(fd, syscall.SHUT_WR)
	}
	return true
}

// peerStillOpen は、受信を捨てながら、相手がまだ閉じていないソケットがあるかを返す。強制の終わり・解放済みなら false
// （待たない）。読み取りが 0 バイト（FIN）か、失敗（リセット・未接続）になったソケットは、もう待つものが無い。
func (k *killSwitch) peerStillOpen() bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.broken || k.released {
		return false
	}
	buffer := make([]byte, lingerReadBytes)
	open := false
	for _, fd := range k.fds {
		if socketStillOpen(fd, buffer) {
			open = true
		}
	}
	return open
}

// socketStillOpen は、ソケットの受信を捨て（ブロックしない）、相手がまだ閉じていないかを返す。読み取りが 0 バイト（相手が閉じた）
// も、リセットなどの失敗も、false。受信が無い（EAGAIN）なら true。1 回の呼び出しで捨てる量には、上限がある。
func socketStillOpen(fd int, buffer []byte) bool {
	for range lingerMaxReads {
		n, _, err := syscall.Recvfrom(fd, buffer, syscall.MSG_DONTWAIT)
		switch {
		case err == nil && n == 0:
			return false
		case err == nil, errors.Is(err, syscall.EINTR):
			continue
		case errors.Is(err, syscall.EAGAIN), errors.Is(err, syscall.EWOULDBLOCK):
			return true
		default:
			return false
		}
	}
	return true
}

// release は、持っている記述子を、すべて閉じる（接続そのものは、go-rtmp が閉じる。この記述子は、その接続の最後の参照になりうるので、
// 閉じるまで、接続の切断は、相手へ届かない）。何度呼んでもよい。以後の control は、エラーを返す。
func (k *killSwitch) release() {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.releaseLocked()
}

func (k *killSwitch) releaseLocked() {
	if k.released {
		return
	}
	k.released = true
	for _, fd := range k.fds {
		_ = syscall.Close(fd)
	}
	k.fds = nil
}
