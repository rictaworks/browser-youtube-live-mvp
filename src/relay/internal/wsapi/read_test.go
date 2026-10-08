package wsapi

import (
	"bytes"
	"errors"
	"io"
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
