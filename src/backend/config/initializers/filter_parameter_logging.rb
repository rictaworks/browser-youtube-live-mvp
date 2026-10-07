# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# 配信キー・トークン・配信のタイトルを、ログへ出さない（CLAUDE.md の不変条件。requirements.md 6.1・7.3・10.1・28.1）。
#   :token          更新トークン・アクセストークン・ID トークン・bot 判定のトークン（recaptcha_token）
#   :title          配信のタイトル
#   :ticket         中継への接続チケット
#   /stream.?(name|key)/i  配信キー（YouTube の streamName・stream_key・streamKey）
#   :secret         共有の秘密値（BFF_SHARED_SECRET・RELAY_SHARED_SECRET）。ヘッダの env のキー（HTTP_X_BFF_SECRET）にも一致する
#   :authorization・:cookie  ヘッダ（env のキー HTTP_AUTHORIZATION・HTTP_COOKIE にも一致する）
#   "x-bff-secret"・"x-relay-secret"  ヘッダの名前（上の :secret と重なるが、名前を明示する）
#   :nonce・:code_verifier  OAuth の途中状態（nonce・PKCE の検証子）
#   :google_sub・:sub_digest  Google の利用者識別子と、その要約値（20.1・28.2）
# 認可コード（code）と state は、短い名前なので、完全一致だけを伏せる（reason_code・error_code など、デバッグに要るものを巻き込まない）。
# ログへ IP アドレスを出さないことは、lib/request_logger.rb（要求の開始のログ）が担う。
oauth_state_filter = /\Astate\z/i

Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :title, :ticket, /stream.?(name|key)/i,
  /\Acode\z/i, oauth_state_filter, :nonce, :code_verifier,
  :authorization, :cookie, "x-bff-secret", "x-relay-secret",
  :google_sub, :sub_digest
]

# Active Record の filter_attributes（モデルの inspect・SQL のログのバインド値の伏せ字）は、filter_parameters から作られる。
# OAuth の state は、パラメータとしては伏せるが、モデルの state 列（配信の状態・YouTube の接続状態・健全性の標本の状態）は、
# 機密ではなく、デバッグに要る値なので、モデル側では伏せない（spec/models/sensitive_attributes_spec.rb が、確かめる）。
ActiveSupport.on_load(:active_record) do
  self.filter_attributes -= [ oauth_state_filter ]
end
