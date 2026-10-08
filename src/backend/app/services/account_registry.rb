require "openssl"

# アカウントの登録と、削除直後の再登録の保留（issue #8。requirements.md 7.1・7.4・28.2）。
#
#   find_or_register(google_sub:, now:)  Google の sub でアカウントを特定する。
#       :existing  登録済み（保留の行が残っていても、既存のアカウントを締め出さない）
#       :created   未登録。アカウントを作る（保持するのは sub・作成時刻・最終ログイン時刻だけ。メール・氏名・プロフィールは取得しない）
#       :held      削除から間もない（削除時点の利用日の終わりまで）。アカウントを作らない
#   record_hold(google_sub:, now:)       アカウントの削除時に、#16 が呼ぶ。sub の要約値と、削除時点の利用日を記録する
#   release_expired(now:)                利用日の終わりを過ぎた保留を消去する（#15 の保持期間の適用が呼ぶ。requirements.md 20.3・29.3）
#
# 保留（deletion_holds）が持つのは、sub の要約値（HMAC-SHA256。鍵は SESSION_SECRET から用途ごとに導出）と、その利用日だけ。
# 要約値から sub は復元できない。その利用日の終わり（次の JST 03:00）まで、同じ Google アカウントの再登録を受け付けない
# （削除と再登録の繰り返しによる利用枠の再取得を防ぐ）。利用日は UsageCalendar で算出する（定期ジョブに頼らない）。
# 時刻は引数 now で受け取る（実時計を読まない）。sub・要約値を、ログ・inspect に出さない。
class AccountRegistry
  KEY_PURPOSE = "deletion_hold_sub".freeze
  # Google の sub は、最大 255 文字の ASCII（表示できる文字）
  SUB_PATTERN = /\A[\x21-\x7E]{1,255}\z/

  # 登録の結果。outcome は :existing・:created・:held。user は :held のとき nil
  Registration = Data.define(:outcome, :user) do
    def existing?
      outcome == :existing
    end

    def created?
      outcome == :created
    end

    def held?
      outcome == :held
    end

    # 結果の符号（:existing・:created・:held）とも、== で比較できる（registry.find_or_register(...) == :held）
    def ==(other)
      other.is_a?(Symbol) ? outcome == other : super
    end
  end

  def initialize(secret: Rails.application.secret_key_base)
    @key = DerivedKeys.new(secret: secret).derive(KEY_PURPOSE)
  end

  # sub のアカウントを返す（無ければ作る。保留中なら作らない）
  def find_or_register(google_sub:, now:)
    check_sub!(google_sub)
    check_time!(now)

    user = User.find_by(google_sub: google_sub)
    return Registration.new(outcome: :existing, user: user) if user
    return Registration.new(outcome: :held, user: nil) if held?(google_sub, now)

    register(google_sub, now)
  end

  # 削除したアカウントの sub を、削除時点の利用日の終わりまで保留する。保留の利用日（Date）を返す
  def record_hold(google_sub:, now:)
    check_sub!(google_sub)
    check_time!(now)

    usage_date = UsageCalendar.usage_date(now)
    DeletionHold.upsert({ sub_digest: digest(google_sub), hold_usage_date: usage_date })
    usage_date
  end

  # 利用日の終わりを過ぎた保留を消去する。消去した件数を返す
  def release_expired(now:)
    check_time!(now)

    DeletionHold.where("hold_usage_date < ?", UsageCalendar.usage_date(now)).delete_all
  end

  # sub の要約値（HMAC-SHA256 の 16 進 64 文字）。sub を復元できない
  def digest(google_sub)
    check_sub!(google_sub)

    OpenSSL::HMAC.hexdigest("SHA256", @key, google_sub)
  end

  # 鍵・要約値を出さない
  def inspect
    "#<#{self.class.name}>"
  end

  private

  # now の利用日が、保留の利用日以前（保留の利用日の終わりまで）
  def held?(google_sub, now)
    DeletionHold.where(sub_digest: digest(google_sub)).where("hold_usage_date >= ?", UsageCalendar.usage_date(now)).exists?
  end

  # アカウントを作る。同時の最初のログインで、同じ sub が先に作られていたら（一意制約）、その行を使う。
  # 失敗した INSERT が、外側のトランザクションを壊さないよう、セーブポイントで包む
  def register(google_sub, now)
    user = User.transaction(requires_new: true) { User.create!(google_sub: google_sub, created_at: now, last_login_at: now) }
    Registration.new(outcome: :created, user: user)
  rescue ActiveRecord::RecordNotUnique
    Registration.new(outcome: :existing, user: User.find_by!(google_sub: google_sub))
  end

  def check_sub!(google_sub)
    raise ArgumentError, "google_sub must be an ASCII String of 1 to 255 printable characters" unless google_sub.is_a?(String) && SUB_PATTERN.match?(google_sub)
  end

  def check_time!(now)
    raise ArgumentError, "now must be a Time" unless now.is_a?(Time)
  end
end
