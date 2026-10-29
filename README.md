# inkstone.nvim — 硯

日本語を読みやすく、長い Markdown も扱いやすくする Neovim プラグイン。
[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) をベースにした独立した fork です。上流プラグインのインストールは不要です。

## 実装済み

- 見出し、コード、表、引用、リスト、リンク、チェックボックス、callout など、ベースの描画機能。
- 大きなコードブロックでも、背景と余白の装飾は表示範囲＋マージンに限定。
- ハイライトをまとめてソートし、使わないノード本文の取得を遅延。
- 行幅の要約を上限付きでキャッシュ。編集・幅に関係するオプション変更・バッファ破棄で無効化。
- Markdown 解析は非同期。編集・画面の差し替えで古くなった結果は破棄。
- 更新が連続しても最後のフレームを描画し、破棄時にタイマーとキャッシュを解放。
- 表のセルは **BudouX の文節境界＋基本的な禁則処理**で折り返し。
- 結合濁点、半角カナの濁点、ZWJ 絵文字、国旗、肌色修飾子などを分断しない表示単位。
- 日本語レイアウトをほかのプラグインから使う Lua API。
- Kitty 向けに、半角カナ＋濁点／半濁点の表示幅を保つ描画補正。

通常段落と表セルは、日本語の文節を優先して画面幅に折り返します。段落は `paragraph = { wrap = true, join = false }` が既定で、元の改行を保持します。通常改行の連結は `join = true` で個別に有効化できます。ソースバッファの文字列は書き換えません。

## 必要なもの

- Neovim **0.11 以上**。現在の動作確認環境は 0.13 開発版。
- Tree-sitter の `markdown` / `markdown_inline` パーサー。
- コードの言語別ハイライトや数式を使う場合は、その言語のパーサーや従来の数式変換ツール。

BudouX の Lua 実装とモデルは専用名前空間に同梱済みです。実行時のネットワーク接続、外部の BudouX プラグイン、Rust バイナリは不要です。

## ローカルで使う

lazy.nvim の例:

```lua
{
  dir = vim.fn.expand('~/workspace/inkstone.nvim'),
  name = 'inkstone.nvim',
  main = 'inkstone',
  ft = { 'markdown' },
  opts = {
    anti_conceal = { enabled = false },
    code = { sign = false, width = 'block', left_pad = 1, right_pad = 1 },
    pipe_table = {
      cell = 'trimmed',
      wrap = true,
      japanese = { enabled = true, budoux = true },
    },
  },
}
```

同じバッファでは従来の `render-markdown.nvim` を無効にして使ってください。設定項目の多くは引き継いでいますが、モジュール・コマンド・ハイライト名は別です。

```vim
:Inkstone enable
:Inkstone toggle
:Inkstone preview
:checkhealth inkstone
```

- Lua: `require('inkstone').setup(opts)`
- ハイライト: `InkstoneH1`、`InkstoneCode`、`InkstoneTableHead` など。
- ベースの設定一覧: [doc/upstream-configuration.md](doc/upstream-configuration.md)
- 組み込みヘルプ: `:help inkstone`

このリポジトリの作成だけでは、既存の dotfiles や起動中の Neovim のプラグイン構成は変更されません。

## 日本語レイアウト API

```lua
local text = require('inkstone.text')

text.segment('今日は天気がいいから散歩しましょう。')
-- { '今日は', '天気が', 'いいから', '散歩しましょう。' }

text.wrap('「日本語」の表を、読みやすく。', 12)
-- 各要素の表示幅が 12 カラム以下になる文字列の配列
```

幅は Neovim の `strdisplaywidth()` に合わせます。禁則とカラム幅を同時に満たせない極端に狭い列では、幅と処理の完了を優先します。禁則処理は基本的な文字集合に対応しており、JIS X 4051 全体への完全準拠を意味しません。表示単位も対応ケースをテストしていますが、Unicode UAX #29 全体への完全準拠ではありません。`text.wrap` に1表示単位の幅より小さい幅を指定した場合はエラーになります。

## Kitty 向け表示補正

Kitty が `ｶﾞ` を1セル、Neovim が2セルと扱う環境では、表の罫線などがずれます。
`display_compat` は描画時だけ `ｶﾞ → ガ`、`ﾊﾟ → パ` のように置き換え、
Neovim が確保する幅に合わせます。半角カナ56文字と濁点・半濁点の112通りを扱い、
合成文字がない `ｱﾞ` などは全角の基底文字＋結合濁点で表示します。
通常行・表の各表示方式・折り返し後の仮想行に適用します。

```lua
require('inkstone').setup({
  display_compat = {
    enabled = 'auto', -- Kitty 環境変数がある場合に有効。true / false でも指定可
    kana = true,
    replacements = {}, -- 必要に応じて ['é'] = 'é' のような表示ルールを追加
  },
})
```

バッファの文字列・検索・ヤンク・保存内容は変わりません。tmux や Kitty 本体への
パッチ、OSC の直接送信は不要です。補正の対象は Inkstone が描画するバッファです。
プラグインを無効にした表示や、通常の未処理スクラッチには適用しません。
編集時の anti-conceal が働く行では、他の装飾と同様に元の表示へ戻ります。
全 Unicode の幅の違いを自動検出する機能ではありません。

独自ルールは1表示単位を対象にし、Neovim 上の表示幅が変わらないものだけ適用します。
改行・タブを含むルール、幅が変わるルール、不完全な表示単位への部分一致は適用しません。
ハイライト境界をまたぐ置換は基底文字の色を使い、既に隠された本文を再表示しません。

## 開発

```sh
# Markdown / Lua パーサーをインストールした Neovim で実行
make test

# Plenary がある場合: 引き継いだ単体テスト
make unit

# Plenary、mini.icons、追加のパーサーがある場合: 上流由来の描画テスト
make upstream

# 合成ケースの CPU / 装飾 API 計測
make bench

# 任意: 元の実装との表示範囲内の装飾一致を確認
INKSTONE_UPSTREAM_RTP=/path/to/render-markdown.nvim make reference

# 任意: 標準 tmux → Kitty の実パーサーで表示・再描画・コピーを確認
make terminal
```

パーサーの置き場所は `INKSTONE_PARSER_RTP`、テスト依存は `INKSTONE_PLENARY_RTP` と `INKSTONE_MINI_ICONS_RTP` で指定できます。追加のパーサー置き場には `INKSTONE_EXTRA_PARSER_RTP` を使えます。テスト実行でパーサーを勝手にインストールしません。

計測の詳細は [doc/performance.md](doc/performance.md)、構成と次の開発対象は [doc/architecture.md](doc/architecture.md) を参照してください。

## ベースと参考実装

- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim): MIT。描画エンジンのベース。
- [md-render.nvim](https://github.com/delphinus/md-render.nvim): MIT。日本語・CJK の折り返し設計と禁則文字集合の参考。
- [budoux.lua](https://github.com/delphinus/budoux.lua): Apache-2.0。モデルを含めて内部名前空間へ同梱。
- [Google BudouX](https://github.com/google/budoux): Apache-2.0。文節分割モデルの原著作物。

取り込み元のリビジョンは [UPSTREAM.json](UPSTREAM.json)、ライセンスと変更点は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) に記録しています。
