package session

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// セッション台帳（Registry）の試験。Register・Find・Count・CloseOthers・Remove。
// 同一アカウントの新しい取り込みセッションを照合した時点で、当該アカウントの他の取り込みセッションをすべて閉じる
// （requirements.md 10.5。古い映像が新しい配信へ流れないように、閉じるまで完了を待つ）。

func TestRegisterFindCountRemove(t *testing.T) {
	h := newHarness(t)
	a, b := h.newSession(idA, accountX), h.newSession(idB, accountY)

	if h.reg.Count() != 0 {
		t.Fatalf("Count = %d, want 0", h.reg.Count())
	}
	if err := h.reg.Register(a); err != nil {
		t.Fatalf("Register: %v", err)
	}
	if err := h.reg.Register(b); err != nil {
		t.Fatalf("Register: %v", err)
	}
	if h.reg.Count() != 2 {
		t.Fatalf("Count = %d, want 2", h.reg.Count())
	}
	if got, ok := h.reg.Find(idA); !ok || got != a {
		t.Fatalf("Find(%s) = %v, %v", idA, got, ok)
	}
	if _, ok := h.reg.Find(idC); ok {
		t.Fatal("Find of an unknown broadcast succeeded")
	}
	h.reg.Remove(a)
	if _, ok := h.reg.Find(idA); ok || h.reg.Count() != 1 {
		t.Fatalf("after Remove: Find ok=%v Count=%d", ok, h.reg.Count())
	}
	h.reg.Remove(a) // 二度目は、何も起きない
	if h.reg.Count() != 1 {
		t.Fatalf("Count = %d after a second Remove", h.reg.Count())
	}
}

func TestRegisterRejectsADuplicateBroadcast(t *testing.T) {
	h := newHarness(t)
	first, second := h.newSession(idA, accountX), h.newSession(idA, accountX)
	if err := h.reg.Register(first); err != nil {
		t.Fatalf("Register: %v", err)
	}
	if err := h.reg.Register(second); !errors.Is(err, ErrAlreadyRegistered) {
		t.Fatalf("second Register error = %v, want ErrAlreadyRegistered", err)
	}
	if got, _ := h.reg.Find(idA); got != first {
		t.Fatal("the registered session was replaced")
	}
}

func TestRemoveDoesNotRemoveADifferentSessionOfTheSameBroadcast(t *testing.T) {
	h := newHarness(t)
	registered, other := h.newSession(idA, accountX), h.newSession(idA, accountX)
	if err := h.reg.Register(registered); err != nil {
		t.Fatalf("Register: %v", err)
	}
	h.reg.Remove(other)
	if got, ok := h.reg.Find(idA); !ok || got != registered {
		t.Fatal("Remove of another session removed the registered one")
	}
}

func TestRegisterRefusesAClosedSession(t *testing.T) {
	h := newHarness(t)
	s := h.newSession(idA, accountX)
	s.Close(CloseReasonShutdown)
	h.waitDone(s)
	if err := h.reg.Register(s); !errors.Is(err, ErrSessionClosed) {
		t.Fatalf("Register error = %v, want ErrSessionClosed", err)
	}
}

func TestCloseOthersClosesOnlyTheOtherSessionsOfTheAccount(t *testing.T) {
	h := newHarness(t)
	a1, a2, keep, other := h.newSession(idA, accountX), h.newSession(idB, accountX), h.newSession(idC, accountX), h.newSession("44444444-4444-4444-8444-444444444444", accountY)
	for _, s := range []*IngestSession{a1, a2, keep, other} {
		if err := h.reg.Register(s); err != nil {
			t.Fatalf("Register: %v", err)
		}
	}

	closed := h.reg.CloseOthers(accountX, idC)
	if closed != 2 {
		t.Fatalf("CloseOthers closed %d sessions, want 2", closed)
	}
	// 戻ったときには、閉じるのが完了している（古い映像が流れないように、完了を待つ）
	for _, s := range []*IngestSession{a1, a2} {
		select {
		case <-s.Done():
		default:
			t.Fatalf("CloseOthers returned before session %s was done", s.BroadcastID())
		}
	}
	if h.reg.Count() != 2 {
		t.Fatalf("Count = %d, want 2 (the kept session and the other account's)", h.reg.Count())
	}
	for _, s := range []*IngestSession{keep, other} {
		if s.State() == StateClosed {
			t.Fatalf("session %s was closed", s.BroadcastID())
		}
	}
	if got := h.reg.CloseOthers(accountX, idC); got != 0 {
		t.Fatalf("a second CloseOthers closed %d sessions", got)
	}
}

func TestCloseOthersWithoutOtherSessionsDoesNothing(t *testing.T) {
	h := newHarness(t)
	if got := h.reg.CloseOthers(accountX, idA); got != 0 {
		t.Fatalf("CloseOthers = %d", got)
	}
}

// 同一アカウントの別の配信の照合で、古い取り込みセッションは、バッファを破棄して直ちに切られる（Abort）。
// 新しい配信の accepted は、古い取り込みセッションが完全に終わってから返る。
func TestAHelloOfANewBroadcastClosesTheAccountsOldSessionBeforeAccepting(t *testing.T) {
	h := newHarness(t)
	old := h.bringUp("t-old", idA, 1)
	release := old.pub.holdAbort() // 古い送出の切断が終わらない間は、新しい配信を受理しない
	h.be.addTicket("t-new", verifyResult(idB, 1, contract.BroadcastStateReserved))

	conn := h.connect()
	conn.hello("t-new")
	// 古いセッションの閉じる手順が進む（完了は、まだ）
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, aborts := old.pub.counts(); aborts > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the old session was not aborted")
		}
		time.Sleep(time.Millisecond)
	}
	h.barrierAll()
	for _, line := range conn.link.sequence(t) {
		if line == "accepted" {
			t.Fatal("the new broadcast was accepted while the old session was still closing")
		}
	}

	close(release)
	h.settle()
	expectSequence(t, conn.link, "accepted")
	h.waitDone(old.sess)

	closes, aborts := old.pub.counts()
	if aborts != 1 || closes != 0 {
		t.Fatalf("old publisher: Close %d Abort %d; a superseded session must Abort (Close can keep sending old video for seconds)", closes, aborts)
	}
	// 古いブラウザへは、配信が終わった旨を伝えて切る
	expectSequence(t, old.conn.link, "accepted", "status:awaiting_media", "status:confirming", "fatal:broadcast_ended", "close:1000")
	if got := h.ev.kinds(); got[len(got)-1] != "session_ended" {
		t.Fatalf("events = %v, want session_ended last", got)
	}
	if _, ok := h.reg.Find(idA); ok {
		t.Fatal("the old session is still registered")
	}
	if h.reg.Count() != 1 {
		t.Fatalf("Count = %d, want 1", h.reg.Count())
	}
}

func TestAHelloOfAnotherAccountLeavesTheSessionAlone(t *testing.T) {
	h := newHarness(t)
	first := h.bringUp("t1", idA, 1)
	h.be.addTicket("t2", backendVerifyFor(idB, 1, accountY))
	conn := h.connect()
	conn.hello("t2")
	h.settle()

	expectSequence(t, conn.link, "accepted")
	if first.sess.State() != StateStreaming {
		t.Fatalf("the other account's session is %v", first.sess.State())
	}
	if closes, aborts := first.pub.counts(); closes+aborts != 0 {
		t.Fatalf("the other account's publisher was stopped (Close %d Abort %d)", closes, aborts)
	}
	if h.reg.Count() != 2 {
		t.Fatalf("Count = %d, want 2", h.reg.Count())
	}
}

func TestSessionsOfDifferentAccountsAreIndependent(t *testing.T) {
	h := newHarness(t)
	a, b := h.newSession(idA, accountX), h.newSession(idB, accountY)
	_ = h.reg.Register(a)
	_ = h.reg.Register(b)
	if h.reg.CloseOthers(accountX, idA) != 0 {
		t.Fatal("a session of another account was closed")
	}
	if b.State() == StateClosed {
		t.Fatal("the other account's session was closed")
	}
}

func TestRegistryIsSafeForConcurrentUse(t *testing.T) {
	h := newHarness(t)
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 10; i++ {
				id := fmt.Sprintf("session-%d-%d", g, i)
				s := h.newSession(id, accountX)
				_ = h.reg.Register(s)
				h.reg.Find(id)
				h.reg.Count()
				h.reg.Remove(s)
			}
		}()
	}
	wg.Wait()
	if h.reg.Count() != 0 {
		t.Fatalf("Count = %d, want 0", h.reg.Count())
	}
}

func TestShutdownClosesAllSessionsGracefully(t *testing.T) {
	h := newHarness(t)
	one := h.bringUp("t1", idA, 1)
	h.be.addTicket("t2", backendVerifyFor(idB, 1, accountY))
	two := h.connect()
	two.hello("t2")
	h.settle()
	two.start("720p")
	h.settle()
	h.clock.Advance(h.opts.PublishConfirmWindow)
	h.settle()
	secondPub := h.fac.last(t)

	ctx, cancel := contextWithTimeout(t)
	defer cancel()
	if err := h.reg.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
	for name, pub := range map[string]*fakePublisher{"first": one.pub, "second": secondPub} {
		closes, aborts := pub.counts()
		if closes != 1 || aborts != 0 {
			t.Fatalf("%s publisher: Close %d Abort %d; a graceful shutdown sends the pending media before disconnecting", name, closes, aborts)
		}
	}
	if h.reg.Count() != 0 {
		t.Fatalf("Count = %d after Shutdown", h.reg.Count())
	}
	// ブラウザは、internal_error で復帰（再接続）を試みる
	if got := one.conn.link.fatals(t); len(got) != 1 || got[0] != "internal_error" {
		t.Fatalf("fatal codes = %v, want [internal_error]", got)
	}
	events := h.ev.kinds()
	ended := 0
	for _, kind := range events {
		if kind == "session_ended" {
			ended++
		}
	}
	if ended != 2 {
		t.Fatalf("events = %v, want a session_ended for each session", events)
	}
}

func TestShutdownEscalatesToAbortAtTheDeadline(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	release := make(chan struct{})
	s.pub.mu.Lock()
	s.pub.closeGate = release // 送り切れない（Close が戻らない）
	s.pub.mu.Unlock()
	defer close(release)

	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() { result <- h.reg.Shutdown(ctx) }()
	// Close が始まるのを待ってから、期限を過ぎたことにする
	deadline := time.Now().Add(5 * time.Second)
	for {
		if closes, _ := s.pub.counts(); closes > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the graceful close did not start")
		}
		time.Sleep(time.Millisecond)
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Shutdown error = %v, want context.Canceled", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Shutdown did not return after the deadline")
	}
	if _, aborts := s.pub.counts(); aborts != 1 {
		t.Fatalf("Abort calls = %d, want 1 (escalation at the deadline)", aborts)
	}
	h.waitDone(s.sess)
}

// ---- 受信量の超過で切った配信への再接続の拒否 ----

// floodMessages は、受信量の上限（720p の映像ビットレートの上限の 1.5 倍 = 9,000 kbps を 10 秒平均で）を超える量。
func floodMessages(tc *testConn) {
	for i := 0; i < 6; i++ {
		tc.probe(contract.WSFrameMaxMessageBytes - contract.WSFrameHeaderBytes)
	}
}

func TestABroadcastDisconnectedForExcessiveIngressIsRefusedUntilTheBanExpires(t *testing.T) {
	h := newHarness(t)
	h.be.addTicket("t1", verifyResult(idA, 1, contract.BroadcastStateReserved))
	conn := h.connect()
	conn.hello("t1")
	h.settle()
	session := h.mustSession(idA)
	floodMessages(conn)
	h.settle()
	h.waitDone(session)

	expectSequence(t, conn.link, "accepted", "fatal:bitrate_exceeded", "close:1000")
	if got := h.ev.kinds(); fmt.Sprint(got) != "[relay_disconnected session_ended]" {
		t.Fatalf("events = %v, want relay_disconnected then session_ended", got)
	}
	if h.reg.Count() != 0 {
		t.Fatalf("Count = %d", h.reg.Count())
	}

	// 以後、当該配信への再接続（照合）を受け付けない
	h.be.addTicket("t2", verifyResult(idA, 2, contract.BroadcastStateInterrupted))
	again := h.connect()
	again.hello("t2")
	h.settle()
	expectSequence(t, again.link, "fatal:bitrate_exceeded", "close:1000")
	if h.reg.Count() != 0 {
		t.Fatalf("a banned broadcast got a session (Count = %d)", h.reg.Count())
	}

	// 別の配信は、影響を受けない
	h.be.addTicket("t3", verifyResult(idB, 1, contract.BroadcastStateReserved))
	other := h.connect()
	other.hello("t3")
	h.settle()
	expectSequence(t, other.link, "accepted")

	// 期限が過ぎれば、記録は消える（アプリケーションが、とうに配信を終了している）
	h.clock.Advance(h.opts.BanTTL)
	h.be.addTicket("t4", verifyResult(idA, 3, contract.BroadcastStateInterrupted))
	later := h.connect()
	later.hello("t4")
	h.settle()
	expectSequence(t, later.link, "accepted")
}

func TestTheBanListIsBounded(t *testing.T) {
	h := newHarness(t, func(o *Options) { o.MaxBanned = 2 })
	ids := []string{idA, idB, idC}
	for i, id := range ids {
		ticket := fmt.Sprintf("flood-%d", i)
		h.be.addTicket(ticket, verifyResult(id, 1, contract.BroadcastStateReserved))
		conn := h.connect()
		conn.hello(ticket)
		h.settle()
		session := h.mustSession(id)
		floodMessages(conn)
		h.settle()
		h.waitDone(session)
		h.clock.Advance(time.Second) // 禁止の期限の順に、古いものから消えるように
	}
	// 3 件のうち、最も古い idA の記録は押し出され、新しい 2 件は残る
	for i, id := range ids {
		ticket := fmt.Sprintf("again-%d", i)
		h.be.addTicket(ticket, verifyResult(id, 2, contract.BroadcastStateInterrupted))
		conn := h.connect()
		conn.hello(ticket)
		h.settle()
		banned := len(conn.link.fatals(t)) == 1 && conn.link.fatals(t)[0] == "bitrate_exceeded"
		if want := i > 0; banned != want {
			t.Fatalf("broadcast %d: banned = %v, want %v (the oldest record is evicted when the list is full)", i, banned, want)
		}
	}
}

// ---- 世代 ----

// 同じ配信への 2 つの照合が並行しても、最新の世代の接続だけが残る。
func TestConcurrentHellosForTheSameBroadcastKeepOnlyTheNewestEpoch(t *testing.T) {
	for round := 0; round < 20; round++ {
		t.Run(fmt.Sprintf("round-%d", round), func(t *testing.T) {
			h := newHarness(t)
			h.be.verifyGate = make(chan struct{})
			h.be.addTicket("t2", verifyResult(idA, 2, contract.BroadcastStateReserved))
			h.be.addTicket("t3", verifyResult(idA, 3, contract.BroadcastStateReserved))
			first, second := h.connect(), h.connect()
			first.hello("t2")
			second.hello("t3")
			<-h.be.verifyEntered
			<-h.be.verifyEntered
			close(h.be.verifyGate)
			h.settle()

			session := h.mustSession(idA)
			if session.Epoch() != 3 {
				t.Fatalf("epoch = %d, want 3", session.Epoch())
			}
			if second.link.isClosed() {
				t.Fatalf("the newest connection was closed: %v", second.link.sequence(t))
			}
			expectSequence(t, second.link, "accepted")
			if !first.link.isClosed() {
				t.Fatalf("the older connection is still open: %v", first.link.sequence(t))
			}
			if got := first.link.fatals(t); len(got) != 1 || got[0] != "stale_epoch" {
				t.Fatalf("older connection fatal codes = %v, want [stale_epoch]", got)
			}
		})
	}
}
