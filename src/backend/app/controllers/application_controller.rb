# アプリケーションの画面（管理画面。BASIC 認証。requirements.md 19 章）のコントローラの親。
#
# /api のコントローラの親は、これではなく Api::BaseController（ActionController::API。BFF の確認・CSRF・エラーの形を実装する。issue #7）。
# どの経路にも当てはまらない要求への 404 は、コントローラではなく、Rack の部品（NotFoundApp。config/routes.rb の最後の経路）が返す。
# 管理画面の issue が、この親に、BASIC 認証などを足す。
class ApplicationController < ActionController::Base
end
