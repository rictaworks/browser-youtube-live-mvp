package contract

// RetryAtRule は、受付の拒否の retry_at（再試行の目安時刻）の決め方（src/contracts/http-rejections.json）。
type RetryAtRule string

const (
	RetryAtRuleNone              RetryAtRule = "none"
	RetryAtRuleRateLimitWindow   RetryAtRule = "rate_limit_window"
	RetryAtRuleNextUsageDayStart RetryAtRule = "next_usage_day_start"
	RetryAtRuleNextMonthStart    RetryAtRule = "next_month_start"
	RetryAtRuleNextQuotaDayStart RetryAtRule = "next_quota_day_start"
)

// RetryAtRuleValues は、規則の全値を、契約の順に返す（新しいスライス）。
func RetryAtRuleValues() []RetryAtRule {
	return []RetryAtRule{
		RetryAtRuleNone,
		RetryAtRuleRateLimitWindow,
		RetryAtRuleNextUsageDayStart,
		RetryAtRuleNextMonthStart,
		RetryAtRuleNextQuotaDayStart,
	}
}

// Valid は、v が契約の規則なら true を返す。
func (v RetryAtRule) Valid() bool {
	switch v {
	case RetryAtRuleNone, RetryAtRuleRateLimitWindow, RetryAtRuleNextUsageDayStart, RetryAtRuleNextMonthStart, RetryAtRuleNextQuotaDayStart:
		return true
	}
	return false
}

// HTTPRejection は、受付の拒否理由ごとの、判定の順・HTTP ステータス・区分・retry_at の規則。
type HTTPRejection struct {
	// Order は、9.2 の判定順（0〜13）
	Order       int
	HTTPStatus  int
	Resolution  Resolution
	RetryAtRule RetryAtRule
}

// HTTPRejectionOf は、拒否理由の HTTPRejection を返す。未知の拒否理由は、零値と false。
func HTTPRejectionOf(reason RejectionReason) (HTTPRejection, bool) {
	switch reason {
	case RejectionReasonInvalidInput:
		return HTTPRejection{
			Order:       0,
			HTTPStatus:  422,
			Resolution:  ResolutionFixInput,
			RetryAtRule: RetryAtRuleNone,
		}, true
	case RejectionReasonNotLoggedIn:
		return HTTPRejection{
			Order:       1,
			HTTPStatus:  401,
			Resolution:  ResolutionLogIn,
			RetryAtRule: RetryAtRuleNone,
		}, true
	case RejectionReasonRateLimited:
		return HTTPRejection{
			Order:       2,
			HTTPStatus:  429,
			Resolution:  ResolutionWait,
			RetryAtRule: RetryAtRuleRateLimitWindow,
		}, true
	case RejectionReasonBotCheckFailed:
		return HTTPRejection{
			Order:       3,
			HTTPStatus:  403,
			Resolution:  ResolutionWait,
			RetryAtRule: RetryAtRuleNone,
		}, true
	case RejectionReasonBroadcastInProgress:
		return HTTPRejection{
			Order:       4,
			HTTPStatus:  409,
			Resolution:  ResolutionStopFirst,
			RetryAtRule: RetryAtRuleNone,
		}, true
	case RejectionReasonYouTubeNotConnected:
		return HTTPRejection{
			Order:       5,
			HTTPStatus:  409,
			Resolution:  ResolutionConnect,
			RetryAtRule: RetryAtRuleNone,
		}, true
	case RejectionReasonAuthorizationRevoked:
		return HTTPRejection{
			Order:       6,
			HTTPStatus:  409,
			Resolution:  ResolutionReconnect,
			RetryAtRule: RetryAtRuleNone,
		}, true
	case RejectionReasonLiveNotEnabled:
		return HTTPRejection{
			Order:       7,
			HTTPStatus:  409,
			Resolution:  ResolutionEnableLive,
			RetryAtRule: RetryAtRuleNone,
		}, true
	case RejectionReasonAllowanceConsumed:
		return HTTPRejection{
			Order:       8,
			HTTPStatus:  409,
			Resolution:  ResolutionNextUsageDay,
			RetryAtRule: RetryAtRuleNextUsageDayStart,
		}, true
	case RejectionReasonAttemptsExhausted:
		return HTTPRejection{
			Order:       9,
			HTTPStatus:  409,
			Resolution:  ResolutionNextUsageDay,
			RetryAtRule: RetryAtRuleNextUsageDayStart,
		}, true
	case RejectionReasonIntakePaused:
		return HTTPRejection{
			Order:       10,
			HTTPStatus:  503,
			Resolution:  ResolutionAfterRelease,
			RetryAtRule: RetryAtRuleNone,
		}, true
	case RejectionReasonTransferBudgetExceeded:
		return HTTPRejection{
			Order:       11,
			HTTPStatus:  503,
			Resolution:  ResolutionNextMonth,
			RetryAtRule: RetryAtRuleNextMonthStart,
		}, true
	case RejectionReasonCapacityFull:
		return HTTPRejection{
			Order:       12,
			HTTPStatus:  503,
			Resolution:  ResolutionWait,
			RetryAtRule: RetryAtRuleNone,
		}, true
	case RejectionReasonQuotaInsufficient:
		return HTTPRejection{
			Order:       13,
			HTTPStatus:  503,
			Resolution:  ResolutionNextQuotaDay,
			RetryAtRule: RetryAtRuleNextQuotaDayStart,
		}, true
	}
	return HTTPRejection{}, false
}
