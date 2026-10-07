# frozen_string_literal: true

module Admission
  # 拒否（requirements.md 9.3・契約 http-api.md の「受付の拒否」）。タイトル・ユーザーの識別情報を含まない。
  #   reason      拒否理由の符号（契約の rejection_reason）
  #   resolution  再試行で解消するかの区分（契約の resolution。理由ごとに、契約の http-rejections.json が定める）
  #   retry_at    再試行の目安時刻（JST の Time）。契約が目安時刻を持つとした理由だけが持ち、ほかは nil
  #   fields      不備のある入力項目の名前。invalid_input のときだけ（1 件以上）。ほかは空
  # 契約に反する組（理由と区分の食い違い・目安時刻の有無の食い違い・項目名の不整合）は、作れない（ArgumentError）。
  class Rejected < Data.define(:reason, :resolution, :retry_at, :fields)
    # 入力の項目名（契約 http-api.md の fields）
    FIELD_NAMES = %w[title privacy_status made_for_kids recaptcha_token].freeze

    # 理由から、区分を契約で引いて作る。
    def self.for(reason, retry_at: nil, fields: [])
      new(reason: reason, resolution: contract_for!(reason).fetch("resolution"), retry_at: retry_at, fields: fields)
    end

    def self.contract_for!(reason)
      raise ArgumentError, "reason must be a Contract::RejectionReason code, got #{reason.class}" unless Contract::RejectionReason.valid?(reason)

      Contract::HttpRejections.fetch(reason)
    end

    def initialize(reason:, resolution:, retry_at:, fields:)
      contract = self.class.contract_for!(reason)
      check_resolution!(reason, resolution, contract)
      super(
        reason: reason.dup.freeze,
        resolution: resolution.dup.freeze,
        retry_at: normalized_retry_at(reason, retry_at, contract),
        fields: checked_fields(reason, fields)
      )
    end

    def accepted?
      false
    end

    def rejected?
      true
    end

    private

    def check_resolution!(reason, resolution, contract)
      expected = contract.fetch("resolution")
      return if resolution.is_a?(String) && resolution == expected

      raise ArgumentError, "resolution must be #{expected} for reason #{reason}"
    end

    # 契約が目安時刻を持たない理由は nil だけ。持つ理由は Time が必須で、JST（+09:00）にそろえる。
    def normalized_retry_at(reason, retry_at, contract)
      if contract.fetch("retry_at_rule") == "none"
        raise ArgumentError, "retry_at must be nil for reason #{reason}" unless retry_at.nil?

        return nil
      end
      raise ArgumentError, "retry_at must be a Time for reason #{reason}, got #{retry_at.class}" unless retry_at.is_a?(Time)

      UsageCalendar.to_jst(retry_at)
    end

    def checked_fields(reason, fields)
      raise ArgumentError, "fields must be an Array of Strings" unless fields.is_a?(Array) && fields.all?(String)

      if reason == Contract::RejectionReason::INVALID_INPUT
        raise ArgumentError, "fields must not be empty for invalid_input" if fields.empty?
      elsif fields.any?
        raise ArgumentError, "fields must be empty unless reason is invalid_input"
      end
      raise ArgumentError, "fields must be a subset of #{FIELD_NAMES.join(',')}" unless (fields - FIELD_NAMES).empty?
      raise ArgumentError, "fields must not contain duplicates" unless fields.uniq.size == fields.size

      fields.map { |name| name.dup.freeze }.freeze
    end
  end
end
