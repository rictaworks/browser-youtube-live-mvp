# YouTube の窓口（YouTubeGateway。issue #10）のスペックの共通の補助。
#
# 実際の YouTube・Google は呼ばない（WebMock）。API の応答の形（liveBroadcasts・liveStreams・channels・bind・transition・エラー）を、
# 公式の文書（WORK/factcheck/20261007_external-facts.md）に沿って再現する。応答の実物は未確認（U5。最初の実機で採取して合わせる）。
# 値は明らかなダミー。秘密（アクセストークン・配信キー・タイトル・チャンネル名）は、末尾が must-not-appear で、ログ・例外に現れないことの検査に使う。
#
# spec/rails_helper.rb は spec/support を自動では読み込まない。使うスペックは、先頭で
#   require "support/youtube_gateway_support"
# とし、最上位の describe の中で include する。台帳の部品は services/support/ledger_support（LedgerSupport）も include する。
require "rails_helper"
require "support/model_support"
require "support/external_http_support"
require "support/log_capture"
require "services/support/ledger_support"

module YouTubeGatewaySupport
  # 接続と、その接続のアカウントの配信（予約済み）の組
  Account = Struct.new(:connection, :broadcast)

  # --- ダミー値の読み取り口（スペックの本体は、定数を字句の範囲で引くので、メソッドにする） ---

  def api_base
    "https://www.googleapis.com/youtube/v3"
  end

  def access_token_value
    "ya29.dummy-access-token-must-not-appear"
  end

  def stream_key_value
    "dummy-stream-key-must-not-appear"
  end

  def title_value
    "dummy-title-must-not-appear"
  end

  def channel_title_value
    "dummy-channel-title-must-not-appear"
  end

  def youtube_broadcast_id
    "dummybc0001"
  end

  def youtube_stream_id
    "dummy-stream-id-0001"
  end

  def rtmps_url
    "rtmps://a.rtmps.youtube.com:443/live2"
  end

  def api_url(path)
    "#{api_base}/#{path}"
  end

  # --- 応答の形 ---

  def json_response(body, status: 200)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json; charset=UTF-8" } }
  end

  # YouTube のエラー応答（error.errors[].reason に符号が入る）。message は、タイトルなどを含み得るので、ログ・例外に出ないことを検査する
  def error_response(status, reason, message: "dummy-error-message-must-not-appear")
    json_response(
      { "error" => { "code" => status, "message" => message, "errors" => [ { "domain" => "youtube.liveBroadcast", "reason" => reason, "message" => message } ] } },
      status: status
    )
  end

  # liveBroadcasts のリソース
  def broadcast_resource(id: youtube_broadcast_id, life_cycle_status: "created", title: title_value, scheduled_start_time: "2026-10-07T20:01:00Z")
    {
      "kind" => "youtube#liveBroadcast", "id" => id,
      "snippet" => { "title" => title, "scheduledStartTime" => scheduled_start_time, "description" => "dummy-description" },
      "status" => { "lifeCycleStatus" => life_cycle_status, "privacyStatus" => "unlisted" },
      "contentDetails" => { "boundStreamId" => nil }
    }
  end

  # liveStreams のリソース。ingestionAddress は平文の RTMP（使わない）、rtmpsIngestionAddress が RTMPS（使う）、バックアップは使わない
  def stream_resource(id: youtube_stream_id, stream_key: stream_key_value, rtmps: rtmps_url, health: nil)
    ingestion = { "streamName" => stream_key, "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2", "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1" }
    ingestion["rtmpsIngestionAddress"] = rtmps unless rtmps.nil?
    ingestion["rtmpsBackupIngestionAddress"] = "rtmps://b.rtmps.youtube.com:443/live2?backup=1"
    status = { "streamStatus" => "ready" }
    status["healthStatus"] = health if health
    { "kind" => "youtube#liveStream", "id" => id, "cdn" => { "ingestionType" => "rtmp", "ingestionInfo" => ingestion }, "status" => status }
  end

  def list_response(*items)
    json_response({ "kind" => "youtube#listResponse", "items" => items })
  end

  def channel_resource(title: channel_title_value)
    { "kind" => "youtube#channel", "id" => "dummy-channel-id", "snippet" => { "title" => title } }
  end

  # --- 窓口の組み立て ---

  # token_vault は、アクセストークンを返すもの。clock は now から始まり、呼び出しのたびに 1 ミリ秒進む（台帳の明細を、呼び出しの順に並べるため。
  # 最初の呼び出しの時刻は now ちょうど）。環境は、既定で本番（疑似の取り込み口を許さない）
  def build_gateway(vault:, now:, environment: AppEnvironment.new("production"), http: ExternalHttp.new)
    YouTubeGateway.new(
      http: http, token_vault: vault, api_base: api_base, stream_title: "Browser Live", environment: environment,
      clock: ticking_clock(now), logger: Rails.logger
    )
  end

  def ticking_clock(now)
    ticks = 0
    lambda do
      value = now + Rational(ticks, 1000)
      ticks += 1
      value
    end
  end

  def token_vault_double
    instance_double(TokenVault, access_token: access_token_value, forget_access_token: nil)
  end

  # 台帳へ予約済みの配信と、そのアカウントの YouTube 接続を用意する。user を省くと、新しいアカウント。
  # daily_total は 1 日の割り当て（既定は設定の既定値。配信に使える上限があるので、1 日に予約できるのは 16 本まで）。
  # 配信を多数作るスペックは、大きい値を渡す
  def ledger_account(quota_date:, user: nil, daily_total: nil)
    owner = user || create(:user)
    options = daily_total ? { daily_total: daily_total } : {}
    [ owner, create(:youtube_connection, user: owner), create_reserved_broadcast(quota_date: quota_date, user: owner, **options) ]
  end

  # 台帳の明細（呼び出しの順）
  def ledger_entries
    QuotaEntry.order(:called_at).map { |entry| [ entry.method, entry.units, entry.bucket, entry.result ] }
  end

  # WebMock で、YouTube への要求が 1 件も送られていない
  def expect_no_youtube_request
    expect(a_request(:any, %r{\Ahttps://www\.googleapis\.com/youtube/v3/})).not_to have_been_made
  end
end
