package session

import (
	"context"
	"errors"
	"fmt"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/backend"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/rtmps"
)

// 境界の実装が、インターフェースを満たすことの確認（コンパイル時）。
var (
	_ Backend          = (*backend.Client)(nil)
	_ EventSink        = (*backend.EventQueue)(nil)
	_ Publisher        = (*rtmps.Publisher)(nil)
	_ PublisherFactory = (*RTMPSFactory)(nil)
)

// RTMPSFactory は、PublisherFactory の本番の実装（internal/rtmps）。取り込み先を、許可リスト（環境ごと。本番は YouTube の取り込み口に
// 限る）で検証し、RTMPS で接続して publish する。許可リストは、呼び出し側が、環境から決めて渡す（rtmps.PolicyForGinMode）。
type RTMPSFactory struct {
	policy rtmps.Policy
	config rtmps.Config
}

// NewRTMPSFactory は、許可リストと接続の設定から、RTMPSFactory を作る。config.Logger は、接続ごとの記録（配信レコードの識別子つき）で上書きする。
func NewRTMPSFactory(policy rtmps.Policy, config rtmps.Config) *RTMPSFactory {
	return &RTMPSFactory{policy: policy, config: config}
}

// Open は、取り込み先を検証してから、接続して publish する。取り込み先・配信キーが検証に通らなければ、接続を試みずに、
// ErrDestinationRejected を包んだエラー（再試行しても変わらない）。エラーは、取り込み先・配信キーの内容を含まない（rtmps の保証）。
func (f *RTMPSFactory) Open(ctx context.Context, request OpenRequest) (Publisher, error) {
	destination, err := rtmps.Validate(string(request.URL), f.policy)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrDestinationRejected, err)
	}
	if err := request.StreamKey.Validate(); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrDestinationRejected, err)
	}
	config := f.config
	if request.Logger != nil {
		config.Logger = request.Logger
	}
	publisher, err := rtmps.Dial(ctx, destination, request.StreamKey, config)
	if err != nil {
		if errors.Is(err, rtmps.ErrInvalidDestination) || errors.Is(err, rtmps.ErrInvalidStreamKey) || errors.Is(err, rtmps.ErrInvalidConfig) {
			return nil, fmt.Errorf("%w: %w", ErrDestinationRejected, err)
		}
		return nil, err
	}
	return publisher, nil
}
