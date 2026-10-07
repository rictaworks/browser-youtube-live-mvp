require "digest"

# サーバー側のセッション（issue #7。requirements.md 7.1・20.3・28.1。src/contracts/http-api.md 1.3）。
#
#   発行      乱数 32 バイトの URL 安全な文字列（Cookie bl_session の値）。要約値（SHA-256）だけを sessions.token_digest に保存する
#             （識別子そのものは、DB に残さない）
#   検索      有効なセッションだけを返す（破棄済み・期限切れは nil）。読み取りだけで、書き込まない
#   最終利用の更新  last_used_at と expires_at（最終利用から 30 日）を、1 つの UPDATE 文で更新する
#   破棄      sessions の行を消す（ログアウト・アカウントの削除・セッション固定化の防止のための入れ替え）
#
# 時刻は、引数で受け取る（実時計を読まない）。Rails 標準のセッション（Cookie ストア）は使わない。
#
# 検索（find）は、アカウントを特定する前の処理（セッションの識別子から、アカウントを得る）なので、owned_by を経由できない。
# token_digest の一意索引で、1 件に決まる。それ以外（更新・破棄）は、セッションのアカウントで絞り込む（OwnerScope）。
class SessionStore
  # 有効期間（最終利用から）。契約の保持期間（retention.session_days_after_last_use）
  LIFETIME = Contract::Limits::RETENTION.fetch("session_days_after_last_use").days

  TOKEN_BYTES = 32
  # 乱数 32 バイトの base64url（パディングなし）は 43 文字
  TOKEN_FORMAT = /\A[A-Za-z0-9_-]{43}\z/

  Issued = Data.define(:token, :session)

  # セッションの識別子（token）の要約値（SHA-256 の 16 進）
  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end

  # 新しいセッションを発行する。user は保存済みのアカウント
  def issue(user:, now:)
    raise ArgumentError, "user must be a persisted User" unless user.is_a?(User) && user.persisted?

    ensure_time!(now)

    token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
    session = Session.create!(
      user: user, token_digest: self.class.digest(token), created_at: now, last_used_at: now, expires_at: now + LIFETIME
    )
    Issued.new(token: token, session: session)
  end

  # 有効なセッションを返す。形が違う token は、DB を引かずに nil。期限の瞬間（expires_at と同じ）から、無効。
  def find(token, now:)
    ensure_time!(now)
    return nil unless token.is_a?(String) && token.valid_encoding? && TOKEN_FORMAT.match?(token)

    session = Session.find_by(token_digest: self.class.digest(token))
    return nil if session.nil? || session.expires_at <= now

    session
  end

  # 最終利用を更新する（last_used_at = now・expires_at = now + 30 日）。破棄済みのセッションには、何も起こさない。
  def touch(session, now:)
    ensure_time!(now)

    owned(session).update_all(last_used_at: now, expires_at: now + LIFETIME)
    nil
  end

  # セッションを破棄する。すでに無ければ、何もしない（冪等）
  def revoke(session)
    owned(session).delete_all
    nil
  end

  # アカウントのすべてのセッションを破棄する。破棄した件数を返す
  def revoke_all(user)
    Session.owned_by(user).delete_all
  end

  private

  def owned(session)
    Session.owned_by(session.user_id).where(id: session.id)
  end

  def ensure_time!(now)
    raise ArgumentError, "now must be a Time" unless now.is_a?(Time)
  end
end
