require "rails_helper"
require "support/model_support"
require "support/expected_schema"

# requirements.md 14 章・28.1「所有権」。利用者に属するレコードは、アカウント識別子で絞り込む。
# 他のアカウントのレコードを、参照・更新・削除できない（owned_by 経由では、その経路が存在しない）。
# 2 つのアカウント（a・b）を使い、利用者に属する 8 つのモデルのすべてについて検査する。
RSpec.describe OwnerScope do
  # テーブル名 => 更新に使う列と値（owned_by 越しの更新が、他のアカウントに届かないことの確認用）。
  # release は、削除の前に行う準備（daily_usages は、配信が参照している間は、削除できないため、配信を先に削除する）
  owned = {
    "sessions" => { column: :last_used_at, value: Time.utc(2000, 1, 1) },
    "youtube_connections" => { column: :last_verified_at, value: Time.utc(2000, 1, 1) },
    "broadcasts" => { column: :last_checked_at, value: Time.utc(2000, 1, 1) },
    "daily_usages" => { column: :extra_grants, value: 99, release: -> { Broadcast.owned_by(account_a).destroy_all } },
    "relay_tickets" => { column: :used_at, value: Time.utc(2000, 1, 1) },
    "health_samples" => { column: :sampled_at, value: Time.utc(2000, 1, 1) },
    "broadcast_events" => { column: :occurred_at, value: Time.utc(2000, 1, 1) },
    "usage_events" => { column: :occurred_at, value: Time.utc(2000, 1, 1) }
  }

  let!(:account_a) { create(:user) }
  let!(:account_b) { create(:user) }
  let!(:records_a) { create_account_records(account_a) }
  let!(:records_b) { create_account_records(account_b) }

  it "検査の対象は、20.1 の「アカウント識別子 保持する」の 8 テーブル（分類の表と一致する）" do
    expect(owned.keys).to match_array(ExpectedSchema::USER_OWNED_TABLES)
  end

  it "利用者に属するモデルは、すべて OwnerScope を含む" do
    owned.each_key do |table|
      expect(table.classify.constantize.include?(OwnerScope)).to be(true), "#{table.classify} が OwnerScope を含まない"
    end
  end

  it "利用者に属さないモデル（users・システム全体・保持しないテーブル）は、OwnerScope を含まず、owned_by を持たない" do
    other_tables = ExpectedSchema::TABLES.keys - owned.keys

    other_tables.each do |table|
      model = table.classify.constantize
      expect(model.include?(OwnerScope)).to be(false), "#{model} が OwnerScope を含む"
      expect(model).not_to respond_to(:owned_by)
    end
  end

  owned.each do |table, update|
    model_name = table.classify
    key = table.singularize.to_sym

    describe model_name do
      let(:model) { model_name.constantize }
      let(:record_a) { records_a.fetch(key) }
      let(:record_b) { records_b.fetch(key) }

      it "owned_by(a) は、a のレコードだけを返す（User でも、識別子の文字列でも）" do
        expect(model.owned_by(account_a).pluck(:id)).to eq([ record_a.id ])
        expect(model.owned_by(account_a.id).pluck(:id)).to eq([ record_a.id ])
        expect(model.owned_by(account_b).pluck(:id)).to eq([ record_b.id ])
      end

      it "owned_by(a).find(b のレコードの識別子) は、ActiveRecord::RecordNotFound（他のアカウントのレコードは、存在しないものとして扱う）" do
        expect { model.owned_by(account_a).find(record_b.id) }.to raise_error(ActiveRecord::RecordNotFound)
        expect { model.owned_by(account_a).find_by!(id: record_b.id) }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "owned_by(a) から、b のレコードを、find_by・exists?・where で引いても、何も得られない" do
        scope = model.owned_by(account_a)

        expect(scope.find_by(id: record_b.id)).to be_nil
        expect(scope.exists?(record_b.id)).to be(false)
        expect(scope.where(id: record_b.id)).to be_empty
        expect(scope.where(id: [ record_a.id, record_b.id ]).pluck(:id)).to eq([ record_a.id ])
      end

      it "owned_by(a) 越しの update_all は、b のレコードに届かない" do
        changed = model.owned_by(account_a).where(id: record_b.id).update_all(update.fetch(:column) => update.fetch(:value))

        expect(changed).to eq(0)
        expect(model.find(record_b.id).public_send(update.fetch(:column))).not_to eq(update.fetch(:value))
      end

      it "owned_by(a) 越しの update_all・destroy_all は、a のレコードだけに作用する" do
        expect(model.owned_by(account_a).update_all(update.fetch(:column) => update.fetch(:value))).to eq(1)
        expect(model.find(record_a.id).public_send(update.fetch(:column))).to eq(update.fetch(:value))
        expect(model.find(record_b.id).public_send(update.fetch(:column))).not_to eq(update.fetch(:value))

        instance_exec(&update[:release]) if update[:release]
        model.owned_by(account_a).destroy_all

        expect(model.exists?(record_a.id)).to be(false)
        expect(model.exists?(record_b.id)).to be(true)
      end

      it "owned_by(a).find(a のレコードの識別子) は、a のレコードを返し、更新・削除できる（他のアカウントのレコードだけを、拒否する）" do
        found = model.owned_by(account_a).find(record_a.id)

        expect(found).to eq(record_a)
        expect(found.update(update.fetch(:column) => update.fetch(:value))).to be(true)
        instance_exec(&update[:release]) if update[:release]
        expect(found.destroy).to be_truthy
        expect(model.exists?(record_a.id)).to be(false)
      end

      it "user_id は、作成後に付け替えられない（他のアカウントのレコードへ変えられない）" do
        expect { record_a.update(user_id: account_b.id) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
        expect(model.find(record_a.id).user_id).to eq(account_a.id)
      end

      it "owned_by は、ほかの条件と連結できる（所有者の絞り込みが外れない）" do
        scope = model.owned_by(account_a).where.not(id: nil).order(:id)

        expect(scope.pluck(:id)).to eq([ record_a.id ])
        expect(scope.to_sql).to include("user_id")
      end

      it "owned_by に、識別子として使えない値（nil・空・UUID でない文字列・保存前の User・数値・配列）を渡すと、絞り込まずに失敗する" do
        [ nil, "", " ", "not-a-uuid", User.new, 1, [ account_a.id ], { id: account_a.id } ].each do |invalid|
          expect { model.owned_by(invalid) }.to raise_error(OwnerScope::InvalidOwnerError), "owned_by(#{invalid.inspect}) が失敗しない"
        end
      end
    end
  end

  describe "アカウントとの紐づけを外した測定イベント（usage_events.user_id が NULL）" do
    it "どのアカウントの owned_by にも現れず、owned_by(nil) は失敗する（NULL を絞り込みの値にしない）" do
      detached = create(:usage_event, :detached)

      expect(UsageEvent.owned_by(account_a).pluck(:id)).not_to include(detached.id)
      expect(UsageEvent.owned_by(account_b).pluck(:id)).not_to include(detached.id)
      expect { UsageEvent.owned_by(nil) }.to raise_error(OwnerScope::InvalidOwnerError)
    end
  end

  describe "OwnerScope::InvalidOwnerError" do
    it "ArgumentError の一種（呼び出し側の誤りであり、黙って別の値へ倒さない）" do
      expect(OwnerScope::InvalidOwnerError.ancestors).to include(ArgumentError)
    end

    it "メッセージに、渡された値そのものを含めない（識別子・要約値を、例外から出さない）" do
      error = begin
        Session.owned_by("dummy-secret-looking-value")
      rescue OwnerScope::InvalidOwnerError => e
        e
      end

      expect(error.message).not_to include("dummy-secret-looking-value")
    end
  end
end
