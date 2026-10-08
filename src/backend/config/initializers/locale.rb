# 言語は日本語のみ（issue #8。requirements.md 17 章・CLAUDE.md「日本語版のみ開発する」）。
# 既定の言語を ja にして、config/locales/ja.yml の文言を、画面（ERB の t ヘルパー）から引けるようにする。
# 英語への切り替えの仕組みは持たない（日本語版のみ）。
Rails.application.config.i18n.default_locale = :ja
