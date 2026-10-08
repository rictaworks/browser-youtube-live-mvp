package session

import (
	"fmt"
	"math/rand/v2"
	"testing"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
)

// Decode → TimeGuard → Rebaser を通す結合の試験（#18 のレビューの申し送り）。
// 復帰（ブラウザの再接続）を何度もまたぎ、ブラウザのメディアクロックが、続く・0 に戻る・前方へ大きく飛ぶ場合でも、
// 送出する時刻が戻らず、欠落が詰まり、フレームが時刻の逆行として誤って破棄されないこと。

type segment struct {
	name    string
	startUs uint64 // この接続の最初のフレームの時刻
	frames  int    // 映像のフレーム数（音声は、同じ長さぶん）
}

func TestOutputTimestampsNeverGoBackwardAcrossResumesAndClockRestarts(t *testing.T) {
	h := newHarness(t)
	s := h.bringUp("t1", idA, 1)
	conn := s.conn
	segments := []segment{
		{"最初の接続", 0, 60},
		{"クロックが続く（同じページの再接続）", 2_100_000, 45},
		{"クロックが 0 に戻る（ページの再読み込み）", 0, 60},
		{"前方へ大きく飛ぶ", 9_000_000_000, 30},
		{"もう一度 0 に戻る", 0, 30},
		{"短い接続", 123, 3},
	}

	var sentFrames int
	var previousFirstMs, previousMaxMs int64 = -1, -1
	for index, seg := range segments {
		if index > 0 {
			conn.conn.Disconnected()
			h.settle()
			conn = h.resumeConnect(fmt.Sprintf("t-%d", index+1), idA, index+1, contract.BroadcastStateInterrupted)
			conn.start("720p")
			h.settle()
			want := []string{"accepted", "keyframe_request"}
			if got := conn.link.sequence(t); fmt.Sprint(got) != fmt.Sprint(want) {
				t.Fatalf("segment %q: link sequence = %v, want %v", seg.name, got, want)
			}
		}
		beforeTags := len(mediaTags(s.pub.tags()))
		for i := 0; i < seg.frames; i++ {
			videoUs := seg.startUs + uint64(i)*33333
			audioUs := seg.startUs + uint64(i)*23220
			conn.video(videoUs, i%30 == 0, videoPayload(byte(i), 40))
			conn.audio(audioUs, audioPayload(byte(i), 20))
			sentFrames += 2
		}
		h.settle()

		tags := mediaTags(s.pub.tags())
		added := tags[beforeTags:]
		if len(added) != 2*seg.frames {
			t.Fatalf("segment %q: %d tags were written for %d frames (frames were discarded)", seg.name, len(added), 2*seg.frames)
		}
		if s.sess.State() != StateStreaming {
			t.Fatalf("segment %q: state = %v, want streaming", seg.name, s.sess.State())
		}
		// 欠落は詰まる：この接続の最初の出力は、直前の最大の出力から、1 フレーム分（33 ミリ秒）より離れない
		firstMs := int64(added[0].ts)
		if previousMaxMs >= 0 && (firstMs < previousMaxMs || firstMs-previousMaxMs > 34) {
			t.Fatalf("segment %q: first output %d ms after a maximum of %d ms; the gap must be closed to at most one frame", seg.name, firstMs, previousMaxMs)
		}
		for _, tag := range added {
			if int64(tag.ts) > previousMaxMs {
				previousMaxMs = int64(tag.ts)
			}
		}
		if previousFirstMs < 0 {
			previousFirstMs = firstMs
		}
	}

	// 全体を通して、種類ごとに、出力の時刻が減らない
	last := map[string]uint32{}
	for i, tag := range mediaTags(s.pub.tags()) {
		if tag.ts < last[tag.kind] {
			t.Fatalf("tag %d (%s): timestamp %d went back from %d", i, tag.kind, tag.ts, last[tag.kind])
		}
		last[tag.kind] = tag.ts
	}
	if previousFirstMs != 0 {
		t.Fatalf("the first output was at %d ms, want 0 (the origin of the RTMPS connection)", previousFirstMs)
	}
}

// 映像と音声に、同一の補正量を適用する（同期を保つ）。同じ時刻の映像と音声は、復帰をまたいでも、同じ出力時刻になる。
func TestAudioAndVideoOfTheSameInstantStayInSyncAcrossAResume(t *testing.T) {
	random := rand.New(rand.NewPCG(1, 2))
	for round := 0; round < 20; round++ {
		t.Run(fmt.Sprintf("round-%d", round), func(t *testing.T) {
			h := newHarness(t)
			s := h.bringUp("t1", idA, 1)
			firstMedia(s.conn)
			h.settle()
			s.conn.conn.Disconnected()
			h.settle()
			resumed := h.resumeConnect("t2", idA, 2, contract.BroadcastStateInterrupted)
			resumed.start("720p")
			h.settle()

			start := uint64(random.IntN(5_000_000_000))
			resumed.video(start, true, videoPayload(1, 30))
			resumed.audio(start, audioPayload(1, 20))
			offset := uint64(1 + random.IntN(1_000_000))
			resumed.video(start+offset, false, videoPayload(2, 30))
			resumed.audio(start+offset, audioPayload(2, 20))
			h.settle()

			tags := mediaTags(s.pub.tags())
			tags = tags[len(tags)-4:]
			if tags[0].ts != tags[1].ts {
				t.Fatalf("the keyframe (%d ms) and the audio (%d ms) of the same instant differ", tags[0].ts, tags[1].ts)
			}
			if tags[2].ts != tags[3].ts {
				t.Fatalf("video (%d ms) and audio (%d ms) of the same instant %d µs later differ (the correction must be the same)", tags[2].ts, tags[3].ts, offset)
			}
		})
	}
}
