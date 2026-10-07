# frozen_string_literal: true

module StartAdmission
  # 開始の受付の入力（requirements.md 9.1。契約 http-api.md の POST /api/broadcasts の要求）。
  #   title           配信のタイトル。1〜100 文字（Unicode のコードポイントの数）・山括弧（<・>）を含まない・空白だけは不可
  #   privacy_status  公開範囲。public・unlisted・private の 3 値
  #   made_for_kids   子ども向けの申告。true・false の真偽が必須（未選択 = nil は不備）
  # 値は、検証しないまま保持する（不備のある値も保持し、invalid_fields が不備の項目名を返す）。指定しない項目は nil（不備）。
  # bot 判定のトークンは含めない（順 3 の bot 判定で、サーバー側で検証する）。
  # タイトルは秘密として扱う（ログ・例外・測定イベントへ出さない）。この型は、タイトルを例外・メッセージに含めない。
  class Input < Data.define(:title, :privacy_status, :made_for_kids)
    PRIVACY_STATUSES = %w[public unlisted private].freeze

    # タイトルの文字数（Unicode のコードポイントの数。両端を含む）。JavaScript の length（UTF-16）とは数え方が違う
    TITLE_LENGTH = (1..100)

    # タイトルのバイト数の上限（UTF-8 の 1 文字は最大 4 バイト）。これを超える文字列は、走査せずに不備にする
    TITLE_MAX_BYTES = TITLE_LENGTH.end * 4

    # inspect・to_s に出す、タイトルの代わりの表記（Rails のパラメーターのフィルターと同じ）
    FILTERED = "[FILTERED]"

    # 山括弧（ASCII の < と >）
    ANGLE_BRACKETS = /[<>]/

    # 空白（Unicode の空白）と、幅のない空白（U+200B・U+200C・U+200D・U+2060・U+FEFF）だけの文字列。空文字列を含む
    BLANK = /\A[[:space:]\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}]*\z/

    def initialize(title: nil, privacy_status: nil, made_for_kids: nil)
      super(title: frozen_copy(title), privacy_status: frozen_copy(privacy_status), made_for_kids: made_for_kids)
    end

    # 不備のある項目名（title・privacy_status・made_for_kids の順）。不備がなければ空。凍結した配列。
    def invalid_fields
      invalid = []
      invalid << :title unless valid_title?
      invalid << :privacy_status unless PRIVACY_STATUSES.include?(privacy_status)
      invalid << :made_for_kids unless [ true, false ].include?(made_for_kids)
      invalid.map(&:name).freeze
    end

    # タイトルを含めない（ログ・例外へ、配信のタイトルを出さない。CLAUDE.md の不変条件）。to_h は、判定のために持つ。
    def inspect
      "#<#{self.class.name} title=#{FILTERED} privacy_status=#{privacy_status.inspect} made_for_kids=#{made_for_kids.inspect}>"
    end
    alias_method :to_s, :inspect

    private

    # UTF-8（または ASCII だけ）の正しい文字列で、文字数が範囲内、山括弧なし、空白だけでない。
    def valid_title?
      return false unless title.is_a?(String) && title.bytesize <= TITLE_MAX_BYTES && title.valid_encoding?
      return false unless title.encoding == Encoding::UTF_8 || title.ascii_only?

      TITLE_LENGTH.cover?(title.length) && !title.match?(ANGLE_BRACKETS) && !title.match?(BLANK)
    end

    def frozen_copy(value)
      value.is_a?(String) && !value.frozen? ? value.dup.freeze : value
    end
  end
end
