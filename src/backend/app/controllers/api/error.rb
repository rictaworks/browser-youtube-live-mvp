# API のエラー（issue #7。src/contracts/http-api.md 1.6）。Api::BaseController が、契約の形（{"error":{"code","details"}}）の
# JSON にして返す。画面に出す文言を含まない（符号と数値だけ）。
#
#   Forbidden         403 forbidden        X-BFF-Secret が欠落・不一致（本文に手がかりを書かない）
#   CsrfInvalid       403 csrf_invalid     X-BL-Client・X-CSRF-Token・Origin の不備
#   NotLoggedIn       401 not_logged_in    セッションが無い・無効
#   NotFound          404 not_found        存在しない（他のアカウントのレコードも、存在しないものとして扱う）
#   InvalidInput      422 invalid_input    要求を解釈できない・必須の項目が無い・値が不正（details の fields に、項目名）
#   UnsupportedEvent  422 unsupported_event  ブラウザから送れない種別の測定イベント
#   RateLimited       429 rate_limited     頻度の上限（details の retry_at は、枠が空く時刻。JST の ISO 8601）
#   InternalError     500 internal_error   想定外の例外（詳細を応答に出さない）
#
# reason は、ログ用の符号（応答には出さない。例: :bff_secret_rejected・:token_mismatch）。メッセージは、符号だけ（値を含めない）。
module Api
  class Error < StandardError
    attr_reader :code, :status, :details, :reason

    def initialize(code:, status:, details: {}, reason: nil)
      @code = code
      @status = status
      @details = details
      @reason = reason
      super(code)
    end

    class Forbidden < Error
      def initialize(reason: nil)
        super(code: "forbidden", status: 403, reason: reason)
      end
    end

    class CsrfInvalid < Error
      def initialize(reason: nil)
        super(code: "csrf_invalid", status: 403, reason: reason)
      end
    end

    class NotLoggedIn < Error
      def initialize(reason: nil)
        super(code: "not_logged_in", status: 401, reason: reason)
      end
    end

    class NotFound < Error
      def initialize(reason: nil)
        super(code: "not_found", status: 404, reason: reason)
      end
    end

    class InvalidInput < Error
      # fields は、不備のある項目名の配列（省略できる）
      def initialize(fields: nil, reason: nil)
        details = fields.nil? || fields.empty? ? {} : { "fields" => fields.map(&:to_s) }
        super(code: "invalid_input", status: 422, details: details, reason: reason)
      end
    end

    class UnsupportedEvent < Error
      def initialize(reason: nil)
        super(code: "unsupported_event", status: 422, reason: reason)
      end
    end

    class RateLimited < Error
      # retry_at は、頻度の枠が空く時刻（Time）。秒に切り上げ、JST（+09:00）の ISO 8601 で返す
      def initialize(retry_at:, reason: nil)
        super(code: "rate_limited", status: 429, details: { "retry_at" => retry_at.ceil.in_time_zone.iso8601 }, reason: reason)
      end
    end

    class InternalError < Error
      def initialize(reason: nil)
        super(code: "internal_error", status: 500, reason: reason)
      end
    end
  end
end
