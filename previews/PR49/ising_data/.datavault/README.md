# .datavault/

**このディレクトリを削除しないでください。**

DataVault はこのディレクトリ内の `*.log.toml` ファイルを、`outdir` 配下に
ある全 study データの discovery anchor として使用します。
DataVault のすべてのバージョンが次の凍結契約に依存しています:

  1. `{outdir}/.datavault/` というディレクトリが存在する
  2. 各 (study, run) ペアが `{project_name}/{run_name}.log.toml` を持つ
  3. 各 `*.log.toml` には `[meta].log_toml_version`（整数）がある

このディレクトリ内のファイルを削除・改名すると、DataVault がデータを
永久に追跡できなくなる可能性があります。バックアップではこのディレクトリ
を内容ごとそのまま保全してください。

このファイル (README.md) は DataVault が初回のみ自動生成しますが、
以降は人間の編集を尊重して上書きしません。自由に追記して構いません。
