require "spec_helper"
require_relative "support/contracts_loader"

# 受付の拒否理由 14 種（src/contracts/http-rejections.json）と、Ruby の定数 Contract::HttpRejections の一致。
RSpec.describe "契約の拒否理由（Ruby の定数 Contract::HttpRejections）" do
  rejections = ContractSpecSupport.strip_document_keys(ContractSpecSupport.load_json("http-rejections.json"))

  before(:all) { ContractSpecSupport.load_contract_namespace! }

  it "BY_REASON は、JSON の rejections と一致する（型まで）" do
    expect(ContractSpecSupport.same_value?(Contract::HttpRejections::BY_REASON, rejections.fetch("rejections"))).to be(true)
  end

  it "RETRY_AT_RULES は、JSON の retry_at_rules と一致する" do
    expect(Contract::HttpRejections::RETRY_AT_RULES).to eq(rejections.fetch("retry_at_rules"))
    expect(Contract::HttpRejections::RETRY_AT_RULES).to eq(%w[ none rate_limit_window next_usage_day_start next_month_start next_quota_day_start ])
  end

  it "定数は BY_REASON と RETRY_AT_RULES だけ（JSON のキーと過不足なく対応）" do
    expect(Contract::HttpRejections.constants(false).sort).to eq(%i[ BY_REASON RETRY_AT_RULES ])
  end

  it "深く凍結されている" do
    expect(Contract::HttpRejections::BY_REASON).to be_frozen
    expect(Contract::HttpRejections::RETRY_AT_RULES).to be_frozen
    Contract::HttpRejections::BY_REASON.each do |reason, entry|
      expect(reason).to be_frozen
      expect(entry).to be_frozen
      expect(entry.values.select { |value| value.is_a?(String) }).to all(be_frozen)
    end
  end

  describe "14 種の網羅" do
    it "拒否理由は、列挙 RejectionReason の 14 値と過不足なく一致する（順も同じ）" do
      expect(Contract::HttpRejections::BY_REASON.keys).to eq(Contract::RejectionReason::ALL)
      expect(Contract::HttpRejections::BY_REASON.size).to eq(14)
    end

    it "order は、列挙の添字（9.2 の順 0〜13）と一致する" do
      Contract::RejectionReason::ALL.each_with_index do |reason, index|
        expect(Contract::HttpRejections.fetch(reason).fetch("order")).to eq(index)
      end
    end

    it "区分（resolution）は、列挙 Resolution の値で、11 値すべてが使われる" do
      used = Contract::HttpRejections::BY_REASON.values.map { |entry| entry.fetch("resolution") }

      expect(used - Contract::Resolution::ALL).to be_empty
      expect(used.uniq.sort).to eq(Contract::Resolution::ALL.sort)
    end

    it "再試行の目安時刻の規則は、RETRY_AT_RULES の値" do
      rules = Contract::HttpRejections::BY_REASON.values.map { |entry| entry.fetch("retry_at_rule") }

      expect(rules - Contract::HttpRejections::RETRY_AT_RULES).to be_empty
    end
  end

  describe "HTTP ステータスと区分（設計メモの表）" do
    {
      "invalid_input" => [ 422, "fix_input", "none" ],
      "not_logged_in" => [ 401, "log_in", "none" ],
      "rate_limited" => [ 429, "wait", "rate_limit_window" ],
      "bot_check_failed" => [ 403, "wait", "none" ],
      "broadcast_in_progress" => [ 409, "stop_first", "none" ],
      "youtube_not_connected" => [ 409, "connect", "none" ],
      "authorization_revoked" => [ 409, "reconnect", "none" ],
      "live_not_enabled" => [ 409, "enable_live", "none" ],
      "allowance_consumed" => [ 409, "next_usage_day", "next_usage_day_start" ],
      "attempts_exhausted" => [ 409, "next_usage_day", "next_usage_day_start" ],
      "intake_paused" => [ 503, "after_release", "none" ],
      "transfer_budget_exceeded" => [ 503, "next_month", "next_month_start" ],
      "capacity_full" => [ 503, "wait", "none" ],
      "quota_insufficient" => [ 503, "next_quota_day", "next_quota_day_start" ]
    }.each do |reason, (status, resolution, rule)|
      it "#{reason}: #{status}・#{resolution}・retry_at は #{rule}" do
        entry = Contract::HttpRejections.fetch(reason)

        expect(entry.fetch("http_status")).to eq(status)
        expect(entry.fetch("resolution")).to eq(resolution)
        expect(entry.fetch("retry_at_rule")).to eq(rule)
      end
    end
  end

  describe ".fetch" do
    it "列挙の定数（Contract::RejectionReason::…）で引ける" do
      expect(Contract::HttpRejections.fetch(Contract::RejectionReason::ALLOWANCE_CONSUMED).fetch("http_status")).to eq(409)
    end

    [ nil, "", "unknown", :invalid_input, 0, "INVALID_INPUT", " invalid_input" ].each do |reason|
      it "未知の拒否理由 #{reason.inspect} は KeyError（既定値へ倒さない）" do
        expect { Contract::HttpRejections.fetch(reason) }.to raise_error(KeyError)
      end
    end
  end
end
