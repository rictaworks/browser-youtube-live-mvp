require "rails_helper"
require "support/model_support"
require "support/expected_schema"

# requirements.md 14 章・28.1「所有権」。利用者に属するレコードは、アカウント識別子で絞り込む。
# 他のアカウントのレコードを、参照・更新・削除できない（owned_by 経由では、その経路が存在しない）。
# 2 つのアカウント（a・b）を使い、利用者に属する 8 つのモデルのすべてについて検査する。
#
# 識別子を受け取って書き換えるメソッドのうち、Rails 8.1 の Relation が、絞り込みを無視して、クラスのメソッドを
# 直接呼ぶもの（update(id, 属性)・update!(id, 属性)・increment_counter・decrement_counter・upsert・upsert_all）も検査する。
# 関連経由（user.broadcasts.update(id, 属性) など）は、owned_by の対象外（後続の issue は owned_by(user).find(id).update(...) を使う）。
RSpec.describe OwnerScope do
  # テーブル名 => 更新に使う列と値（owned_by 越しの更新が、他のアカウントに届かないことの確認用）。
  #   release  削除の前に行う準備（daily_usages は、配信が参照している間は、削除できないため、配信を先に削除する）
  #   counter  increment_counter・decrement_counter の確認に使う整数の列（整数の列が無いモデルは、nil）
  owned = {
    "sessions" => { column: :last_used_at, value: Time.utc(2000, 1, 1), counter: nil },
    "youtube_connections" => { column: :last_verified_at, value: Time.utc(2000, 1, 1), counter: nil },
    "broadcasts" => { column: :last_checked_at, value: Time.utc(2000, 1, 1), counter: :resume_count },
    "daily_usages" => { column: :extra_grants, value: 99, counter: :consumed_count, release: -> { Broadcast.owned_by(account_a).destroy_all } },
    "relay_tickets" => { column: :used_at, value: Time.utc(2000, 1, 1), counter: :epoch },
    "health_samples" => { column: :sampled_at, value: Time.utc(2000, 1, 1), counter: :sent_kbps },
    "broadcast_events" => { column: :occurred_at, value: Time.utc(2000, 1, 1), counter: nil },
    "usage_events" => { column: :occurred_at, value: Time.utc(2000, 1, 1), counter: nil }
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

  owned.each do |table, change|
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
        changed = model.owned_by(account_a).where(id: record_b.id).update_all(change.fetch(:column) => change.fetch(:value))

        expect(changed).to eq(0)
        expect(model.find(record_b.id).public_send(change.fetch(:column))).not_to eq(change.fetch(:value))
      end

      it "owned_by(a) 越しの update_all・destroy_all は、a のレコードだけに作用する" do
        expect(model.owned_by(account_a).update_all(change.fetch(:column) => change.fetch(:value))).to eq(1)
        expect(model.find(record_a.id).public_send(change.fetch(:column))).to eq(change.fetch(:value))
        expect(model.find(record_b.id).public_send(change.fetch(:column))).not_to eq(change.fetch(:value))

        instance_exec(&change[:release]) if change[:release]
        model.owned_by(account_a).destroy_all

        expect(model.exists?(record_a.id)).to be(false)
        expect(model.exists?(record_b.id)).to be(true)
      end

      it "owned_by(a).find(a のレコードの識別子) は、a のレコードを返し、更新・削除できる（他のアカウントのレコードだけを、拒否する）" do
        found = model.owned_by(account_a).find(record_a.id)

        expect(found).to eq(record_a)
        expect(found.update(change.fetch(:column) => change.fetch(:value))).to be(true)
        instance_exec(&change[:release]) if change[:release]
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

      describe "識別子を受け取って書き換えるメソッド（Relation が、絞り込みを無視してクラスのメソッドを呼ぶものを含む）" do
        let(:column) { change.fetch(:column) }
        let(:value) { change.fetch(:value) }
        let(:attributes) { { column => value } }

        # 列の、いまの値（DB から読み直す）
        def stored(record)
          model.find(record.id).public_send(column)
        end

        it "update(b のレコードの識別子, 属性)・update!(…) は、ActiveRecord::RecordNotFound。b のレコードは書き換わらない" do
          expect { model.owned_by(account_a).update(record_b.id, attributes) }.to raise_error(ActiveRecord::RecordNotFound)
          expect { model.owned_by(account_a).update!(record_b.id, attributes) }.to raise_error(ActiveRecord::RecordNotFound)
          expect(stored(record_b)).not_to eq(value)
        end

        it "配列の形（update([b の識別子], [属性])・update!(…)）も、RecordNotFound。b のレコードは書き換わらない" do
          expect { model.owned_by(account_a).update([ record_b.id ], [ attributes ]) }.to raise_error(ActiveRecord::RecordNotFound)
          expect { model.owned_by(account_a).update!([ record_b.id ], [ attributes ]) }.to raise_error(ActiveRecord::RecordNotFound)
          expect(stored(record_b)).not_to eq(value)
        end

        it "a と b の識別子を混ぜた配列は、RecordNotFound で、どちらのレコードも書き換えない" do
          expect { model.owned_by(account_a).update([ record_a.id, record_b.id ], [ attributes, attributes ]) }.to raise_error(ActiveRecord::RecordNotFound)
          expect(stored(record_a)).not_to eq(value)
          expect(stored(record_b)).not_to eq(value)
        end

        it "destroy(b の識別子) は RecordNotFound、delete(b の識別子) は 0 件（配列の形も同じ）。b のレコードは残る" do
          expect { model.owned_by(account_a).destroy(record_b.id) }.to raise_error(ActiveRecord::RecordNotFound)
          expect { model.owned_by(account_a).destroy([ record_b.id ]) }.to raise_error(ActiveRecord::RecordNotFound)
          expect(model.owned_by(account_a).delete(record_b.id)).to eq(0)
          expect(model.owned_by(account_a).delete([ record_b.id ])).to eq(0)
          expect(model.exists?(record_b.id)).to be(true)
        end

        it "a 自身のレコードには、update・update!（識別子の形・配列の形・全件の形）が使える。b のレコードは書き換わらない" do
          original = stored(record_a)
          forms = {
            "update(識別子, 属性)" => -> { model.owned_by(account_a).update(record_a.id, attributes) },
            "update!(識別子, 属性)" => -> { model.owned_by(account_a).update!(record_a.id, attributes) },
            "update([識別子], [属性])" => -> { model.owned_by(account_a).update([ record_a.id ], [ attributes ]) },
            "update!([識別子], [属性])" => -> { model.owned_by(account_a).update!([ record_a.id ], [ attributes ]) },
            "update(属性)（全件の形）" => -> { model.owned_by(account_a).update(attributes) },
            "update!(属性)（全件の形）" => -> { model.owned_by(account_a).update!(attributes) }
          }

          aggregate_failures do
            forms.each do |label, form|
              instance_exec(&form)

              expect(stored(record_a)).to eq(value), "#{label} が、a のレコードを書き換えない"
              expect(stored(record_b)).not_to eq(value), "#{label} が、b のレコードを書き換えた"
              model.where(id: record_a.id).update_all(column => original)
            end
          end
        end

        it "識別子の形の update・update! は、書き換えたレコードを返す" do
          expect(model.owned_by(account_a).update(record_a.id, attributes)).to eq(record_a)
          expect(model.owned_by(account_a).update!(record_a.id, attributes)).to eq(record_a)
          expect(model.owned_by(account_a).update([ record_a.id ], [ attributes ])).to eq([ record_a ])
        end

        it "連結した絞り込み（where・order・先に付けた where・merge）のあとでも、update(b の識別子, 属性)・update!(…) は届かない" do
          relations = [
            model.owned_by(account_a).where.not(id: nil),
            model.owned_by(account_a).order(:id),
            model.where.not(id: nil).owned_by(account_a),
            model.owned_by(account_a).merge(model.where.not(id: nil))
          ]

          relations.each do |relation|
            expect { relation.update(record_b.id, attributes) }.to raise_error(ActiveRecord::RecordNotFound)
            expect { relation.update!(record_b.id, attributes) }.to raise_error(ActiveRecord::RecordNotFound)
          end
          expect(stored(record_b)).not_to eq(value)
        end

        if change[:counter]
          it "increment_counter・decrement_counter は、b のレコードに届かない（0 件）。a のレコードには効く" do
            counter = change.fetch(:counter)
            before_a = model.find(record_a.id).public_send(counter)
            before_b = model.find(record_b.id).public_send(counter)

            expect(model.owned_by(account_a).increment_counter(counter, record_b.id)).to eq(0)
            expect(model.owned_by(account_a).decrement_counter(counter, record_b.id, by: 3)).to eq(0)
            expect(model.find(record_b.id).public_send(counter)).to eq(before_b)

            expect(model.owned_by(account_a).increment_counter(counter, record_a.id, by: 2)).to eq(1)
            expect(model.find(record_a.id).public_send(counter)).to eq(before_a + 2)
            expect(model.owned_by(account_a).decrement_counter(counter, record_a.id)).to eq(1)
            expect(model.find(record_a.id).public_send(counter)).to eq(before_a + 1)
            expect(model.find(record_b.id).public_send(counter)).to eq(before_b)
          end
        end

        it "upsert・upsert_all は、owned_by 越しには使えない（主キーの衝突で、他のアカウントの行を上書きできるため）" do
          row = record_b.attributes.merge(column.to_s => value)

          expect { model.owned_by(account_a).upsert(row) }.to raise_error(OwnerScope::UnscopedOperationError)
          expect { model.owned_by(account_a).upsert_all([ row ]) }.to raise_error(OwnerScope::UnscopedOperationError)
          expect(stored(record_b)).not_to eq(value)
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

  describe "owned_by が返す Relation" do
    it "識別子を受け取る書き換えを絞り込む拡張（OwnerScope::OwnedRelation）を持つ。連結しても、外れない" do
      relation = Session.owned_by(account_a)

      expect(relation).to be_a(OwnerScope::OwnedRelation)
      expect(relation.where.not(id: nil)).to be_a(OwnerScope::OwnedRelation)
      expect(Session.where.not(id: nil).owned_by(account_a)).to be_a(OwnerScope::OwnedRelation)
    end

    it "owned_by を通さない通常の Relation には、拡張が付かない（システム全体の処理が、通常のまま使える）" do
      expect(Session.all).not_to be_a(OwnerScope::OwnedRelation)
    end
  end

  describe "OwnerScope::UnscopedOperationError" do
    it "メッセージに、行の値を含めず、代わりの呼び方（クラスのメソッド）を示す" do
      error = begin
        Session.owned_by(account_a).upsert(token_digest: "dummy-secret-looking-value")
      rescue OwnerScope::UnscopedOperationError => e
        e
      end

      expect(error).to be_a(StandardError)
      expect(error.message).not_to include("dummy-secret-looking-value")
      expect(error.message).to include("Session.upsert")
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
