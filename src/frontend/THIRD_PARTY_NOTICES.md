# サードパーティのライセンス表示

このアプリケーション（`src/frontend/`）が、ビルドへ含めて配布する第三者の著作物のライセンス表示です。

## 書体

次の 3 書体は、`app/layout.tsx` の `next/font/google` で、ビルド時に Google Fonts から取得し、このアプリケーション自身のドメイン（`/_next/static/media/`）から配信します（自己ホスト）。実行時に、ブラウザは Google へ接続しません。取得できなければ、ビルドは失敗します。3 書体とも SIL Open Font License 1.1（下に全文）の下にあり、同梱・再配布できます。

| 書体 | 著作権表示 | ライセンス |
|---|---|---|
| Inter | Copyright 2020 The Inter Project Authors (https://github.com/rsms/inter) | SIL Open Font License 1.1 |
| Noto Sans JP | Copyright 2014-2021 Adobe (http://www.adobe.com/), with Reserved Font Name 'Source' | SIL Open Font License 1.1 |
| Playfair Display | Copyright 2017 The Playfair Display Project Authors (https://github.com/clauseggers/Playfair-Display), with Reserved Font Name "Playfair Display" | SIL Open Font License 1.1 |

著作権表示とライセンスの全文の出どころは、Google Fonts のリポジトリ（https://github.com/google/fonts の `ofl/inter/OFL.txt`・`ofl/notosansjp/OFL.txt`・`ofl/playfairdisplay/OFL.txt`）です。3 つのファイルのライセンスの本文は、同一です。

### SIL Open Font License 1.1

```
-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded, 
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

## アイコン（Font Awesome Free）

アイコンは、Font Awesome Free の npm パッケージ（`@fortawesome/fontawesome-svg-core`・`@fortawesome/free-solid-svg-icons`・`@fortawesome/free-regular-svg-icons`・`@fortawesome/free-brands-svg-icons`・`@fortawesome/react-fontawesome`）を使い、SVG として描画します。CDN は使いません。書体ファイル（Web フォント）は使いません。

- Font Awesome Free 7.3.1 by @fontawesome - https://fontawesome.com
- ライセンス: https://fontawesome.com/license/free （アイコン: CC BY 4.0、書体: SIL OFL 1.1、コード: MIT License）
- Copyright 2026 Fonticons, Inc.

アイコンの SVG・JS ファイルは、Creative Commons Attribution 4.0 International License（https://creativecommons.org/licenses/by/4.0/ ）の下にあります。コードは MIT License（https://opensource.org/licenses/MIT ）の下にあります。各パッケージは、ライセンスの全文（`LICENSE.txt`）を同梱しており、帰属表示のコメントを含みます。
