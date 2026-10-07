# 設定値の読み書き（requirements.md 8 章・19 章・20.4）。system_settings（キーと値の文字列）と、#5 の Settings（型付きの値）の橋渡し。
#
# 型・範囲・既定値の規則は、Domain Core（Settings・契約の limits.json の setting_defaults）が持つ。このサービスは、読み書きだけを行う。
#
#   current   system_settings を毎回読み、Settings を返す。
#             キャッシュしない（管理画面で制限値を変えたら、次の受付から適用する。反映が遅れない。8 章・19 章）。
#             行が無いキーは既定値。保存された値が壊れている（検証に失敗する）ときは、既定値へ黙って戻さず、CorruptSetting にする
#   update!   検証したうえで、1 つの upsert 文で保存する。未知のキー・範囲外・型違いは、Settings::InvalidSetting（保存しない）。
#             操作の記録（admin_actions）は、呼び出し側（管理画面。#17）が別に行う。このメソッドは記録しない
#
# 受付停止（intake_paused）も、9 つの設定の 1 つとして、同じ経路で読み書きする。
module SettingsStore
  # 保存された値が、検証に通らない（system_settings の行が壊れている。手で書き換えた・規則を変えた・旧い版の値など）。
  # 呼び出し側（受付など）は、これを受付の失敗として扱い、既定値で続行しない。原因（Settings::InvalidSetting）は cause に残る。
  #   key     壊れていた行のキー
  #   reason  :unknown_key・:invalid_type・:out_of_range（Settings::InvalidSetting の reason）
  class CorruptSetting < StandardError
    attr_reader :key, :reason

    def initialize(key:, reason:)
      @key = key
      @reason = reason
      super("corrupt_setting key=#{key} reason=#{reason}")
    end
  end

  class << self
    # 現在の設定。毎回 DB を読む。
    def current
      Settings.from_raw(SystemSetting.pluck(:key, :value).to_h)
    rescue Settings::InvalidSetting => e
      raise CorruptSetting.new(key: e.key, reason: e.reason)
    end

    # 設定を 1 つ保存する。value は、文字列（管理画面の入力）または型付きの値。保存する文字列は、正規の形（"05" は "5"）。
    # 保存した型付きの値を返す。不正な入力は Settings::InvalidSetting（保存しない）。
    def update!(key:, value:)
      typed_settings = Settings.from_raw({ key => value })
      name = key.to_s
      typed = typed_settings.public_send(name)

      SystemSetting.upsert_all([ { key: name, value: typed.to_s } ], unique_by: :key)
      typed
    end
  end
end
