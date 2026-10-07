require "rails_helper"
require "support/api_helpers"

# セッション（Cookie bl_session。サーバー側に保持）での認証（issue #7。requirements.md 7.1・20.3。src/contracts/http-api.md 1.3）。
# 現在のアカウントは、セッションからだけ得る。破棄済み・期限切れのセッションは無効。有効期限は、最終利用から 30 日。
RSpec.describe "セッションでの認証", type: :request do
  include ApiHelpers
  include ActiveSupport::Testing::TimeHelpers
  include_context "API の環境"

  let(:user) { create(:user) }
  let(:body) { { event_type: "watch_url_copied" } }

  describe "ログイン済みの判定" do
    it "有効なセッションの Cookie があれば、ログイン済み（アカウントは、セッションのもの）" do
      signed_in = sign_in(user)

      api_post "/api/usage-events", body, signed_in: signed_in

      expect(response).to have_http_status(204)
      expect(UsageEvent.last.user_id).to eq(user.id)
    end

    it "Cookie が無ければ、ログインしていない（401）" do
      api_post "/api/usage-events", body

      expect(response).to have_http_status(401)
    end

    it "アカウントは、セッションからだけ得る（本文・ヘッダ・クエリで、別のアカウントを名乗れない）" do
      signed_in = sign_in(user)
      other = create(:user)

      post "/api/usage-events?user_id=#{other.id}",
           params: JSON.generate(body.merge(user_id: other.id)),
           headers: api_headers(signed_in: signed_in, state_changing: true).merge(
             "Content-Type" => "application/json", "X-User-Id" => other.id, "X-Account-Id" => other.id
           ),
           env: public_listener_env

      expect(response).to have_http_status(204)
      expect(UsageEvent.last.user_id).to eq(user.id)
    end

    it "未知の token の Cookie は、ログインしていない扱い（401）。例外にならない" do
      api_post "/api/usage-events", body, headers: { "Cookie" => "#{SessionCookie::NAME}=#{SecureRandom.urlsafe_base64(32)}" }

      expect(response).to have_http_status(401)
    end

    it "セッションの要約値（DB に保存した値）そのものを、Cookie に入れても、ログインできない" do
      signed_in = sign_in(user)
      digest = signed_in.session.token_digest

      api_post "/api/usage-events", body, headers: { "Cookie" => "#{SessionCookie::NAME}=#{digest}" }

      expect(response).to have_http_status(401)
    end

    it "Cookie の名前は bl_session だけ（Rails 標準のセッションの Cookie では、認証しない）" do
      signed_in = sign_in(user)

      api_post "/api/usage-events", body, headers: { "Cookie" => "_session_id=#{signed_in.token}; _backend_session=#{signed_in.token}; session=#{signed_in.token}" }

      expect(response).to have_http_status(401)
    end

    it "Authorization ヘッダの token では、認証しない（Cookie のセッションだけ）" do
      signed_in = sign_in(user)

      api_post "/api/usage-events", body, headers: { "Authorization" => "Bearer #{signed_in.token}" }

      expect(response).to have_http_status(401)
    end
  end

  describe "セッションの無効" do
    it "破棄したセッションは、無効（401）" do
      signed_in = sign_in(user)
      SessionStore.new.revoke(signed_in.session)

      api_post "/api/usage-events", body, signed_in: signed_in

      expect(response).to have_http_status(401)
    end

    it "期限切れ（最終利用から 30 日）のセッションは、無効（401）。要求で、よみがえらない" do
      now = Time.utc(2026, 10, 7, 4, 30, 0)
      signed_in = sign_in(user, now: now)

      travel_to(now + 30.days) { api_post "/api/usage-events", body, signed_in: signed_in }

      expect(response).to have_http_status(401)
      expect(Session.find(signed_in.session.id).last_used_at).to eq(now)
      expect(UsageEvent.count).to eq(0)
    end

    it "期限の 1 秒前は、有効" do
      now = Time.utc(2026, 10, 7, 4, 30, 0)
      signed_in = sign_in(user, now: now)

      travel_to(now + 30.days - 1.second) { api_post "/api/usage-events", body, signed_in: signed_in }

      expect(response).to have_http_status(204)
    end

    it "アカウントが削除されたあとは、セッションも無い（連鎖削除）ので、401" do
      signed_in = sign_in(user)
      User.find(user.id).destroy!

      api_post "/api/usage-events", body, signed_in: signed_in

      expect(response).to have_http_status(401)
    end
  end

  describe "最終利用の更新（最終利用から 30 日）" do
    let(:now) { Time.utc(2026, 10, 7, 4, 30, 0) }
    let!(:signed_in) { sign_in(user, now: now) }

    it "有効な要求のたびに、last_used_at と expires_at を更新する" do
      later = now + 10.days

      travel_to(later) { api_post "/api/usage-events", body, signed_in: signed_in }

      row = Session.find(signed_in.session.id)
      expect(row.last_used_at).to eq(later)
      expect(row.expires_at).to eq(later + 30.days)
    end

    it "GET（BFF の確認を通った要求）でも更新する" do
      later = now + 3.days

      travel_to(later) { get "/api/no-such-endpoint", headers: bff_headers("Cookie" => "#{SessionCookie::NAME}=#{signed_in.token}"), env: public_listener_env }

      expect(response).to have_http_status(404)
      expect(Session.find(signed_in.session.id).last_used_at).to eq(later)
    end

    it "使い続ければ、元の期限（発行から 30 日）を過ぎても、有効" do
      travel_to(now + 29.days) { api_post "/api/usage-events", body, signed_in: signed_in }
      travel_to(now + 58.days) { api_post "/api/usage-events", body, signed_in: signed_in }

      expect(response).to have_http_status(204)
      expect(UsageEvent.count).to eq(2)
    end

    it "BFF の確認で拒否された要求は、更新しない" do
      travel_to(now + 10.days) { api_post "/api/usage-events", body, signed_in: signed_in, headers: { "X-BFF-Secret" => "wrong" } }

      expect(response).to have_http_status(403)
      expect(Session.find(signed_in.session.id).last_used_at).to eq(now)
    end

    it "CSRF の検査で拒否された要求は、更新しない（クロスサイトの要求で、セッションを延命させない）" do
      travel_to(now + 10.days) { api_post "/api/usage-events", body, signed_in: signed_in, headers: { "X-CSRF-Token" => "0" * 64 } }

      expect(response).to have_http_status(403)
      expect(Session.find(signed_in.session.id).last_used_at).to eq(now)
    end

    it "ログインしていない要求は、どのセッションも更新しない" do
      travel_to(now + 10.days) { api_post "/api/usage-events", body }

      expect(Session.find(signed_in.session.id).last_used_at).to eq(now)
    end

    it "他のアカウントのセッションを更新しない" do
      other = sign_in(create(:user), now: now)

      travel_to(now + 10.days) { api_post "/api/usage-events", body, signed_in: signed_in }

      expect(Session.find(other.session.id).last_used_at).to eq(now)
    end
  end

  describe "複数の端末" do
    it "同じアカウントの複数のセッションが、それぞれ有効" do
      first = sign_in(user)
      second = sign_in(user)

      api_post "/api/usage-events", body, signed_in: first
      api_post "/api/usage-events", body, signed_in: second

      expect(UsageEvent.where(user_id: user.id).count).to eq(2)
    end

    it "1 つのセッションを破棄しても、ほかの端末のセッションは有効" do
      first = sign_in(user)
      second = sign_in(user)
      SessionStore.new.revoke(first.session)

      api_post "/api/usage-events", body, signed_in: second

      expect(response).to have_http_status(204)
    end
  end
end
