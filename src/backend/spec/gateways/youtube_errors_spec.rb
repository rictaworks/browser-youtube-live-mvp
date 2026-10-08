require "rails_helper"

# YouTube・Google の応答のエラー分類（issue #10。requirements.md 10.6・10.5・10.4）。
#   error.errors[].reason（エラーの理由の符号）の表引きで、型付きの例外へ分類する（HTTP ステータスや種別だけでは誤る。403 が兼ねる）。
#   表に無い reason は UnexpectedResponse（黙って成功にしない。特定の失敗にもしない）。
#   各例外に disposition（接続状態の更新・終了理由・再試行の可否・清算の結果）を持たせ、呼び出し側が表引きできるようにする。
#   トークン・配信キー・タイトルを、例外のメッセージ・inspect に出さない。
RSpec.describe YouTubeErrors do
  def error_payload(*reasons, message: "dummy-error-message")
    {
      "error" => {
        "code" => 403, "message" => message,
        "errors" => reasons.map { |reason| { "domain" => "youtube.liveBroadcast", "reason" => reason, "message" => message } }
      }
    }
  end

  def classify(status: 403, payload: nil, call_kind: :insert_broadcast)
    described_class.classify(status: status, payload: payload, call_kind: call_kind)
  end

  # issue #10 の分類の表（reason -> 例外クラス）。実装の表とは別に、ここへ書き写して固定する
  reason_table = {
    "liveStreamingNotEnabled" => YouTubeErrors::LiveNotEnabled,
    "livePermissionBlocked" => YouTubeErrors::LiveStreamingRestricted,
    "channelClosed" => YouTubeErrors::LiveStreamingRestricted,
    "channelSuspended" => YouTubeErrors::LiveStreamingRestricted,
    "authenticatedUserAccountClosed" => YouTubeErrors::LiveStreamingRestricted,
    "authenticatedUserAccountSuspended" => YouTubeErrors::LiveStreamingRestricted,
    "insufficientLivePermissions" => YouTubeErrors::InsufficientPermissions,
    "insufficientPermissions" => YouTubeErrors::InsufficientPermissions,
    "forbidden" => YouTubeErrors::InsufficientPermissions,
    "invalid_grant" => YouTubeErrors::TokenRevoked,
    "userBroadcastsExceedLimit" => YouTubeErrors::BroadcastLimitExceeded,
    "concurrentBroadcastsExceedLimit" => YouTubeErrors::BroadcastLimitExceeded,
    "sharedIngestionBroadcastsExceedLimit" => YouTubeErrors::BroadcastLimitExceeded,
    "quotaExceeded" => YouTubeErrors::QuotaExceeded,
    "dailyLimitExceeded" => YouTubeErrors::QuotaExceeded,
    "userRequestsExceedRateLimit" => YouTubeErrors::RateLimited,
    "rateLimitExceeded" => YouTubeErrors::RateLimited,
    "userRateLimitExceeded" => YouTubeErrors::RateLimited,
    "liveBroadcastNotFound" => YouTubeErrors::NotFound,
    "liveStreamNotFound" => YouTubeErrors::NotFound,
    "redundantTransition" => YouTubeErrors::AlreadyTerminal,
    "invalidTransition" => YouTubeErrors::NotAllowed,
    "errorStreamInactive" => YouTubeErrors::NotAllowed,
    "liveBroadcastDeletionNotAllowed" => YouTubeErrors::NotAllowed,
    "liveStreamDeletionNotAllowed" => YouTubeErrors::NotAllowed,
    "liveBroadcastBindingNotAllowed" => YouTubeErrors::NotAllowed,
    "channelNotFound" => YouTubeErrors::NoChannel,
    "youtubeSignupRequired" => YouTubeErrors::NoChannel
  }

  describe ".classify（reason の表引き）" do
    reason_table.each do |reason, error_class|
      it "reason #{reason} は #{error_class.name.demodulize}" do
        error = classify(payload: error_payload(reason))

        expect(error).to be_instance_of(error_class)
        expect(error.reason).to eq(reason)
        expect(error.status).to eq(403)
        expect(error.call_kind).to eq(:insert_broadcast)
      end
    end

    it "表は、issue の分類のすべての reason を持つ（実装の表と、ここの表が一致する）" do
      expect(described_class::REASON_CLASSES).to eq(reason_table)
    end

    it "HTTP ステータスが同じ 403 でも、reason で分ける（403 は権限・割り当て・遷移不可・上限を兼ねる）" do
      classes = %w[ forbidden quotaExceeded invalidTransition userBroadcastsExceedLimit liveStreamingNotEnabled ].map do |reason|
        classify(status: 403, payload: error_payload(reason)).class
      end

      expect(classes.uniq.size).to eq(5)
    end

    it "concurrentBroadcastsExceedLimit・sharedIngestionBroadcastsExceedLimit は、種別が rateLimitExceeded でも RateLimited にしない（再試行で解消しない上限）" do
      payload = {
        "error" => {
          "code" => 403, "message" => "dummy",
          "errors" => [ { "domain" => "youtube.liveBroadcast", "reason" => "concurrentBroadcastsExceedLimit", "message" => "dummy" } ],
          "status" => "rateLimitExceeded"
        }
      }

      error = classify(payload: payload)

      expect(error).to be_instance_of(YouTubeErrors::BroadcastLimitExceeded)
      expect(error.disposition.retryable).to be(false)
    end

    it "errors が複数あれば、表にある最初の reason で分類する（先頭が未知でも、あとの既知を拾う）" do
      error = classify(payload: error_payload("somethingNew", "liveStreamingNotEnabled"))

      expect(error).to be_instance_of(YouTubeErrors::LiveNotEnabled)
      expect(error.reason).to eq("liveStreamingNotEnabled")
    end

    it "OAuth のトークンエンドポイントの形（error が文字列）の invalid_grant は TokenRevoked" do
      error = classify(status: 400, payload: { "error" => "invalid_grant", "error_description" => "dummy" }, call_kind: :token_refresh)

      expect(error).to be_instance_of(YouTubeErrors::TokenRevoked)
      expect(error.reason).to eq("invalid_grant")
    end
  end

  describe ".classify（ステータスの規則と、未知の reason）" do
    it "未知の reason は UnexpectedResponse（黙って成功にしない。特定の失敗にもしない）。reason は記録する" do
      error = classify(status: 403, payload: error_payload("someNewReason"))

      expect(error).to be_instance_of(YouTubeErrors::UnexpectedResponse)
      expect(error.reason).to eq("someNewReason")
    end

    it "reason が無い 400・401・403 は UnexpectedResponse" do
      [ 400, 401, 403, 409, 418 ].each do |status|
        expect(classify(status: status, payload: nil)).to be_instance_of(YouTubeErrors::UnexpectedResponse)
        expect(classify(status: status, payload: {})).to be_instance_of(YouTubeErrors::UnexpectedResponse)
      end
    end

    it "404 は NotFound（reason が表に無くても、無くても）" do
      expect(classify(status: 404, payload: nil)).to be_instance_of(YouTubeErrors::NotFound)
      expect(classify(status: 404, payload: error_payload("notFound"))).to be_instance_of(YouTubeErrors::NotFound)
    end

    it "429 は RateLimited、5xx は Transient（reason が表に無いとき）" do
      expect(classify(status: 429, payload: nil)).to be_instance_of(YouTubeErrors::RateLimited)
      [ 500, 502, 503, 504, 599 ].each do |status|
        expect(classify(status: status, payload: nil)).to be_instance_of(YouTubeErrors::Transient)
        expect(classify(status: status, payload: error_payload("backendError"))).to be_instance_of(YouTubeErrors::Transient)
      end
    end

    it "reason が表にあれば、ステータスより reason を優先する（404 でも reason が quotaExceeded なら QuotaExceeded）" do
      expect(classify(status: 404, payload: error_payload("quotaExceeded"))).to be_instance_of(YouTubeErrors::QuotaExceeded)
      expect(classify(status: 500, payload: error_payload("liveStreamingNotEnabled"))).to be_instance_of(YouTubeErrors::LiveNotEnabled)
    end

    it "応答の本文が、解釈できない形（配列・文字列・errors が配列でない・要素がオブジェクトでない）でも、例外にせず、ステータスの規則へ回す" do
      [ [], "text", 1, { "error" => [] }, { "error" => { "errors" => "x" } }, { "error" => { "errors" => [ "x", 1, nil ] } } ].each do |payload|
        expect(classify(status: 403, payload: payload)).to be_instance_of(YouTubeErrors::UnexpectedResponse)
        expect(classify(status: 503, payload: payload)).to be_instance_of(YouTubeErrors::Transient)
      end
    end

    it "符号の形でない reason（空白・改行・長すぎる・文字列でない）は、メッセージにも reason にも出さない（unrecognized）" do
      hostile = [ "dummy title with spaces", "line\nbreak", "a" * 200, "", "<script>", "日本語の理由" ]
      hostile.each do |reason|
        error = classify(status: 403, payload: error_payload(reason))

        expect(error).to be_instance_of(YouTubeErrors::UnexpectedResponse)
        expect(error.reason).to eq("unrecognized")
        expect(error.message).not_to include(reason) unless reason.empty?
      end
      expect(classify(status: 403, payload: error_payload(1, nil))).to be_instance_of(YouTubeErrors::UnexpectedResponse)
    end

    it "status は整数、call_kind はシンボルまたは nil だけ（それ以外は ArgumentError）" do
      expect { described_class.classify(status: "403", payload: nil, call_kind: :bind) }.to raise_error(ArgumentError, /status/)
      expect { described_class.classify(status: 403, payload: nil, call_kind: "bind") }.to raise_error(ArgumentError, /call_kind/)
    end
  end

  describe "例外のメッセージと inspect（機密を出さない）" do
    it "メッセージは、クラス・呼び出し・ステータス・reason の符号だけ。応答の message（タイトルなどを含み得る）を含めない" do
      payload = error_payload("liveStreamingNotEnabled", message: "dummy-title-must-not-appear")

      error = classify(payload: payload)

      expect(error.message).to eq("youtube_error class=LiveNotEnabled call=insert_broadcast status=403 reason=liveStreamingNotEnabled")
      expect(error.inspect).not_to include("dummy-title-must-not-appear")
      expect(error.full_message).not_to include("dummy-title-must-not-appear")
    end

    it "未知の reason でも、メッセージに応答の本文を含めない" do
      error = classify(payload: error_payload("someNewReason", message: "dummy-stream-key-must-not-appear"))

      expect(error.message).to eq("youtube_error class=UnexpectedResponse call=insert_broadcast status=403 reason=someNewReason")
    end

    it "cause や detail を渡しても、機密になり得る任意の文字列は載せない（detail は符号だけ）" do
      error = YouTubeErrors::UnexpectedResponse.new(call_kind: :ensure_stream, detail: :missing_ingestion_address)

      expect(error.message).to eq("youtube_error class=UnexpectedResponse call=ensure_stream detail=missing_ingestion_address")
      expect { YouTubeErrors::UnexpectedResponse.new(detail: "free text with spaces") }.to raise_error(ArgumentError, /detail/)
    end

    it "QuotaInsufficient は、枠の名前（prep・settle・common）を持つ。HTTP は呼ばれていないので、ステータスは無い" do
      error = YouTubeErrors::QuotaInsufficient.new(call_kind: :insert_broadcast, bucket: :prep)

      expect(error.bucket).to eq(:prep)
      expect(error.status).to be_nil
      expect(error.message).to eq("youtube_error class=QuotaInsufficient call=insert_broadcast bucket=prep")
      expect { YouTubeErrors::QuotaInsufficient.new(call_kind: :bind, bucket: :other) }.to raise_error(ArgumentError, /bucket/)
    end
  end

  # 10.6 の「動作」。実装とは別に、ここへ書き写して固定する: [接続状態, 終了理由, 再試行できるか, 清算の結果]
  disposition_table = {
    YouTubeErrors::LiveNotEnabled => [ "live_not_enabled", "prepare_failed", false, :failed ],
    YouTubeErrors::LiveStreamingRestricted => [ "live_not_enabled", "prepare_failed", false, :failed ],
    YouTubeErrors::InsufficientPermissions => [ "revoked", "authorization_revoked", false, :forbidden ],
    YouTubeErrors::TokenRevoked => [ "revoked", "authorization_revoked", false, :failed ],
    YouTubeErrors::BroadcastLimitExceeded => [ nil, "prepare_failed", false, :failed ],
    YouTubeErrors::QuotaExceeded => [ nil, "prepare_failed", false, :failed ],
    YouTubeErrors::QuotaInsufficient => [ nil, "prepare_failed", false, :failed ],
    YouTubeErrors::RateLimited => [ nil, "prepare_failed", true, :failed ],
    YouTubeErrors::Transient => [ nil, "prepare_failed", true, :failed ],
    YouTubeErrors::Timeout => [ nil, "prepare_failed", true, :failed ],
    YouTubeErrors::TokenTemporarilyUnavailable => [ nil, "prepare_failed", true, :failed ],
    YouTubeErrors::NotFound => [ nil, nil, false, :not_found ],
    YouTubeErrors::AlreadyTerminal => [ nil, nil, false, :already_terminal ],
    YouTubeErrors::NotAllowed => [ nil, "prepare_failed", false, :not_transitionable ],
    YouTubeErrors::NoChannel => [ nil, nil, false, :failed ],
    YouTubeErrors::UnexpectedResponse => [ nil, "prepare_failed", false, :failed ]
  }

  describe "#disposition（呼び出し側が表引きする動作）" do
    disposition_table.each do |error_class, (state, end_reason, retryable, settlement)|
      it "#{error_class.name.demodulize}: 接続状態=#{state.inspect}・終了理由=#{end_reason.inspect}・再試行=#{retryable}・清算=#{settlement}" do
        disposition = error_class.new.disposition

        expect(disposition.connection_state).to eq(state)
        expect(disposition.end_reason).to eq(end_reason)
        expect(disposition.retryable).to eq(retryable)
        expect(disposition.settlement_result).to eq(settlement)
        expect(disposition).to be_frozen
      end
    end

    it "すべての型付きの例外が、表にある（表に無い例外の追加を、検出する）" do
      defined_classes = described_class.constants.map { |name| described_class.const_get(name) }
                                       .select { |value| value.is_a?(Class) && value < described_class::Base }

      expect(defined_classes).to match_array(disposition_table.keys)
    end

    it "値は、契約の列挙（接続状態・終了理由）と、清算の結果（SettlementRules::RESULTS の失敗系）の中にある" do
      disposition_table.each_value do |state, end_reason, _retryable, settlement|
        expect([ nil, Contract::YoutubeConnectionState::LIVE_NOT_ENABLED, Contract::YoutubeConnectionState::REVOKED ]).to include(state)
        expect([ nil ] + Contract::EndReason::ALL).to include(end_reason)
        expect(SettlementRules::RESULTS - [ :success ]).to include(settlement)
      end
    end

    it "終了理由は、認可の失敗が authorization_revoked、それ以外が prepare_failed（10.6）" do
      authorization = disposition_table.select { |_, (_, end_reason)| end_reason == "authorization_revoked" }.keys

      expect(authorization).to contain_exactly(YouTubeErrors::InsufficientPermissions, YouTubeErrors::TokenRevoked)
    end

    it "再試行できるのは、要求が多すぎる・一時的な失敗・タイムアウト（トークン更新の一時的な失敗を含む）だけ" do
      retryable = disposition_table.select { |_, (_, _, can_retry)| can_retry }.keys

      expect(retryable).to contain_exactly(
        YouTubeErrors::RateLimited, YouTubeErrors::Transient, YouTubeErrors::Timeout, YouTubeErrors::TokenTemporarilyUnavailable
      )
    end

    it "retryable? は、disposition の再試行の可否と同じ" do
      expect(YouTubeErrors::Transient.new.retryable?).to be(true)
      expect(YouTubeErrors::NotAllowed.new.retryable?).to be(false)
    end

    it "先行配信の清算（context: :prior_settlement）での権限の応答は、認可失効にしない（接続状態を変えず、終了理由も求めない。10.5）" do
      permission = YouTubeErrors::InsufficientPermissions.new(status: 403, reason: "forbidden")

      default = permission.disposition
      prior = permission.disposition(context: :prior_settlement)

      expect(default.connection_state).to eq("revoked")
      expect(prior.connection_state).to be_nil
      expect(prior.end_reason).to be_nil
      expect(prior.settlement_result).to eq(:forbidden)
    end

    it "context が違っても、ほかの例外の動作は変わらない。トークンの失効は、先行配信の清算でも認可失効" do
      disposition_table.each_key do |error_class|
        next if error_class == YouTubeErrors::InsufficientPermissions

        expect(error_class.new.disposition(context: :prior_settlement)).to eq(error_class.new.disposition)
      end
      expect(YouTubeErrors::TokenRevoked.new.disposition(context: :prior_settlement).connection_state).to eq("revoked")
    end

    it "context が nil と :default は同じ。未知の context は ArgumentError（黙って既定に倒さない）" do
      error = YouTubeErrors::NotFound.new

      expect(error.disposition(context: nil)).to eq(error.disposition(context: :default))
      expect { error.disposition(context: :other) }.to raise_error(ArgumentError, /context/)
    end
  end

  describe "清算の結果（Domain Core の SettlementRules）との整合" do
    it "SettlementRules.result_for_error の表にある reason は、同じ清算の結果へ写る（#13 が result_for_error を外すまでの、二重の表の食い違いを検出する）" do
      SettlementRules::ERROR_REASON_RESULTS.each do |reason, expected|
        error = classify(payload: error_payload(reason))

        expect(error.disposition.settlement_result).to eq(expected), "reason #{reason}: #{error.disposition.settlement_result} != #{expected}"
      end
    end

    it "表に無い reason は、SettlementRules でも failed。未知の reason（UnexpectedResponse）の清算の結果も failed（清算済みにしない）" do
      expect(SettlementRules.result_for_error(reason: "someNewReason")).to eq(:failed)
      expect(classify(payload: error_payload("someNewReason")).disposition.settlement_result).to eq(:failed)
    end

    it "清算の結果が success になる例外は無い（失敗の分類だけを持つ）" do
      expect(disposition_table.values.map(&:last)).not_to include(:success)
    end
  end

  describe "型の階層" do
    it "すべて YouTubeErrors::Base（StandardError）の子。TokenTemporarilyUnavailable は Transient の一種（再試行の扱いが同じ）" do
      disposition_table.each_key { |error_class| expect(error_class.ancestors).to include(described_class::Base, StandardError) }
      expect(YouTubeErrors::TokenTemporarilyUnavailable.ancestors).to include(YouTubeErrors::Transient)
    end
  end
end
