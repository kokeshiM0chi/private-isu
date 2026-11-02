# 資料の目次

private-isuの練習で作った資料の一覧である。アプリとDBの間に遅延がある構成を想定し、性能改善を変更ごとに検証している。

## まず読むもの

| 知りたいこと | 資料 |
| --- | --- |
| 改善の全体像と結果 | [perf-00-report.md](perf-00-report.md) |
| 計測の進め方 | [ops-01-measure-workflow.md](ops-01-measure-workflow.md) |
| 遅延で再現している構成 | [arch-01-latency-topology.md](arch-01-latency-topology.md) |

## 準備

| 資料 | 分かること |
| --- | --- |
| [setup-01-preparation.md](setup-01-preparation.md) | 練習の方針、構成案、AWSと手元のMacで準備するもの |

## 構成

| 資料 | 分かること |
| --- | --- |
| [arch-01-latency-topology.md](arch-01-latency-topology.md) | 遅延で再現している物理配置の図、段階ごとの構成、設定との対応、再現していないこと |

## 運用と手順

| 資料 | 分かること |
| --- | --- |
| [ops-01-measure-workflow.md](ops-01-measure-workflow.md) | ブランチの役割、変更の単位と分類、計測と記録の手順 |
| [ops-02-image-baseline.md](ops-02-image-baseline.md) | 画像ファイルを計測のたびに初期状態へ戻す理由と方法 |

## 性能改善

| 資料 | 分かること |
| --- | --- |
| [perf-00-report.md](perf-00-report.md) | 全段階の結果、環境の問題、未確認の点。現在は暫定値 |
| [perf-00-history.md](perf-00-history.md) | 変更とコミット、スコアの対応表。現在は `perf-02` まで |
| [perf-01-baseline.md](perf-01-baseline.md) | 改善なしの基準スコア、100msで失敗する理由 |
| [perf-02-db-index.md](perf-02-db-index.md) | インデックス追加の内容と結果 |

`perf-03` から `perf-07` の個別の資料は、確定値が出てから追加する。それまでの内容はレポートにまとめている。

## 資料以外の記録

| 場所 | 内容 |
| --- | --- |
| `results/summary.tsv` | 全計測の一覧 |
| `results/*.jsonl` | ベンチの出力そのまま |
| `scripts/practice.sh` | 起動、計測、遅延の切り替え |
| `scripts/measure-all.sh` | 全段階の一括計測 |
| `scripts/clean-local-disk.sh` | Macのキャッシュの掃除 |

## ファイル名の規則

`<prefix>-<連番2桁>-<内容>.md` の形式で、連番はprefixごとに振る。

| prefix | 内容 |
| --- | --- |
| `setup` | 準備、環境構築 |
| `arch` | 構成の設計、学習メモ |
| `ops` | 運用、手順 |
| `perf` | 性能改善の計測と結果 |
