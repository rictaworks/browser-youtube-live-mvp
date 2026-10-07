require "spec_helper"
require_relative "../support/domain_loader"

# 副作用・遷移の指示を表す値（Directive）。種別（シンボル）と引数（シンボルのキーの Hash）だけを持ち、実行しない。
# 状態遷移の効果（effects）・期限の評価・終了処理・清算の各規則が返す。
RSpec.describe "指示の値（Directive）" do
  describe ".of" do
    it "種別と引数を持つ" do
      directive = Directive.of(:end, reason: "start_timeout")

      expect(directive.kind).to eq(:end)
      expect(directive.args).to eq({ reason: "start_timeout" })
    end

    it "引数が無いときは、空の Hash" do
      expect(Directive.of(:consume_allowance).args).to eq({})
    end

    it "同じ種別と引数なら等しい（値として比べる）。引数が違えば等しくない" do
      expect(Directive.of(:end, reason: "user_stop")).to eq(Directive.of(:end, reason: "user_stop"))
      expect(Directive.of(:end, reason: "user_stop")).not_to eq(Directive.of(:end, reason: "admin_stop"))
      expect(Directive.of(:end, reason: "user_stop")).not_to eq(Directive.of(:terminate, reason: "user_stop"))
      expect(Directive.of(:end, reason: "user_stop").hash).to eq(Directive.of(:end, reason: "user_stop").hash)
    end

    it "指示も引数も凍結される（不変）" do
      directive = Directive.of(:end, reason: "user_stop")

      expect(directive).to be_frozen
      expect(directive.args).to be_frozen
    end

    it "引数は複写される。作成後に、元の Hash を変えても影響しない" do
      source = { reason: "user_stop" }
      directive = Directive.new(kind: :end, args: source)
      source[:reason] = "admin_stop"

      expect(directive.args).to eq({ reason: "user_stop" })
    end
  end

  describe "検査" do
    [ "end", nil, 1, [ :end ] ].each do |kind|
      it "種別がシンボルでなければ拒否する（#{kind.inspect}）" do
        expect { Directive.new(kind: kind, args: {}) }.to raise_error(ArgumentError, "kind must be a Symbol, got #{kind.class}")
      end
    end

    it "引数が Hash でなければ拒否する" do
      expect { Directive.new(kind: :end, args: [ [ :reason, "x" ] ]) }
        .to raise_error(ArgumentError, "args must be a Hash, got Array")
    end

    it "引数のキーがシンボルでなければ拒否する" do
      expect { Directive.new(kind: :end, args: { "reason" => "x" }) }
        .to raise_error(ArgumentError, "args keys must be a Symbol, got String")
    end
  end
end
