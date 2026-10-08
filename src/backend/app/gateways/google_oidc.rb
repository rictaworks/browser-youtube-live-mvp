# Google ログイン（OpenID Connect）の共通の型（issue #8）。GoogleOidcClient（実物）と FakeGoogleOidc（開発・テストの疑似）が共有する。
module GoogleOidc
  # 認証の結果。保持するのは、Google の利用者識別子（sub）だけ（メール・氏名・プロフィールを持たない。requirements.md 7.1・28.2）。
  # トークン（アクセス・ID）は、持たない・返さない。sub を、ログ・例外の報告へ出さない（inspect に出さない）。
  Identity = Data.define(:sub) do
    def inspect
      "#<#{self.class.name} [FILTERED]>"
    end

    def to_s
      inspect
    end
  end

  # 認証の失敗。reason は、失敗の理由の符号（トークン・コード・sub を含めない）。ログと、利用者への応答の分岐（oauth_failed）に使う。
  #   token_endpoint_unreachable  トークンエンドポイントに到達できない（タイムアウト・接続・TLS）
  #   token_exchange_rejected     トークンエンドポイントが、コードの交換を受け付けなかった（200 以外）
  #   token_response_invalid      トークンエンドポイントの応答が、解釈できない
  #   id_token_missing            応答に ID トークンが無い
  #   jwks_unavailable            公開鍵（JWKS）を取得できない
  #   id_token_malformed          ID トークンが、JWT として読めない
  #   algorithm_invalid           署名のアルゴリズムが、RS256 ではない
  #   signature_invalid           署名が合わない
  #   signing_key_unknown         署名の鍵（kid）が、公開鍵の中に無い
  #   issuer_invalid · audience_invalid · expired · issued_in_future · nonce_mismatch · subject_invalid · claim_missing · id_token_invalid
  # 疑似（FakeGoogleOidc）は、code_invalid · code_expired · pkce_mismatch · redirect_uri_mismatch も使う。
  class AuthenticationFailed < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("google authentication failed: #{reason}")
    end
  end
end
