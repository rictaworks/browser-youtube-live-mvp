# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# 配信キー・トークン・配信のタイトルを、ログへ出さない（CLAUDE.md の不変条件。requirements.md 6.1・7.3・10.1）。
#   :token          更新トークン・アクセストークン
#   :title          配信のタイトル
#   :ticket         中継への接続チケット
#   /stream.?(name|key)/i  配信キー（YouTube の streamName・stream_key・streamKey）
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :title, :ticket, /stream.?(name|key)/i
]
