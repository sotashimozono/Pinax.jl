module Pinax

using ParamIO
using DataVault

# 設計仕様は notes/(00–10)を参照。
# 実装はインクリメンタル: 文書モデル + 構造マクロ(本ファイル群)→ resolve → render → cache → theme …

include("document.jl")

# 構造マクロ(原稿 DSL)
export @pinaxsetup,
    @debug_mode,
    @bibliography,
    @newcommand,
    @page,
    @section,
    @figure,
    @caption,
    @desc,
    @thumbnail,
    @no_thumbnail,
    @md_str

end # module Pinax
