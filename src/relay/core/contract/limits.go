package contract

// 契約の制限値・間隔・閾値・固定値（src/contracts/limits.json）。キーの単位は名前に含まれる。

// ProfileLimits は、プロファイルごとの制限値（11.7・11.8）。LineThresholdKbps は、実効スループットがこの値以上ならそのプロファイル。
type ProfileLimits struct {
	Width                   int
	Height                  int
	Framerate               int
	VideoBitrateMinKbps     int
	VideoBitrateInitialKbps int
	VideoBitrateMaxKbps     int
	LineThresholdKbps       int
}

// ProfileLimitsOf は、プロファイルの制限値を返す。未知のプロファイルは、零値と false。
func ProfileLimitsOf(profile Profile) (ProfileLimits, bool) {
	switch profile {
	case Profile720p:
		return ProfileLimits{
			Width:                   1280,
			Height:                  720,
			Framerate:               30,
			VideoBitrateMinKbps:     3000,
			VideoBitrateInitialKbps: 4500,
			VideoBitrateMaxKbps:     6000,
			LineThresholdKbps:       4100,
		}, true
	case Profile480p:
		return ProfileLimits{
			Width:                   854,
			Height:                  480,
			Framerate:               30,
			VideoBitrateMinKbps:     800,
			VideoBitrateInitialKbps: 1500,
			VideoBitrateMaxKbps:     2500,
			LineThresholdKbps:       1200,
		}, true
	}
	return ProfileLimits{}, false
}

// --- 映像のコーデックとキーフレーム（11.7） ---

const (
	VideoCodecMain                = "avc1.4D401F"
	VideoCodecConstrainedBaseline = "avc1.42E01F"
	VideoKeyframeIntervalSeconds  = 2
)

// --- 音声（11.5・11.6・11.7） ---

const (
	AudioCodec                = "mp4a.40.2"
	AudioSampleRateHz         = 44100
	AudioChannels             = 2
	AudioBitrateKbps          = 128
	AudioSamplesPerVideoFrame = 1470
)

// --- 回線計測（11.8） ---

const (
	LineProbeDurationSeconds             = 3
	LineProbeMaxRateKbps                 = 6000
	LineProbeMessageBytesHint            = 32768
	LineProbeStartBitrateThroughputRatio = 0.75
)

// --- 適応制御（12 章）。Conditions のキーは列挙 AdaptiveCondition の値。Over は超える・Under は未満・AtMost は以下 ---

const (
	AdaptiveEvaluationIntervalMs                             = 1000
	AdaptiveTargetChangeMinIntervalMs                        = 1000
	AdaptiveEncoderQueueMaxFrames                            = 2
	AdaptiveConditionsBacklogHighTwiceBacklogOverMs          = 1500
	AdaptiveConditionsBacklogHighTwiceConsecutiveEvaluations = 2
	AdaptiveConditionsBacklogHighTwiceDecreasePercent        = 30
	AdaptiveConditionsBacklogLowNoDropBacklogUnderMs         = 300
	AdaptiveConditionsBacklogLowNoDropNoDropWindowSeconds    = 10
	AdaptiveConditionsBacklogLowNoDropIncreasePercent        = 10
	AdaptiveConditionsBacklogCriticalBacklogOverMs           = 4000
	AdaptiveConditionsVideoAckStalledStalledSeconds          = 10
	AdaptiveConditionsBacklogSevereSustainedBacklogOverMs    = 8000
	AdaptiveConditionsBacklogSevereSustainedDurationSeconds  = 10
	AdaptiveConditionsDegradedEnterBacklogOverMs             = 1500
	AdaptiveConditionsDegradedEnterDurationSeconds           = 20
	AdaptiveConditionsDegradedExitBacklogAtMostMs            = 1500
	AdaptiveConditionsDegradedExitDurationSeconds            = 10
)

// --- WebSocket 転送フレーム（11.9）。種別符号と方向は frame.go ---

const (
	WSFrameVersion                       = 1
	WSFrameHeaderBytes                   = 17
	WSFrameHeaderFieldsMagicOffset       = 0
	WSFrameHeaderFieldsMagicLength       = 2
	WSFrameHeaderFieldsVersionOffset     = 2
	WSFrameHeaderFieldsVersionLength     = 1
	WSFrameHeaderFieldsTypeOffset        = 3
	WSFrameHeaderFieldsTypeLength        = 1
	WSFrameHeaderFieldsAttributesOffset  = 4
	WSFrameHeaderFieldsAttributesLength  = 1
	WSFrameHeaderFieldsTimestampUsOffset = 5
	WSFrameHeaderFieldsTimestampUsLength = 8
	WSFrameHeaderFieldsBodyLengthOffset  = 13
	WSFrameHeaderFieldsBodyLengthLength  = 4
	WSFrameKeyframeAttributeBit          = 0
	WSFrameMaxMessageBytes               = 2097152
)

// --- 中継（11.9・11.10） ---

const (
	RelayHelloTimeoutSeconds                     = 10
	RelayIngressBitrateLimitFactor               = 1.5
	RelayIngressBitrateWindowSeconds             = 10
	RelayIngressBitrateLimitProbeProfile Profile = Profile720p
	RelayMediaStallSeconds                       = 5
	RelayHeartbeatIntervalSeconds                = 2
	RelayHeartbeatLostStopSeconds                = 60
	RelayEgressBufferLimitMs                     = 3000
	RelayEgressThrottleMs                        = 1500
	RelayAckIntervalMs                           = 500
	RelayReportIntervalMs                        = 1000
)

// --- 接続チケット（11.9） ---

const (
	TicketsTTLSeconds = 60
)

// --- 期限（13.2・10.4・8.3） ---

const (
	DeadlinesReservedSeconds                   = 90
	DeadlinesAwaitingMediaSeconds              = 30
	DeadlinesConfirmingSeconds                 = 120
	DeadlinesInterruptedRelayNotifiedSeconds   = 30
	DeadlinesInterruptedHeartbeatLostSeconds   = 75
	DeadlinesHeartbeatLostDetectSeconds        = 10
	DeadlinesMaxResumes                        = 10
	DeadlinesLiveConfirmPollIntervalSeconds    = 5
	DeadlinesLiveCheckIntervalSeconds          = 300
	DeadlinesDeadlineMonitorMaxIntervalSeconds = 5
	DeadlinesReconnectBackoffCapMs             = 5000
	DeadlinesTimeLimitNoticeBeforeSeconds      = 300
)

// DeadlinesSettlementRetryDelaysSeconds は、deadlines.settlement_retry_delays_seconds を、新しいスライスで返す。
func DeadlinesSettlementRetryDelaysSeconds() []int {
	return []int{60, 120, 240}
}

// --- 割り当て台帳（8.4） ---

const (
	QuotaCommonUnits                   = 500
	QuotaSafetyMarginUnits             = 500
	QuotaBroadcastUsableUnitsAtDefault = 9000
	QuotaBroadcastReservationUnits     = 550
	QuotaPrepReservationUnits          = 340
	QuotaSettleReservationUnits        = 210
	QuotaUnitCostsList                 = 1
	QuotaUnitCostsInsert               = 50
	QuotaUnitCostsUpdate               = 50
	QuotaUnitCostsBind                 = 50
	QuotaUnitCostsTransition           = 50
	QuotaUnitCostsDelete               = 50
)

// --- RTMPS の送出先の許可（10.1・28.1。公式に許可ホストの列挙が無く、最初の実機で確定する） ---

const (
	RTMPSIngestScheme          = "rtmps"
	RTMPSIngestPort            = 443
	RTMPSIngestUserinfoAllowed = false
	RTMPSIngestQueryAllowed    = false
)

// RTMPSIngestHosts は、rtmps_ingest.hosts を、新しいスライスで返す。
func RTMPSIngestHosts() []string {
	return []string{"a.rtmps.youtube.com", "b.rtmps.youtube.com"}
}

// --- 開発用の疑似の取り込み口（開発・テストの環境でのみ許可。production には存在しない） ---

const (
	DevIngestScheme = "rtmps"
	DevIngestHost   = "fake-ingest"
	DevIngestPort   = 1935
	DevIngestTLS    = "self_signed"
)

// DevIngestAllowedEnvironments は、dev_ingest.allowed_environments を、新しいスライスで返す。
func DevIngestAllowedEnvironments() []string {
	return []string{"development", "test"}
}

// --- 頻度（28.1・7.2） ---

const (
	RateLimitsLoginStartScope                          = "ip"
	RateLimitsLoginStartLimit                          = 30
	RateLimitsLoginStartWindowSeconds                  = 3600
	RateLimitsConnectStartScope                        = "ip"
	RateLimitsConnectStartLimit                        = 30
	RateLimitsConnectStartWindowSeconds                = 3600
	RateLimitsRecheckPerMinuteScope                    = "account"
	RateLimitsRecheckPerMinuteLimit                    = 1
	RateLimitsRecheckPerMinuteWindowSeconds            = 60
	RateLimitsRecheckPerDayScope                       = "account"
	RateLimitsRecheckPerDayLimit                       = 20
	RateLimitsRecheckPerDayWindowSeconds               = 86400
	RateLimitsIntakeScope                              = "account"
	RateLimitsIntakeLimitSetting            SettingKey = SettingKeyIntakeRatePerHour
	RateLimitsIntakeWindowSeconds                      = 3600
)

// --- 保持（20.3） ---

const (
	RetentionYouTubeBroadcastIDDaysAfterEnd = 30
	RetentionHealthSamplesDays              = 30
	RetentionBroadcastEventsDays            = 30
	RetentionRelayTicketDaysAfterExpiry     = 1
	RetentionSessionDaysAfterLastUse        = 30
	RetentionStreamIDDaysAfterLastVerified  = 30
	RetentionChannelTitleMemoryMaxMinutes   = 10
)

// --- 設定の既定値（8 章。bot_score_threshold の 0.5 は仮置き。CLAUDE.md の U4） ---

const (
	SettingDefaultsDailyAllowance          = 1
	SettingDefaultsAttemptLimit            = 3
	SettingDefaultsConcurrentLimit         = 3
	SettingDefaultsTimeLimitMinutes        = 60
	SettingDefaultsIntakeRatePerHour       = 10
	SettingDefaultsMonthlyTransferBudgetGB = 10
	SettingDefaultsDailyQuotaUnits         = 10000
	SettingDefaultsBotScoreThreshold       = 0.5
	SettingDefaultsIntakePaused            = false
)
