# 測定イベントの記録（issue #7。requirements.md 18.2・28.2。src/contracts/enums.json の usage_event_type）。
#
# 内部のアカウント識別子にだけ紐づける。氏名・メールアドレス・チャンネル名・タイトル・IP・端末を特定する文字列を、受け付けない。
# 受け付ける属性を明示的に絞る（record のキーワード引数。余分な属性は ArgumentError。メッセージは、キーの名前だけで、値を含まない）。
# 属性の値も、形を検査する。
#   type            契約の測定イベントの種別 20 種のみ（InvalidEventType）
#   user_id         アカウント識別子（UUID）または nil（ログイン前の出来事・アカウント削除のあと）
#   reason_code     符号 ^[a-z0-9_]{1,32}$（自由記述・デバイス名を受け付けない）
#   bucket          Bucketizer の区分の文字列（数値のまま・任意の文字列を保存しない）
#   browser_class   BrowserClass（系統と対応可否だけ。ユーザーエージェントの文字列を受け付けない）
# 発生の時刻は、引数の時計（clock）から取る。例外のメッセージに、値を含めない。
class UsageRecorder
  # 種別が契約の 20 種でない
  class InvalidEventType < ArgumentError; end

  # 属性の値が、形に合わない（メッセージは、属性の名前だけ）
  class InvalidAttribute < ArgumentError; end

  REASON_CODE_PATTERN = /\A[a-z0-9_]{1,32}\z/
  UUID_PATTERN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  # 実時計で記録する
  def self.record(**attributes)
    new.record(**attributes)
  end

  def initialize(clock: SystemClock.method(:now))
    @clock = clock
  end

  # 測定イベントを 1 件作り、返す
  def record(user_id:, type:, reason_code: nil, bucket: nil, browser_class: nil)
    validate!(user_id: user_id, type: type, reason_code: reason_code, bucket: bucket, browser_class: browser_class)

    UsageEvent.create!(
      user_id: user_id, occurred_at: @clock.call, event_type: type,
      reason_code: reason_code, bucket: bucket, browser_class: browser_class&.to_s
    )
  end

  private

  def validate!(user_id:, type:, reason_code:, bucket:, browser_class:)
    raise InvalidEventType, "type is not one of the usage event types in the contract" unless Contract::UsageEventType.valid?(type)

    invalid!("user_id") unless user_id.nil? || (user_id.is_a?(String) && UUID_PATTERN.match?(user_id))
    invalid!("reason_code") unless reason_code.nil? || (reason_code.is_a?(String) && REASON_CODE_PATTERN.match?(reason_code))
    invalid!("bucket") unless bucket.nil? || Bucketizer.valid_label?(bucket)
    invalid!("browser_class") unless browser_class.nil? || browser_class.is_a?(BrowserClass)
  end

  def invalid!(attribute)
    raise InvalidAttribute, "#{attribute} is invalid"
  end
end
