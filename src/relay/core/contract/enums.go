package contract

// 契約の列挙（src/contracts/enums.json）。値の順は契約の一部。

// SourceKind は、列挙 source_kind（requirements.md 20.4（ソース種別）・4 章）。
type SourceKind string

const (
	SourceKindCamera      SourceKind = "camera"
	SourceKindScreen      SourceKind = "screen"
	SourceKindMicrophone  SourceKind = "microphone"
	SourceKindSharedAudio SourceKind = "shared_audio"
	SourceKindSlate       SourceKind = "slate"
)

// SourceKindValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func SourceKindValues() []SourceKind {
	return []SourceKind{
		SourceKindCamera,
		SourceKindScreen,
		SourceKindMicrophone,
		SourceKindSharedAudio,
		SourceKindSlate,
	}
}

// Valid は、v が列挙 source_kind の符号なら true を返す。
func (v SourceKind) Valid() bool {
	switch v {
	case SourceKindCamera, SourceKindScreen, SourceKindMicrophone, SourceKindSharedAudio, SourceKindSlate:
		return true
	}
	return false
}

// Layout は、列挙 layout（requirements.md 20.4（レイアウト）・11.3）。
type Layout string

const (
	LayoutScreenWithWipe Layout = "screen_with_wipe"
	LayoutScreenOnly     Layout = "screen_only"
	LayoutCameraOnly     Layout = "camera_only"
	LayoutSlate          Layout = "slate"
)

// LayoutValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func LayoutValues() []Layout {
	return []Layout{
		LayoutScreenWithWipe,
		LayoutScreenOnly,
		LayoutCameraOnly,
		LayoutSlate,
	}
}

// Valid は、v が列挙 layout の符号なら true を返す。
func (v Layout) Valid() bool {
	switch v {
	case LayoutScreenWithWipe, LayoutScreenOnly, LayoutCameraOnly, LayoutSlate:
		return true
	}
	return false
}

// Profile は、列挙 profile（requirements.md 20.4（エンコードプロファイル）・11.7）。
type Profile string

const (
	Profile720p Profile = "720p"
	Profile480p Profile = "480p"
)

// ProfileValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func ProfileValues() []Profile {
	return []Profile{
		Profile720p,
		Profile480p,
	}
}

// Valid は、v が列挙 profile の符号なら true を返す。
func (v Profile) Valid() bool {
	switch v {
	case Profile720p, Profile480p:
		return true
	}
	return false
}

// BroadcastState は、列挙 broadcast_state（requirements.md 20.4（配信レコードの状態）・25.1）。
type BroadcastState string

const (
	BroadcastStateReserved      BroadcastState = "reserved"
	BroadcastStateAwaitingMedia BroadcastState = "awaiting_media"
	BroadcastStateConfirming    BroadcastState = "confirming"
	BroadcastStateLive          BroadcastState = "live"
	BroadcastStateInterrupted   BroadcastState = "interrupted"
	BroadcastStateEnded         BroadcastState = "ended"
)

// BroadcastStateValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func BroadcastStateValues() []BroadcastState {
	return []BroadcastState{
		BroadcastStateReserved,
		BroadcastStateAwaitingMedia,
		BroadcastStateConfirming,
		BroadcastStateLive,
		BroadcastStateInterrupted,
		BroadcastStateEnded,
	}
}

// Valid は、v が列挙 broadcast_state の符号なら true を返す。
func (v BroadcastState) Valid() bool {
	switch v {
	case BroadcastStateReserved,
		BroadcastStateAwaitingMedia,
		BroadcastStateConfirming,
		BroadcastStateLive,
		BroadcastStateInterrupted,
		BroadcastStateEnded:
		return true
	}
	return false
}

// SettlementState は、列挙 settlement_state（requirements.md 20.4（清算状態）・25.2）。
type SettlementState string

const (
	SettlementStateNone      SettlementState = "none"
	SettlementStatePending   SettlementState = "pending"
	SettlementStateSettled   SettlementState = "settled"
	SettlementStateAbandoned SettlementState = "abandoned"
)

// SettlementStateValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func SettlementStateValues() []SettlementState {
	return []SettlementState{
		SettlementStateNone,
		SettlementStatePending,
		SettlementStateSettled,
		SettlementStateAbandoned,
	}
}

// Valid は、v が列挙 settlement_state の符号なら true を返す。
func (v SettlementState) Valid() bool {
	switch v {
	case SettlementStateNone, SettlementStatePending, SettlementStateSettled, SettlementStateAbandoned:
		return true
	}
	return false
}

// EndReason は、列挙 end_reason（requirements.md 20.4（終了理由））。
type EndReason string

const (
	EndReasonUserStop              EndReason = "user_stop"
	EndReasonTimeLimit             EndReason = "time_limit"
	EndReasonConnectionLost        EndReason = "connection_lost"
	EndReasonYouTubeEnded          EndReason = "youtube_ended"
	EndReasonAuthorizationRevoked  EndReason = "authorization_revoked"
	EndReasonAdminStop             EndReason = "admin_stop"
	EndReasonStartTimeout          EndReason = "start_timeout"
	EndReasonConfirmTimeout        EndReason = "confirm_timeout"
	EndReasonPrepareFailed         EndReason = "prepare_failed"
	EndReasonPriorUnsettled        EndReason = "prior_unsettled"
	EndReasonInsufficientBandwidth EndReason = "insufficient_bandwidth"
	EndReasonUserCancel            EndReason = "user_cancel"
	EndReasonRelayDisconnect       EndReason = "relay_disconnect"
)

// EndReasonValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func EndReasonValues() []EndReason {
	return []EndReason{
		EndReasonUserStop,
		EndReasonTimeLimit,
		EndReasonConnectionLost,
		EndReasonYouTubeEnded,
		EndReasonAuthorizationRevoked,
		EndReasonAdminStop,
		EndReasonStartTimeout,
		EndReasonConfirmTimeout,
		EndReasonPrepareFailed,
		EndReasonPriorUnsettled,
		EndReasonInsufficientBandwidth,
		EndReasonUserCancel,
		EndReasonRelayDisconnect,
	}
}

// Valid は、v が列挙 end_reason の符号なら true を返す。
func (v EndReason) Valid() bool {
	switch v {
	case EndReasonUserStop,
		EndReasonTimeLimit,
		EndReasonConnectionLost,
		EndReasonYouTubeEnded,
		EndReasonAuthorizationRevoked,
		EndReasonAdminStop,
		EndReasonStartTimeout,
		EndReasonConfirmTimeout,
		EndReasonPrepareFailed,
		EndReasonPriorUnsettled,
		EndReasonInsufficientBandwidth,
		EndReasonUserCancel,
		EndReasonRelayDisconnect:
		return true
	}
	return false
}

// RejectionReason は、列挙 rejection_reason（requirements.md 20.4（開始の拒否理由）・9.2。配列の順が 9.2 の順 0〜13）。
type RejectionReason string

const (
	RejectionReasonInvalidInput           RejectionReason = "invalid_input"
	RejectionReasonNotLoggedIn            RejectionReason = "not_logged_in"
	RejectionReasonRateLimited            RejectionReason = "rate_limited"
	RejectionReasonBotCheckFailed         RejectionReason = "bot_check_failed"
	RejectionReasonBroadcastInProgress    RejectionReason = "broadcast_in_progress"
	RejectionReasonYouTubeNotConnected    RejectionReason = "youtube_not_connected"
	RejectionReasonAuthorizationRevoked   RejectionReason = "authorization_revoked"
	RejectionReasonLiveNotEnabled         RejectionReason = "live_not_enabled"
	RejectionReasonAllowanceConsumed      RejectionReason = "allowance_consumed"
	RejectionReasonAttemptsExhausted      RejectionReason = "attempts_exhausted"
	RejectionReasonIntakePaused           RejectionReason = "intake_paused"
	RejectionReasonTransferBudgetExceeded RejectionReason = "transfer_budget_exceeded"
	RejectionReasonCapacityFull           RejectionReason = "capacity_full"
	RejectionReasonQuotaInsufficient      RejectionReason = "quota_insufficient"
)

// RejectionReasonValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func RejectionReasonValues() []RejectionReason {
	return []RejectionReason{
		RejectionReasonInvalidInput,
		RejectionReasonNotLoggedIn,
		RejectionReasonRateLimited,
		RejectionReasonBotCheckFailed,
		RejectionReasonBroadcastInProgress,
		RejectionReasonYouTubeNotConnected,
		RejectionReasonAuthorizationRevoked,
		RejectionReasonLiveNotEnabled,
		RejectionReasonAllowanceConsumed,
		RejectionReasonAttemptsExhausted,
		RejectionReasonIntakePaused,
		RejectionReasonTransferBudgetExceeded,
		RejectionReasonCapacityFull,
		RejectionReasonQuotaInsufficient,
	}
}

// Valid は、v が列挙 rejection_reason の符号なら true を返す。
func (v RejectionReason) Valid() bool {
	switch v {
	case RejectionReasonInvalidInput,
		RejectionReasonNotLoggedIn,
		RejectionReasonRateLimited,
		RejectionReasonBotCheckFailed,
		RejectionReasonBroadcastInProgress,
		RejectionReasonYouTubeNotConnected,
		RejectionReasonAuthorizationRevoked,
		RejectionReasonLiveNotEnabled,
		RejectionReasonAllowanceConsumed,
		RejectionReasonAttemptsExhausted,
		RejectionReasonIntakePaused,
		RejectionReasonTransferBudgetExceeded,
		RejectionReasonCapacityFull,
		RejectionReasonQuotaInsufficient:
		return true
	}
	return false
}

// YouTubeConnectionState は、列挙 youtube_connection_state（requirements.md 20.4（YouTube 接続状態）・25.4）。
type YouTubeConnectionState string

const (
	YouTubeConnectionStateNotConnected   YouTubeConnectionState = "not_connected"
	YouTubeConnectionStateConnected      YouTubeConnectionState = "connected"
	YouTubeConnectionStateLiveNotEnabled YouTubeConnectionState = "live_not_enabled"
	YouTubeConnectionStateRevoked        YouTubeConnectionState = "revoked"
)

// YouTubeConnectionStateValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func YouTubeConnectionStateValues() []YouTubeConnectionState {
	return []YouTubeConnectionState{
		YouTubeConnectionStateNotConnected,
		YouTubeConnectionStateConnected,
		YouTubeConnectionStateLiveNotEnabled,
		YouTubeConnectionStateRevoked,
	}
}

// Valid は、v が列挙 youtube_connection_state の符号なら true を返す。
func (v YouTubeConnectionState) Valid() bool {
	switch v {
	case YouTubeConnectionStateNotConnected,
		YouTubeConnectionStateConnected,
		YouTubeConnectionStateLiveNotEnabled,
		YouTubeConnectionStateRevoked:
		return true
	}
	return false
}

// StudioState は、列挙 studio_state（requirements.md 20.4（スタジオの状態）・25.3）。
type StudioState string

const (
	StudioStateIdle         StudioState = "idle"
	StudioStateRequesting   StudioState = "requesting"
	StudioStateConnecting   StudioState = "connecting"
	StudioStateProbing      StudioState = "probing"
	StudioStateStarting     StudioState = "starting"
	StudioStateLive         StudioState = "live"
	StudioStateDegraded     StudioState = "degraded"
	StudioStateReconnecting StudioState = "reconnecting"
	StudioStateStopping     StudioState = "stopping"
	StudioStateEnded        StudioState = "ended"
)

// StudioStateValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func StudioStateValues() []StudioState {
	return []StudioState{
		StudioStateIdle,
		StudioStateRequesting,
		StudioStateConnecting,
		StudioStateProbing,
		StudioStateStarting,
		StudioStateLive,
		StudioStateDegraded,
		StudioStateReconnecting,
		StudioStateStopping,
		StudioStateEnded,
	}
}

// Valid は、v が列挙 studio_state の符号なら true を返す。
func (v StudioState) Valid() bool {
	switch v {
	case StudioStateIdle,
		StudioStateRequesting,
		StudioStateConnecting,
		StudioStateProbing,
		StudioStateStarting,
		StudioStateLive,
		StudioStateDegraded,
		StudioStateReconnecting,
		StudioStateStopping,
		StudioStateEnded:
		return true
	}
	return false
}

// SourceState は、列挙 source_state（requirements.md 20.4（ソースの状態）・25.5）。
type SourceState string

const (
	SourceStateDetached   SourceState = "detached"
	SourceStateRequesting SourceState = "requesting"
	SourceStateActive     SourceState = "active"
	SourceStateDenied     SourceState = "denied"
	SourceStateLost       SourceState = "lost"
)

// SourceStateValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func SourceStateValues() []SourceState {
	return []SourceState{
		SourceStateDetached,
		SourceStateRequesting,
		SourceStateActive,
		SourceStateDenied,
		SourceStateLost,
	}
}

// Valid は、v が列挙 source_state の符号なら true を返す。
func (v SourceState) Valid() bool {
	switch v {
	case SourceStateDetached, SourceStateRequesting, SourceStateActive, SourceStateDenied, SourceStateLost:
		return true
	}
	return false
}

// WSMessageType は、列挙 ws_message_type（requirements.md 20.4（転送メッセージ種別）・11.9。前の 7 種がブラウザ → 中継、後の 7 種が中継 → ブラウザ）。
type WSMessageType string

const (
	WSMessageTypeHello           WSMessageType = "hello"
	WSMessageTypeProbe           WSMessageType = "probe"
	WSMessageTypeStart           WSMessageType = "start"
	WSMessageTypeVideo           WSMessageType = "video"
	WSMessageTypeAudio           WSMessageType = "audio"
	WSMessageTypeReport          WSMessageType = "report"
	WSMessageTypeEnd             WSMessageType = "end"
	WSMessageTypeAccepted        WSMessageType = "accepted"
	WSMessageTypeProbeResult     WSMessageType = "probe_result"
	WSMessageTypeAck             WSMessageType = "ack"
	WSMessageTypeKeyframeRequest WSMessageType = "keyframe_request"
	WSMessageTypeThrottle        WSMessageType = "throttle"
	WSMessageTypeStatus          WSMessageType = "status"
	WSMessageTypeFatal           WSMessageType = "fatal"
)

// WSMessageTypeValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func WSMessageTypeValues() []WSMessageType {
	return []WSMessageType{
		WSMessageTypeHello,
		WSMessageTypeProbe,
		WSMessageTypeStart,
		WSMessageTypeVideo,
		WSMessageTypeAudio,
		WSMessageTypeReport,
		WSMessageTypeEnd,
		WSMessageTypeAccepted,
		WSMessageTypeProbeResult,
		WSMessageTypeAck,
		WSMessageTypeKeyframeRequest,
		WSMessageTypeThrottle,
		WSMessageTypeStatus,
		WSMessageTypeFatal,
	}
}

// Valid は、v が列挙 ws_message_type の符号なら true を返す。
func (v WSMessageType) Valid() bool {
	switch v {
	case WSMessageTypeHello,
		WSMessageTypeProbe,
		WSMessageTypeStart,
		WSMessageTypeVideo,
		WSMessageTypeAudio,
		WSMessageTypeReport,
		WSMessageTypeEnd,
		WSMessageTypeAccepted,
		WSMessageTypeProbeResult,
		WSMessageTypeAck,
		WSMessageTypeKeyframeRequest,
		WSMessageTypeThrottle,
		WSMessageTypeStatus,
		WSMessageTypeFatal:
		return true
	}
	return false
}

// InternalCall は、列挙 internal_call（requirements.md 20.4（内部通信の呼び出し）・11.9）。
type InternalCall string

const (
	InternalCallVerify    InternalCall = "verify"
	InternalCallProvision InternalCall = "provision"
	InternalCallHeartbeat InternalCall = "heartbeat"
	InternalCallEvent     InternalCall = "event"
)

// InternalCallValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func InternalCallValues() []InternalCall {
	return []InternalCall{
		InternalCallVerify,
		InternalCallProvision,
		InternalCallHeartbeat,
		InternalCallEvent,
	}
}

// Valid は、v が列挙 internal_call の符号なら true を返す。
func (v InternalCall) Valid() bool {
	switch v {
	case InternalCallVerify, InternalCallProvision, InternalCallHeartbeat, InternalCallEvent:
		return true
	}
	return false
}

// BroadcastEventType は、列挙 broadcast_event_type（requirements.md 20.4（配信の出来事の種別））。
type BroadcastEventType string

const (
	BroadcastEventTypeAccepted            BroadcastEventType = "accepted"
	BroadcastEventTypeVerified            BroadcastEventType = "verified"
	BroadcastEventTypeProbeDone           BroadcastEventType = "probe_done"
	BroadcastEventTypeProvisionStarted    BroadcastEventType = "provision_started"
	BroadcastEventTypeProvisionDone       BroadcastEventType = "provision_done"
	BroadcastEventTypePublishStarted      BroadcastEventType = "publish_started"
	BroadcastEventTypeLiveConfirmed       BroadcastEventType = "live_confirmed"
	BroadcastEventTypeSourceAdded         BroadcastEventType = "source_added"
	BroadcastEventTypeSourceLost          BroadcastEventType = "source_lost"
	BroadcastEventTypeFallbackSwitched    BroadcastEventType = "fallback_switched"
	BroadcastEventTypeBitrateDown         BroadcastEventType = "bitrate_down"
	BroadcastEventTypeBitrateUp           BroadcastEventType = "bitrate_up"
	BroadcastEventTypeVideoDropped        BroadcastEventType = "video_dropped"
	BroadcastEventTypeDegradedStarted     BroadcastEventType = "degraded_started"
	BroadcastEventTypeDegradedCleared     BroadcastEventType = "degraded_cleared"
	BroadcastEventTypeInterrupted         BroadcastEventType = "interrupted"
	BroadcastEventTypeResumed             BroadcastEventType = "resumed"
	BroadcastEventTypeThrottleDirected    BroadcastEventType = "throttle_directed"
	BroadcastEventTypeKeyframeRequested   BroadcastEventType = "keyframe_requested"
	BroadcastEventTypeYouTubeWarning      BroadcastEventType = "youtube_warning"
	BroadcastEventTypeTimeLimitNotice     BroadcastEventType = "time_limit_notice"
	BroadcastEventTypeEnded               BroadcastEventType = "ended"
	BroadcastEventTypeSettlementSucceeded BroadcastEventType = "settlement_succeeded"
	BroadcastEventTypeSettlementFailed    BroadcastEventType = "settlement_failed"
)

// BroadcastEventTypeValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func BroadcastEventTypeValues() []BroadcastEventType {
	return []BroadcastEventType{
		BroadcastEventTypeAccepted,
		BroadcastEventTypeVerified,
		BroadcastEventTypeProbeDone,
		BroadcastEventTypeProvisionStarted,
		BroadcastEventTypeProvisionDone,
		BroadcastEventTypePublishStarted,
		BroadcastEventTypeLiveConfirmed,
		BroadcastEventTypeSourceAdded,
		BroadcastEventTypeSourceLost,
		BroadcastEventTypeFallbackSwitched,
		BroadcastEventTypeBitrateDown,
		BroadcastEventTypeBitrateUp,
		BroadcastEventTypeVideoDropped,
		BroadcastEventTypeDegradedStarted,
		BroadcastEventTypeDegradedCleared,
		BroadcastEventTypeInterrupted,
		BroadcastEventTypeResumed,
		BroadcastEventTypeThrottleDirected,
		BroadcastEventTypeKeyframeRequested,
		BroadcastEventTypeYouTubeWarning,
		BroadcastEventTypeTimeLimitNotice,
		BroadcastEventTypeEnded,
		BroadcastEventTypeSettlementSucceeded,
		BroadcastEventTypeSettlementFailed,
	}
}

// Valid は、v が列挙 broadcast_event_type の符号なら true を返す。
func (v BroadcastEventType) Valid() bool {
	switch v {
	case BroadcastEventTypeAccepted,
		BroadcastEventTypeVerified,
		BroadcastEventTypeProbeDone,
		BroadcastEventTypeProvisionStarted,
		BroadcastEventTypeProvisionDone,
		BroadcastEventTypePublishStarted,
		BroadcastEventTypeLiveConfirmed,
		BroadcastEventTypeSourceAdded,
		BroadcastEventTypeSourceLost,
		BroadcastEventTypeFallbackSwitched,
		BroadcastEventTypeBitrateDown,
		BroadcastEventTypeBitrateUp,
		BroadcastEventTypeVideoDropped,
		BroadcastEventTypeDegradedStarted,
		BroadcastEventTypeDegradedCleared,
		BroadcastEventTypeInterrupted,
		BroadcastEventTypeResumed,
		BroadcastEventTypeThrottleDirected,
		BroadcastEventTypeKeyframeRequested,
		BroadcastEventTypeYouTubeWarning,
		BroadcastEventTypeTimeLimitNotice,
		BroadcastEventTypeEnded,
		BroadcastEventTypeSettlementSucceeded,
		BroadcastEventTypeSettlementFailed:
		return true
	}
	return false
}

// UsageEventType は、列挙 usage_event_type（requirements.md 20.4（測定イベントの種別）・18 章）。
type UsageEventType string

const (
	UsageEventTypeLoginStarted       UsageEventType = "login_started"
	UsageEventTypeLoginCompleted     UsageEventType = "login_completed"
	UsageEventTypeConnectStarted     UsageEventType = "connect_started"
	UsageEventTypeConnectCompleted   UsageEventType = "connect_completed"
	UsageEventTypeConnectFailed      UsageEventType = "connect_failed"
	UsageEventTypeCapabilityDetected UsageEventType = "capability_detected"
	UsageEventTypeSourceGranted      UsageEventType = "source_granted"
	UsageEventTypeSourceDenied       UsageEventType = "source_denied"
	UsageEventTypeStartRequested     UsageEventType = "start_requested"
	UsageEventTypeStartRejected      UsageEventType = "start_rejected"
	UsageEventTypeLineMeasured       UsageEventType = "line_measured"
	UsageEventTypePrepared           UsageEventType = "prepared"
	UsageEventTypeLiveConfirmed      UsageEventType = "live_confirmed"
	UsageEventTypeDegraded           UsageEventType = "degraded"
	UsageEventTypeReconnectStarted   UsageEventType = "reconnect_started"
	UsageEventTypeReconnectSucceeded UsageEventType = "reconnect_succeeded"
	UsageEventTypeBroadcastEnded     UsageEventType = "broadcast_ended"
	UsageEventTypeWatchURLCopied     UsageEventType = "watch_url_copied"
	UsageEventTypeDisconnected       UsageEventType = "disconnected"
	UsageEventTypeAccountDeleted     UsageEventType = "account_deleted"
)

// UsageEventTypeValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func UsageEventTypeValues() []UsageEventType {
	return []UsageEventType{
		UsageEventTypeLoginStarted,
		UsageEventTypeLoginCompleted,
		UsageEventTypeConnectStarted,
		UsageEventTypeConnectCompleted,
		UsageEventTypeConnectFailed,
		UsageEventTypeCapabilityDetected,
		UsageEventTypeSourceGranted,
		UsageEventTypeSourceDenied,
		UsageEventTypeStartRequested,
		UsageEventTypeStartRejected,
		UsageEventTypeLineMeasured,
		UsageEventTypePrepared,
		UsageEventTypeLiveConfirmed,
		UsageEventTypeDegraded,
		UsageEventTypeReconnectStarted,
		UsageEventTypeReconnectSucceeded,
		UsageEventTypeBroadcastEnded,
		UsageEventTypeWatchURLCopied,
		UsageEventTypeDisconnected,
		UsageEventTypeAccountDeleted,
	}
}

// Valid は、v が列挙 usage_event_type の符号なら true を返す。
func (v UsageEventType) Valid() bool {
	switch v {
	case UsageEventTypeLoginStarted,
		UsageEventTypeLoginCompleted,
		UsageEventTypeConnectStarted,
		UsageEventTypeConnectCompleted,
		UsageEventTypeConnectFailed,
		UsageEventTypeCapabilityDetected,
		UsageEventTypeSourceGranted,
		UsageEventTypeSourceDenied,
		UsageEventTypeStartRequested,
		UsageEventTypeStartRejected,
		UsageEventTypeLineMeasured,
		UsageEventTypePrepared,
		UsageEventTypeLiveConfirmed,
		UsageEventTypeDegraded,
		UsageEventTypeReconnectStarted,
		UsageEventTypeReconnectSucceeded,
		UsageEventTypeBroadcastEnded,
		UsageEventTypeWatchURLCopied,
		UsageEventTypeDisconnected,
		UsageEventTypeAccountDeleted:
		return true
	}
	return false
}

// SettingKey は、列挙 setting_key（requirements.md 20.4（制限値・設定）・8 章）。
type SettingKey string

const (
	SettingKeyDailyAllowance          SettingKey = "daily_allowance"
	SettingKeyAttemptLimit            SettingKey = "attempt_limit"
	SettingKeyConcurrentLimit         SettingKey = "concurrent_limit"
	SettingKeyTimeLimitMinutes        SettingKey = "time_limit_minutes"
	SettingKeyIntakeRatePerHour       SettingKey = "intake_rate_per_hour"
	SettingKeyMonthlyTransferBudgetGB SettingKey = "monthly_transfer_budget_gb"
	SettingKeyDailyQuotaUnits         SettingKey = "daily_quota_units"
	SettingKeyBotScoreThreshold       SettingKey = "bot_score_threshold"
	SettingKeyIntakePaused            SettingKey = "intake_paused"
)

// SettingKeyValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func SettingKeyValues() []SettingKey {
	return []SettingKey{
		SettingKeyDailyAllowance,
		SettingKeyAttemptLimit,
		SettingKeyConcurrentLimit,
		SettingKeyTimeLimitMinutes,
		SettingKeyIntakeRatePerHour,
		SettingKeyMonthlyTransferBudgetGB,
		SettingKeyDailyQuotaUnits,
		SettingKeyBotScoreThreshold,
		SettingKeyIntakePaused,
	}
}

// Valid は、v が列挙 setting_key の符号なら true を返す。
func (v SettingKey) Valid() bool {
	switch v {
	case SettingKeyDailyAllowance,
		SettingKeyAttemptLimit,
		SettingKeyConcurrentLimit,
		SettingKeyTimeLimitMinutes,
		SettingKeyIntakeRatePerHour,
		SettingKeyMonthlyTransferBudgetGB,
		SettingKeyDailyQuotaUnits,
		SettingKeyBotScoreThreshold,
		SettingKeyIntakePaused:
		return true
	}
	return false
}

// AdaptiveCondition は、列挙 adaptive_condition（requirements.md 20.4（適応制御の条件）・12 章。配列の順が 12 章の表の 7 行の順）。
type AdaptiveCondition string

const (
	AdaptiveConditionBacklogHighTwice       AdaptiveCondition = "backlog_high_twice"
	AdaptiveConditionBacklogLowNoDrop       AdaptiveCondition = "backlog_low_no_drop"
	AdaptiveConditionBacklogCritical        AdaptiveCondition = "backlog_critical"
	AdaptiveConditionVideoAckStalled        AdaptiveCondition = "video_ack_stalled"
	AdaptiveConditionBacklogSevereSustained AdaptiveCondition = "backlog_severe_sustained"
	AdaptiveConditionDegradedEnter          AdaptiveCondition = "degraded_enter"
	AdaptiveConditionDegradedExit           AdaptiveCondition = "degraded_exit"
)

// AdaptiveConditionValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func AdaptiveConditionValues() []AdaptiveCondition {
	return []AdaptiveCondition{
		AdaptiveConditionBacklogHighTwice,
		AdaptiveConditionBacklogLowNoDrop,
		AdaptiveConditionBacklogCritical,
		AdaptiveConditionVideoAckStalled,
		AdaptiveConditionBacklogSevereSustained,
		AdaptiveConditionDegradedEnter,
		AdaptiveConditionDegradedExit,
	}
}

// Valid は、v が列挙 adaptive_condition の符号なら true を返す。
func (v AdaptiveCondition) Valid() bool {
	switch v {
	case AdaptiveConditionBacklogHighTwice,
		AdaptiveConditionBacklogLowNoDrop,
		AdaptiveConditionBacklogCritical,
		AdaptiveConditionVideoAckStalled,
		AdaptiveConditionBacklogSevereSustained,
		AdaptiveConditionDegradedEnter,
		AdaptiveConditionDegradedExit:
		return true
	}
	return false
}

// ColorRole は、列挙 color_role（requirements.md 20.4（配色の役割）・17.2）。
type ColorRole string

const (
	ColorRoleBase          ColorRole = "base"
	ColorRoleSurface       ColorRole = "surface"
	ColorRoleSurfaceRaised ColorRole = "surface_raised"
	ColorRoleDivider       ColorRole = "divider"
	ColorRoleControlBorder ColorRole = "control_border"
	ColorRoleTextPrimary   ColorRole = "text_primary"
	ColorRoleTextSecondary ColorRole = "text_secondary"
	ColorRoleAccent        ColorRole = "accent"
	ColorRoleLive          ColorRole = "live"
	ColorRoleWarning       ColorRole = "warning"
	ColorRoleSuccess       ColorRole = "success"
	ColorRoleFocus         ColorRole = "focus"
)

// ColorRoleValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func ColorRoleValues() []ColorRole {
	return []ColorRole{
		ColorRoleBase,
		ColorRoleSurface,
		ColorRoleSurfaceRaised,
		ColorRoleDivider,
		ColorRoleControlBorder,
		ColorRoleTextPrimary,
		ColorRoleTextSecondary,
		ColorRoleAccent,
		ColorRoleLive,
		ColorRoleWarning,
		ColorRoleSuccess,
		ColorRoleFocus,
	}
}

// Valid は、v が列挙 color_role の符号なら true を返す。
func (v ColorRole) Valid() bool {
	switch v {
	case ColorRoleBase,
		ColorRoleSurface,
		ColorRoleSurfaceRaised,
		ColorRoleDivider,
		ColorRoleControlBorder,
		ColorRoleTextPrimary,
		ColorRoleTextSecondary,
		ColorRoleAccent,
		ColorRoleLive,
		ColorRoleWarning,
		ColorRoleSuccess,
		ColorRoleFocus:
		return true
	}
	return false
}

// Hex は、配色の役割の 16 進値（17.2）を返す。役割でなければ空文字列と false。
func (v ColorRole) Hex() (string, bool) {
	switch v {
	case ColorRoleBase:
		return "#0F1115", true
	case ColorRoleSurface:
		return "#171A21", true
	case ColorRoleSurfaceRaised:
		return "#1F2430", true
	case ColorRoleDivider:
		return "#2B3140", true
	case ColorRoleControlBorder:
		return "#6B7488", true
	case ColorRoleTextPrimary:
		return "#F2F4F8", true
	case ColorRoleTextSecondary:
		return "#A9B1C1", true
	case ColorRoleAccent:
		return "#3FB6A8", true
	case ColorRoleLive:
		return "#CE2C31", true
	case ColorRoleWarning:
		return "#F5A524", true
	case ColorRoleSuccess:
		return "#46A758", true
	case ColorRoleFocus:
		return "#8AB4F8", true
	}
	return "", false
}

// OnHex は、役割の上に載せる文字の色（16 進値）を返す。持たない役割は空文字列と false。
func (v ColorRole) OnHex() (string, bool) {
	switch v {
	case ColorRoleAccent:
		return "#06201D", true
	case ColorRoleLive:
		return "#FFFFFF", true
	}
	return "", false
}

// FatalCode は、列挙 fatal_code（契約独自の列挙（#3）。ws-protocol.md の致命通知）。
type FatalCode string

const (
	FatalCodeMessageTooLarge   FatalCode = "message_too_large"
	FatalCodeBitrateExceeded   FatalCode = "bitrate_exceeded"
	FatalCodeHelloTimeout      FatalCode = "hello_timeout"
	FatalCodeInvalidTicket     FatalCode = "invalid_ticket"
	FatalCodeStaleEpoch        FatalCode = "stale_epoch"
	FatalCodeBroadcastEnded    FatalCode = "broadcast_ended"
	FatalCodeProtocolViolation FatalCode = "protocol_violation"
	FatalCodeHeartbeatLost     FatalCode = "heartbeat_lost"
	FatalCodePublishFailed     FatalCode = "publish_failed"
	FatalCodeInternalError     FatalCode = "internal_error"
)

// FatalCodeValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func FatalCodeValues() []FatalCode {
	return []FatalCode{
		FatalCodeMessageTooLarge,
		FatalCodeBitrateExceeded,
		FatalCodeHelloTimeout,
		FatalCodeInvalidTicket,
		FatalCodeStaleEpoch,
		FatalCodeBroadcastEnded,
		FatalCodeProtocolViolation,
		FatalCodeHeartbeatLost,
		FatalCodePublishFailed,
		FatalCodeInternalError,
	}
}

// Valid は、v が列挙 fatal_code の符号なら true を返す。
func (v FatalCode) Valid() bool {
	switch v {
	case FatalCodeMessageTooLarge,
		FatalCodeBitrateExceeded,
		FatalCodeHelloTimeout,
		FatalCodeInvalidTicket,
		FatalCodeStaleEpoch,
		FatalCodeBroadcastEnded,
		FatalCodeProtocolViolation,
		FatalCodeHeartbeatLost,
		FatalCodePublishFailed,
		FatalCodeInternalError:
		return true
	}
	return false
}

// RelayEventKind は、列挙 relay_event_kind（契約独自の列挙（#3）。internal-api.md の事象の種類）。
type RelayEventKind string

const (
	RelayEventKindPublishStarted    RelayEventKind = "publish_started"
	RelayEventKindInterrupted       RelayEventKind = "interrupted"
	RelayEventKindResumed           RelayEventKind = "resumed"
	RelayEventKindPublishFailed     RelayEventKind = "publish_failed"
	RelayEventKindRelayDisconnected RelayEventKind = "relay_disconnected"
	RelayEventKindSessionEnded      RelayEventKind = "session_ended"
)

// RelayEventKindValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func RelayEventKindValues() []RelayEventKind {
	return []RelayEventKind{
		RelayEventKindPublishStarted,
		RelayEventKindInterrupted,
		RelayEventKindResumed,
		RelayEventKindPublishFailed,
		RelayEventKindRelayDisconnected,
		RelayEventKindSessionEnded,
	}
}

// Valid は、v が列挙 relay_event_kind の符号なら true を返す。
func (v RelayEventKind) Valid() bool {
	switch v {
	case RelayEventKindPublishStarted,
		RelayEventKindInterrupted,
		RelayEventKindResumed,
		RelayEventKindPublishFailed,
		RelayEventKindRelayDisconnected,
		RelayEventKindSessionEnded:
		return true
	}
	return false
}

// InterruptCause は、列挙 interrupt_cause（契約独自の列挙（#3）。internal-api.md の事象（中断）の原因）。
type InterruptCause string

const (
	InterruptCauseBrowserDisconnected InterruptCause = "browser_disconnected"
	InterruptCauseMediaStalled        InterruptCause = "media_stalled"
	InterruptCauseRTMPSDisconnected   InterruptCause = "rtmps_disconnected"
	InterruptCauseBufferOverflow      InterruptCause = "buffer_overflow"
)

// InterruptCauseValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func InterruptCauseValues() []InterruptCause {
	return []InterruptCause{
		InterruptCauseBrowserDisconnected,
		InterruptCauseMediaStalled,
		InterruptCauseRTMPSDisconnected,
		InterruptCauseBufferOverflow,
	}
}

// Valid は、v が列挙 interrupt_cause の符号なら true を返す。
func (v InterruptCause) Valid() bool {
	switch v {
	case InterruptCauseBrowserDisconnected,
		InterruptCauseMediaStalled,
		InterruptCauseRTMPSDisconnected,
		InterruptCauseBufferOverflow:
		return true
	}
	return false
}

// BrowserEventKind は、列挙 browser_event_kind（契約独自の列挙（#3）。状態報告に載せる、ブラウザ側の出来事（配信の出来事の種別の部分集合））。
type BrowserEventKind string

const (
	BrowserEventKindSourceAdded      BrowserEventKind = "source_added"
	BrowserEventKindSourceLost       BrowserEventKind = "source_lost"
	BrowserEventKindFallbackSwitched BrowserEventKind = "fallback_switched"
	BrowserEventKindBitrateDown      BrowserEventKind = "bitrate_down"
	BrowserEventKindBitrateUp        BrowserEventKind = "bitrate_up"
	BrowserEventKindVideoDropped     BrowserEventKind = "video_dropped"
	BrowserEventKindDegradedStarted  BrowserEventKind = "degraded_started"
	BrowserEventKindDegradedCleared  BrowserEventKind = "degraded_cleared"
)

// BrowserEventKindValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func BrowserEventKindValues() []BrowserEventKind {
	return []BrowserEventKind{
		BrowserEventKindSourceAdded,
		BrowserEventKindSourceLost,
		BrowserEventKindFallbackSwitched,
		BrowserEventKindBitrateDown,
		BrowserEventKindBitrateUp,
		BrowserEventKindVideoDropped,
		BrowserEventKindDegradedStarted,
		BrowserEventKindDegradedCleared,
	}
}

// Valid は、v が列挙 browser_event_kind の符号なら true を返す。
func (v BrowserEventKind) Valid() bool {
	switch v {
	case BrowserEventKindSourceAdded,
		BrowserEventKindSourceLost,
		BrowserEventKindFallbackSwitched,
		BrowserEventKindBitrateDown,
		BrowserEventKindBitrateUp,
		BrowserEventKindVideoDropped,
		BrowserEventKindDegradedStarted,
		BrowserEventKindDegradedCleared:
		return true
	}
	return false
}

// ConnectResult は、列挙 connect_result（契約独自の列挙（#3）。YouTube 接続の結果（7.2））。
type ConnectResult string

const (
	ConnectResultConnected      ConnectResult = "connected"
	ConnectResultLiveNotEnabled ConnectResult = "live_not_enabled"
	ConnectResultScopeDenied    ConnectResult = "scope_denied"
	ConnectResultNoRefreshToken ConnectResult = "no_refresh_token"
	ConnectResultNoChannel      ConnectResult = "no_channel"
	ConnectResultUnverifiable   ConnectResult = "unverifiable"
)

// ConnectResultValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func ConnectResultValues() []ConnectResult {
	return []ConnectResult{
		ConnectResultConnected,
		ConnectResultLiveNotEnabled,
		ConnectResultScopeDenied,
		ConnectResultNoRefreshToken,
		ConnectResultNoChannel,
		ConnectResultUnverifiable,
	}
}

// Valid は、v が列挙 connect_result の符号なら true を返す。
func (v ConnectResult) Valid() bool {
	switch v {
	case ConnectResultConnected,
		ConnectResultLiveNotEnabled,
		ConnectResultScopeDenied,
		ConnectResultNoRefreshToken,
		ConnectResultNoChannel,
		ConnectResultUnverifiable:
		return true
	}
	return false
}

// LoginError は、列挙 login_error（契約独自の列挙（#3）。ログインの失敗の種類（7.1））。
type LoginError string

const (
	LoginErrorRegistrationHeld LoginError = "registration_held"
	LoginErrorOauthFailed      LoginError = "oauth_failed"
)

// LoginErrorValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func LoginErrorValues() []LoginError {
	return []LoginError{
		LoginErrorRegistrationHeld,
		LoginErrorOauthFailed,
	}
}

// Valid は、v が列挙 login_error の符号なら true を返す。
func (v LoginError) Valid() bool {
	switch v {
	case LoginErrorRegistrationHeld, LoginErrorOauthFailed:
		return true
	}
	return false
}

// Resolution は、列挙 resolution（契約独自の列挙（#3）。拒否の「再試行で解消するか」の区分（9.2））。
type Resolution string

const (
	ResolutionFixInput     Resolution = "fix_input"
	ResolutionLogIn        Resolution = "log_in"
	ResolutionWait         Resolution = "wait"
	ResolutionStopFirst    Resolution = "stop_first"
	ResolutionConnect      Resolution = "connect"
	ResolutionReconnect    Resolution = "reconnect"
	ResolutionEnableLive   Resolution = "enable_live"
	ResolutionNextUsageDay Resolution = "next_usage_day"
	ResolutionAfterRelease Resolution = "after_release"
	ResolutionNextMonth    Resolution = "next_month"
	ResolutionNextQuotaDay Resolution = "next_quota_day"
)

// ResolutionValues は、全値を契約の順に返す。呼び出しのたびに新しいスライスを返すので、呼び出し側が変更しても影響しない。
func ResolutionValues() []Resolution {
	return []Resolution{
		ResolutionFixInput,
		ResolutionLogIn,
		ResolutionWait,
		ResolutionStopFirst,
		ResolutionConnect,
		ResolutionReconnect,
		ResolutionEnableLive,
		ResolutionNextUsageDay,
		ResolutionAfterRelease,
		ResolutionNextMonth,
		ResolutionNextQuotaDay,
	}
}

// Valid は、v が列挙 resolution の符号なら true を返す。
func (v Resolution) Valid() bool {
	switch v {
	case ResolutionFixInput,
		ResolutionLogIn,
		ResolutionWait,
		ResolutionStopFirst,
		ResolutionConnect,
		ResolutionReconnect,
		ResolutionEnableLive,
		ResolutionNextUsageDay,
		ResolutionAfterRelease,
		ResolutionNextMonth,
		ResolutionNextQuotaDay:
		return true
	}
	return false
}
