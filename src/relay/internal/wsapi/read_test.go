package wsapi

import (
	"bytes"
	"errors"
	"io"
	"slices"
	"testing"
)

// chunkReader は、1 回の Read で最大 chunk バイトだけ返す Reader。読んだ量を数える。
type chunkReader struct {
	data     []byte
	chunk    int
	consumed int
	// eofWithData が真なら、最後のデータを返す Read が、同時に io.EOF を返す
	eofWithData bool
	// failAfter が 0 より大きければ、その量を読んだあとで、failWith を返す
	failAfter int
	failWith  error
}

func (r *chunkReader) Read(p []byte) (int, error) {
	if r.failAfter > 0 && r.consumed >= r.failAfter {
		return 0, r.failWith
	}
	if r.consumed >= len(r.data) {
		return 0, io.EOF
	}
	n := min(len(p), r.chunk, len(r.data)-r.consumed)
	if r.failAfter > 0 {
		n = min(n, r.failAfter-r.consumed)
	}
	copy(p, r.data[r.consumed:r.consumed+n])
	r.consumed += n
	if r.eofWithData && r.consumed == len(r.data) {
		return n, io.EOF
	}
	return n, nil
}

func patterned(n int) []byte {
	data := make([]byte, n)
	for i := range data {
		data[i] = byte(i*7 + 3)
	}
	return data
}

func TestReadMessageReadsUpToTheLimit(t *testing.T) {
	const limit = 1024
	cases := []struct {
		name        string
		size        int
		chunk       int
		eofWithData bool
		wantOver    bool
	}{
		{"空", 0, 4096, false, false},
		{"1 バイト", 1, 4096, false, false},
		{"上限の 1 つ手前", limit - 1, 4096, false, false},
		{"上限ちょうど", limit, 4096, false, false},
		{"上限を 1 バイト超える", limit + 1, 4096, false, true},
		{"上限をはるかに超える", limit * 100, 4096, false, true},
		{"1 バイトずつ届く（上限ちょうど）", limit, 1, false, false},
		{"1 バイトずつ届く（超過）", limit + 1, 1, false, true},
		{"最後のデータと同時に EOF（上限ちょうど）", limit, 100, true, false},
		{"最後のデータと同時に EOF（小さい）", 10, 4096, true, false},
		{"大きなチャンク（上限ちょうど）", limit, 1 << 20, false, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			data := patterned(c.size)
			reader := &chunkReader{data: data, chunk: c.chunk, eofWithData: c.eofWithData}
			got, over, err := readMessage(reader, limit)
			if err != nil {
				t.Fatalf("readMessage() error = %v; want nil", err)
			}
			if over != c.wantOver {
				t.Fatalf("oversize = %t; want %t", over, c.wantOver)
			}
			if c.wantOver {
				if got != nil {
					t.Errorf("data = %d bytes; want none for an oversize message", len(got))
				}
				// 超過が分かった時点で読むのをやめる（上限 + 1 バイトより先を読まない）
				if reader.consumed > limit+1 {
					t.Errorf("consumed %d bytes; want at most %d (limit + 1)", reader.consumed, limit+1)
				}
				return
			}
			if !bytes.Equal(got, data) {
				t.Errorf("data differs (got %d bytes, want %d)", len(got), len(data))
			}
		})
	}
}

func TestReadMessageReportsReadErrors(t *testing.T) {
	custom := errors.New("connection reset")
	cases := []struct {
		name string
		r    io.Reader
		want error
	}{
		{"途中で予期しない EOF", &chunkReader{data: patterned(500), chunk: 100, failAfter: 300, failWith: io.ErrUnexpectedEOF}, io.ErrUnexpectedEOF},
		{"途中で別の失敗", &chunkReader{data: patterned(500), chunk: 100, failAfter: 200, failWith: custom}, custom},
		{"最初から失敗", &chunkReader{data: patterned(10), chunk: 100, failAfter: 1, failWith: custom, consumed: 1}, custom},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, over, err := readMessage(c.r, 1024)
			if !errors.Is(err, c.want) {
				t.Fatalf("readMessage() error = %v; want %v", err, c.want)
			}
			if got != nil || over {
				t.Errorf("readMessage() = (%d bytes, %t); want no data and no oversize with an error", len(got), over)
			}
		})
	}
}

// 確保する量が、宣言ではなく、実際に届いた量に比例する（小さなメッセージのために、上限ぶんを確保しない）
func TestReadMessageDoesNotAllocateTheLimitUpFront(t *testing.T) {
	data := patterned(100)
	allocations := testing.AllocsPerRun(20, func() {
		if _, _, err := readMessage(bytes.NewReader(data), 2_097_152); err != nil {
			t.Fatalf("readMessage() error = %v", err)
		}
	})
	if allocations > 4 {
		t.Errorf("%v allocations for a 100-byte message; want a handful", allocations)
	}
	var before, after runtimeMemory
	before.read()
	for i := 0; i < 200; i++ {
		if _, _, err := readMessage(bytes.NewReader(data), 2_097_152); err != nil {
			t.Fatalf("readMessage() error = %v", err)
		}
	}
	after.read()
	if grown := after.totalAlloc - before.totalAlloc; grown > 200*64*1024 {
		t.Errorf("allocated %d bytes for 200 small messages; want far less than the 2 MiB limit each", grown)
	}
}

// 緩衝を増やす段（倍々）をまたぐ大きさでも、内容が変わらず、上限の判定が変わらない。増やす経路は、上限が初期の大きさ（4096）を
// 超えるときだけ通る。上限は、2 の冪（8192）・2 の冪でない値（70000）・契約の値（2,097,152）で調べる
func TestReadMessageKeepsTheDataAcrossTheGrowthSteps(t *testing.T) {
	limits := []int{8192, 70000, 2_097_152}
	chunks := []int{1, 1000, 4096, 1 << 20}
	for _, limit := range limits {
		sizes := []int{0, 1, initialReadBytes - 1, initialReadBytes, initialReadBytes + 1, limit/2 - 1, limit / 2, limit/2 + 1, limit - 1, limit, limit + 1, limit + 4096}
		for _, size := range sizes {
			for _, chunk := range chunks {
				if chunk == 1 && size > 80000 {
					continue // 1 バイトずつは、小さい大きさだけ（時間がかかる）
				}
				data := patterned(size)
				reader := &chunkReader{data: data, chunk: chunk}
				got, over, err := readMessage(reader, limit)
				if err != nil {
					t.Fatalf("limit %d size %d chunk %d: error = %v", limit, size, chunk, err)
				}
				if wantOver := size > limit; over != wantOver {
					t.Fatalf("limit %d size %d chunk %d: oversize = %t; want %t", limit, size, chunk, over, wantOver)
				}
				if over {
					if got != nil || reader.consumed > limit+1 {
						t.Fatalf("limit %d size %d chunk %d: data %d bytes, consumed %d; want no data and at most %d consumed", limit, size, chunk, len(got), reader.consumed, limit+1)
					}
					continue
				}
				if !bytes.Equal(got, data) {
					t.Fatalf("limit %d size %d chunk %d: data differs (got %d bytes)", limit, size, chunk, len(got))
				}
			}
		}
	}
}

// capacityRecorder は、Read に渡された領域の末尾の位置（これまでに読んだ量 + 渡された領域の大きさ = そのときの緩衝の容量）を記録する。
type capacityRecorder struct {
	chunkReader
	capacities []int
}

func (r *capacityRecorder) Read(p []byte) (int, error) {
	capacity := r.consumed + len(p)
	if n := len(r.capacities); n == 0 || r.capacities[n-1] != capacity {
		r.capacities = append(r.capacities, capacity)
	}
	return r.chunkReader.Read(p)
}

// 緩衝は倍々に増やすが、最後の段は、上限 + 1 バイトへ一気に増やす。倍にすると上限を超えるときに、さらに倍々で進めると、最後の段で
// 「古い緩衝（上限の半分ぐらい）と新しい緩衝（上限ぐらい）」の両方が同時に生きる量が、上限の 2 倍になる（4 MiB）。
// 一気に増やせば、1 本の読み取り中の最大が、上限の 1.5 倍（3 MiB）で済む。
func TestReadMessageGrowsStraightToTheLimitInTheLastStep(t *testing.T) {
	const limit = 8192
	reader := &capacityRecorder{chunkReader: chunkReader{data: patterned(limit + 100), chunk: 1000}}
	if _, over, err := readMessage(reader, limit); err != nil || !over {
		t.Fatalf("readMessage() = (oversize %t, error %v); want oversize", over, err)
	}
	if want := []int{initialReadBytes, limit + 1}; !slices.Equal(reader.capacities, want) {
		t.Fatalf("buffer capacities = %v; want %v (4096, then straight to limit + 1)", reader.capacities, want)
	}

	// 契約の上限（2,097,152）：1 MiB（= 上限の半分）の次が、2 MiB + 1 バイト。その間に 2 MiB の段を作らない
	const contractLimit = 2_097_152
	big := &capacityRecorder{chunkReader: chunkReader{data: patterned(contractLimit), chunk: 64 << 10}}
	got, over, err := readMessage(big, contractLimit)
	if err != nil || over || len(got) != contractLimit {
		t.Fatalf("readMessage(2 MiB) = (%d bytes, oversize %t, error %v); want the whole message", len(got), over, err)
	}
	var want []int
	for capacity := initialReadBytes; capacity < contractLimit/2+1; capacity *= 2 {
		want = append(want, capacity)
	}
	want = append(want, contractLimit+1)
	if !slices.Equal(big.capacities, want) {
		t.Fatalf("buffer capacities for a 2 MiB message = %v; want %v", big.capacities, want)
	}
	if last, before := big.capacities[len(big.capacities)-1], big.capacities[len(big.capacities)-2]; before > contractLimit/2 || last != contractLimit+1 {
		t.Errorf("the last step went from %d to %d; want from at most half of the limit straight to limit + 1", before, last)
	}
}
