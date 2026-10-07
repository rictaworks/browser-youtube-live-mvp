# Be sure to restart your server when you modify this file.

# 語の綴りの規則（ファイル名 <-> 定数名）。Zeitwerk は、ファイル名から定数名を、この規則で決める。
#   "OAuth"  oauth_state_cookie.rb が OAuthStateCookie を定義する（Cookie bl_oauth。issue #7。requirements.md 7.1）。
#            この規則が無いと、Zeitwerk は OauthStateCookie を期待する。
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.acronym "OAuth"
end
