require "spec_helper"
require "date"
require "time"
require_relative "support/domain_loader"

# 開始受付判定の結果（requirements.md 9.3）。
#   Admission::Accepted   受理。利用日・割り当て日・予約額（550）・適用される上限（時間上限・プロファイルの範囲）
#   Admission::Rejected   拒否。拒否理由の符号・再試行で解消するかの区分・再試行の目安時刻・不備のある入力項目の名前
# 結果は、ユーザーの識別情報・タイトルを含まない。拒否理由・区分・HTTP ステータスは、契約（Contract::RejectionReason・HttpRejections）。
# 値オブジェクトは、契約に反する組（理由と区分の食い違い・再試行の目安時刻の有無の食い違い）を作れない。
RSpec.describe "開始受付判定の結果（Admission）" do
  let(:reasons) { Contract::RejectionReason::ALL }
  let(:retry_at) { Time.utc(2026, 10, 7, 18, 0, 0) }

  # reason に対して、契約が定める retry_at の有無に合う値
  def retry_at_for(reason)
    Contract::HttpRejections.fetch(reason).fetch("retry_at_rule") == "none" ? nil : Time.utc(2026, 10, 7, 18, 0, 0)
  end

  def fields_for(reason)
    reason == "invalid_input" ? [ "title" ] : []
  end

  # Hash・Array・String を、再帰的にたどって、すべて凍結されているか
  def deeply_frozen?(value)
    case value
    when Hash then value.frozen? && value.all? { |key, child| deeply_frozen?(key) && deeply_frozen?(child) }
    when Array then value.frozen? && value.all? { |child| deeply_frozen?(child) }
    else value.frozen?
    end
  end

  describe "Admission::AppliedLimits（適用される上限）" do
    it "設定の時間上限（分）を秒にし、プロファイル（契約の profiles）をそのまま持つ" do
      limits = Admission::AppliedLimits.from_settings(Settings.defaults)

      expect(limits.time_limit_seconds).to eq(3_600)
      expect(limits.profiles).to equal(Contract::Limits::PROFILES)
      expect(limits.profiles.keys).to eq(%w[720p 480p])
      expect(limits.profiles.fetch("720p").values_at("video_bitrate_min_kbps", "video_bitrate_initial_kbps", "video_bitrate_max_kbps")).to eq([ 3_000, 4_500, 6_000 ])
      expect(limits.profiles.fetch("480p").values_at("video_bitrate_min_kbps", "video_bitrate_initial_kbps", "video_bitrate_max_kbps")).to eq([ 800, 1_500, 2_500 ])
      expect(limits).to be_frozen
    end

    it "時間上限を変えた設定が反映される（30 分は 1,800 秒、1 分は 60 秒）" do
      expect(Admission::AppliedLimits.from_settings(Settings.from_raw("time_limit_minutes" => "30")).time_limit_seconds).to eq(1_800)
      expect(Admission::AppliedLimits.from_settings(Settings.from_raw("time_limit_minutes" => "1")).time_limit_seconds).to eq(60)
    end

    it "time_limit_seconds は 1 以上の整数、profiles は Hash。違反は ArgumentError" do
      [ 0, -1, 1.5, "3600", nil ].each do |invalid|
        expect { Admission::AppliedLimits.new(time_limit_seconds: invalid, profiles: Contract::Limits::PROFILES) }
          .to raise_error(ArgumentError, /time_limit_seconds/)
      end
      [ nil, [], "720p" ].each do |invalid|
        expect { Admission::AppliedLimits.new(time_limit_seconds: 3_600, profiles: invalid) }.to raise_error(ArgumentError, /profiles/)
      end
    end

    describe "profiles の凍結（値オブジェクトを、あとから変更できない）" do
      it "凍結されていない profiles は、深く凍結した複製にする。呼び出し側の Hash は、凍結せず、あとの変更の影響も受けない" do
        given = { "720p" => { "width" => 1_280, "codecs" => [ "avc1", "mp4a" ], "label" => +"standard" } }
        limits = Admission::AppliedLimits.new(time_limit_seconds: 3_600, profiles: given)

        expect(limits.profiles).to eq(given)
        expect(deeply_frozen?(limits.profiles)).to be(true)
        expect(given).not_to be_frozen
        expect(given["720p"]).not_to be_frozen
        expect(given["720p"]["codecs"]).not_to be_frozen
        expect(given["720p"]["label"]).not_to be_frozen

        given["720p"]["width"] = 1
        given["720p"]["codecs"] << "extra"
        expect(limits.profiles.dig("720p", "width")).to eq(1_280)
        expect(limits.profiles.dig("720p", "codecs")).to eq([ "avc1", "mp4a" ])
      end

      it "profiles を、あとから変更しようとすると、FrozenError（外側・内側の Hash・Array・String のどれも）" do
        limits = Admission::AppliedLimits.new(time_limit_seconds: 3_600, profiles: { "720p" => { "width" => 1_280, "codecs" => [ "avc1" ], "label" => +"standard" } })

        expect { limits.profiles["480p"] = {} }.to raise_error(FrozenError)
        expect { limits.profiles["720p"]["width"] = 1 }.to raise_error(FrozenError)
        expect { limits.profiles["720p"]["codecs"] << "x" }.to raise_error(FrozenError)
        expect { limits.profiles["720p"]["codecs"].first << "x" }.to raise_error(FrozenError)
        expect { limits.profiles["720p"]["label"] << "x" }.to raise_error(FrozenError)
      end

      it "外側だけ凍結した profiles（内側は凍結されていない）も、深く凍結した複製にする（浅い凍結を信用しない）" do
        outer_only = { "720p" => { "codecs" => [ +"avc1" ] } }.freeze
        limits = Admission::AppliedLimits.new(time_limit_seconds: 3_600, profiles: outer_only)

        expect(deeply_frozen?(limits.profiles)).to be(true)
        expect(limits.profiles).to eq(outer_only)
        expect(limits.profiles).not_to equal(outer_only)
        expect(outer_only["720p"]).not_to be_frozen
      end

      it "すでに深く凍結された profiles（契約の値など）は、複製せず、そのまま持つ" do
        already = { "720p" => { "codecs" => [ "avc1".freeze ].freeze }.freeze }.freeze

        expect(Admission::AppliedLimits.new(time_limit_seconds: 3_600, profiles: already).profiles).to equal(already)
        expect(Admission::AppliedLimits.new(time_limit_seconds: 3_600, profiles: Contract::Limits::PROFILES).profiles).to equal(Contract::Limits::PROFILES)
      end

      it "数値・真偽値・nil・シンボルは、そのまま持つ（不変）。値は変わらない" do
        given = { "a" => [ 1, 2.5, nil, true, false, :sym, +"s" ], "b" => { "c" => 3 } }
        limits = Admission::AppliedLimits.new(time_limit_seconds: 3_600, profiles: given)

        expect(limits.profiles).to eq(given)
        expect(deeply_frozen?(limits.profiles)).to be(true)
      end

      it "from_settings の profiles も、深く凍結されている" do
        expect(deeply_frozen?(Admission::AppliedLimits.from_settings(Settings.defaults).profiles)).to be(true)
      end
    end

    it "設定以外から作れない（from_settings は Settings だけ）" do
      expect { Admission::AppliedLimits.from_settings(nil) }.to raise_error(ArgumentError, /settings/)
      expect { Admission::AppliedLimits.from_settings(time_limit_minutes: 60) }.to raise_error(ArgumentError, /settings/)
    end
  end

  describe "Admission::Accepted（受理）" do
    let(:limits) { Admission::AppliedLimits.from_settings(Settings.defaults) }

    def accepted_attributes(limits)
      { usage_date: Date.new(2026, 10, 7), quota_date: Date.new(2026, 10, 6), reservation_units: 550, limits: limits }
    end

    it "利用日・割り当て日・予約額・適用される上限だけを持つ（ユーザーの識別情報・タイトルを持たない）" do
      accepted = Admission::Accepted.new(**accepted_attributes(limits))

      expect(Admission::Accepted.members).to eq(%i[usage_date quota_date reservation_units limits])
      expect(accepted).to be_frozen
      expect(accepted).to be_accepted
      expect(accepted).not_to be_rejected
    end

    it "型の検査: 利用日・割り当て日は Date、予約額は 1 以上の整数、上限は AppliedLimits" do
      [ nil, "2026-10-07", Time.utc(2026, 10, 7), DateTime.new(2026, 10, 7) ].each do |invalid|
        expect { Admission::Accepted.new(**accepted_attributes(limits).merge(usage_date: invalid)) }.to raise_error(ArgumentError, /usage_date/)
        expect { Admission::Accepted.new(**accepted_attributes(limits).merge(quota_date: invalid)) }.to raise_error(ArgumentError, /quota_date/)
      end
      [ 0, -1, 550.0, "550", nil ].each do |invalid|
        expect { Admission::Accepted.new(**accepted_attributes(limits).merge(reservation_units: invalid)) }.to raise_error(ArgumentError, /reservation_units/)
      end
      [ nil, {}, { time_limit_seconds: 3_600 } ].each do |invalid|
        expect { Admission::Accepted.new(**accepted_attributes(limits).merge(limits: invalid)) }.to raise_error(ArgumentError, /limits/)
      end
    end
  end

  describe "Admission::Rejected（拒否）" do
    it "契約の拒否理由 14 種すべてについて、契約どおりの区分・再試行の目安時刻の有無で作れる" do
      expect(reasons.size).to eq(14)

      reasons.each do |reason|
        contract = Contract::HttpRejections.fetch(reason)
        rejected = Admission::Rejected.new(
          reason: reason, resolution: contract.fetch("resolution"), retry_at: retry_at_for(reason), fields: fields_for(reason)
        )

        expect(rejected.reason).to eq(reason)
        expect(rejected.resolution).to eq(contract.fetch("resolution"))
        expect(rejected).to be_rejected
        expect(rejected).not_to be_accepted
        expect(rejected).to be_frozen
      end
    end

    it "Rejected.for は、理由から、区分を契約で引いて作る" do
      reasons.each do |reason|
        rejected = Admission::Rejected.for(reason, retry_at: retry_at_for(reason), fields: fields_for(reason))

        expect(rejected.resolution).to eq(Contract::HttpRejections.fetch(reason).fetch("resolution"))
      end
    end

    it "Rejected.for の既定は、再試行の目安時刻なし・不備の項目なし" do
      rejected = Admission::Rejected.for("not_logged_in")

      expect(rejected.retry_at).to be_nil
      expect(rejected.fields).to eq([])
    end

    it "未知の拒否理由は ArgumentError（既定の理由へ倒さない）" do
      [ "unknown", "", nil, :invalid_input, "INVALID_INPUT", "invalid_input " ].each do |invalid|
        expect { Admission::Rejected.for(invalid, fields: [ "title" ]) }.to raise_error(ArgumentError, /reason/)
        expect { Admission::Rejected.new(reason: invalid, resolution: "fix_input", retry_at: nil, fields: [ "title" ]) }.to raise_error(ArgumentError, /reason/)
      end
    end

    it "区分が、契約の区分と食い違うときは ArgumentError（例: 利用枠消費済みの区分は next_usage_day）" do
      expect { Admission::Rejected.new(reason: "allowance_consumed", resolution: "wait", retry_at: retry_at, fields: []) }
        .to raise_error(ArgumentError, /resolution/)
      expect { Admission::Rejected.new(reason: "capacity_full", resolution: "next_usage_day", retry_at: nil, fields: []) }
        .to raise_error(ArgumentError, /resolution/)
      expect { Admission::Rejected.new(reason: "capacity_full", resolution: nil, retry_at: nil, fields: []) }
        .to raise_error(ArgumentError, /resolution/)
    end

    describe "再試行の目安時刻（retry_at）" do
      it "契約で目安時刻を持つ理由（頻度超過・利用枠消費済み・試行上限・転送量の予算超過・API 割り当て不足）は、Time が必須" do
        %w[rate_limited allowance_consumed attempts_exhausted transfer_budget_exceeded quota_insufficient].each do |reason|
          expect(Contract::HttpRejections.fetch(reason).fetch("retry_at_rule")).not_to eq("none")
          expect { Admission::Rejected.for(reason, retry_at: nil) }.to raise_error(ArgumentError, /retry_at/)
          expect { Admission::Rejected.for(reason, retry_at: "2026-10-08T03:00:00+09:00") }.to raise_error(ArgumentError, /retry_at/)
          expect(Admission::Rejected.for(reason, retry_at: retry_at).retry_at).to eq(retry_at)
        end
      end

      it "契約で目安時刻を持たない理由は、nil だけ（Time を渡すと ArgumentError）" do
        (reasons - %w[rate_limited allowance_consumed attempts_exhausted transfer_budget_exceeded quota_insufficient]).each do |reason|
          expect(Contract::HttpRejections.fetch(reason).fetch("retry_at_rule")).to eq("none")
          expect { Admission::Rejected.for(reason, retry_at: retry_at, fields: fields_for(reason)) }.to raise_error(ArgumentError, /retry_at/)
          expect(Admission::Rejected.for(reason, fields: fields_for(reason)).retry_at).to be_nil
        end
      end

      it "時刻は JST（+09:00）の Time にそろえる（同じ時刻）。ISO 8601 で秒まで表せる" do
        rejected = Admission::Rejected.for("allowance_consumed", retry_at: Time.utc(2026, 10, 7, 18, 0, 0))

        expect(rejected.retry_at).to eq(Time.utc(2026, 10, 7, 18, 0, 0))
        expect(rejected.retry_at.utc_offset).to eq(32_400)
        expect(rejected.retry_at.iso8601).to eq("2026-10-08T03:00:00+09:00")
        expect(rejected.retry_at).to be_frozen
      end

      it "-07:00 の Time を渡しても、JST にそろう" do
        rejected = Admission::Rejected.for("quota_insufficient", retry_at: Time.new(2026, 10, 7, 0, 0, 0, "-07:00"))

        expect(rejected.retry_at.iso8601).to eq("2026-10-07T16:00:00+09:00")
      end
    end

    describe "不備のある入力項目の名前（fields）" do
      it "invalid_input は、1 件以上の項目名が必須（title・privacy_status・made_for_kids・recaptcha_token の部分集合）" do
        expect(Admission::Rejected::FIELD_NAMES).to eq(%w[title privacy_status made_for_kids recaptcha_token])
        expect { Admission::Rejected.for("invalid_input", fields: []) }.to raise_error(ArgumentError, /fields/)
        expect(Admission::Rejected.for("invalid_input", fields: %w[title privacy_status made_for_kids]).fields).to eq(%w[title privacy_status made_for_kids])
        expect(Admission::Rejected.for("invalid_input", fields: [ "recaptcha_token" ]).fields).to eq([ "recaptcha_token" ])
      end

      it "invalid_input 以外は、項目名を持てない（空だけ）" do
        (reasons - [ "invalid_input" ]).each do |reason|
          expect { Admission::Rejected.for(reason, retry_at: retry_at_for(reason), fields: [ "title" ]) }.to raise_error(ArgumentError, /fields/)
        end
      end

      it "未知の項目名・重複・文字列でないものは ArgumentError" do
        [ [ "unknown" ], [ "Title" ], [ :title ], [ "title", "title" ], [ nil ], "title", nil ].each do |invalid|
          expect { Admission::Rejected.for("invalid_input", fields: invalid) }.to raise_error(ArgumentError, /fields/)
        end
      end

      it "項目名の配列は、凍結され、渡した配列の変更に影響されない" do
        given = [ "title", "made_for_kids" ]
        rejected = Admission::Rejected.for("invalid_input", fields: given)
        given << "privacy_status"

        expect(rejected.fields).to eq(%w[title made_for_kids])
        expect(rejected.fields).to be_frozen
        expect(rejected.fields).to all(be_frozen)
      end
    end

    it "結果は、タイトル・ユーザーの識別情報を持たない（項目は、理由・区分・目安時刻・不備の項目名だけ）" do
      expect(Admission::Rejected.members).to eq(%i[reason resolution retry_at fields])
    end
  end
end
