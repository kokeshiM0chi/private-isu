# 変更ごとの性能比較

`master` の改善なしの結果を基準にして、`kokeshi` ブランチで改善と計測を繰り返す。

## ブランチの役割

| ブランチ | 役割 |
| --- | --- |
| `master` | 本家のまま、改善なし。基準スコアの対象 |
| `kokeshi` | すべての変更を積み重ねる。コード、構成、言語の変更を含む。文書と計測結果も置く |

基準の計測はツールのある `kokeshi` で行う。計測時点で `webapp/golang` と `benchmarker` は `master`（`730e8a4`）と差分がない。

## 変更の単位

1回の変更は、アプローチの分類1つとする。個々の修正の数では数えない。たとえば、複数のテーブルにインデックスを追加しても、1回の変更として扱う。計測もこの単位で行い、アプローチごとの改善幅を確かめる。

| 分類 | 内容の例 |
| --- | --- |
| `db-index` | テーブルのインデックス追加 |
| `db-query` | N+1の解消、クエリの書き換え |
| `db-config` | バッファプールなどのDB設定 |
| `app-cpu` | 外部コマンド呼び出しの廃止、計算処理の見直し |
| `app-connection` | 接続プール、プレースホルダ、往復回数の削減 |
| `data-memory` | データをメモリに置き、変更差分だけを同期する |
| `cache` | memcachedやアプリ内のキャッシュ |
| `static` | 画像のファイル化、nginxからの配信 |
| `infra` | nginxの設定、振り分け、配置 |
| `language` | 実装言語の変更 |

表にない分類は、必要に応じて追加する。

## 1回の改善の流れ

```bash
# 1. 分類を1つ決めて改善する
# 2. コミットする（結果とコミットを対応させるため）
git add -A
git commit -m "perf-02 db-index: Add indexes for comments and posts"

# 3. 計測する。名前は perf-連番-分類 にする
scripts/practice.sh measure perf-02-db-index 0     # 遅延なしで3回
scripts/practice.sh measure perf-02-db-index 100   # 100msで3回

# 4. 結果を確認して記録する
scripts/practice.sh compare
# docs/perf-00-history.md に1行追加し、docs/perf-連番-分類.md に詳細を書く
git add results docs
git commit -m "perf-02 db-index: Record results"
```

連番は `docs/perf-*.md` と共通にする。`perf-01` は基準である。変更と結果のコミットメッセージの先頭には、同じ `perf-連番 分類:` を付ける。どの修正の結果かは、`docs/perf-00-history.md` と `results/summary.tsv` の `commit` 列で追える。

`measure` は、アプリの再ビルド、DBの基準データへの復元、SQLの適用、遅延の設定、ベンチ、結果の記録を順に行う。

## DBの変更

Gitで戻るのはコードだけで、インデックスなどのDBの状態はColimaのボリュームに残る。計測のたびにDBを基準データ（`private-isu_mysql_base`）へ戻すので、DBの変更は手で実行せず、`webapp/sql-changes/` にSQLファイルとして追加する。

```text
webapp/sql-changes/01-db-index.sql
webapp/sql-changes/02-....sql
```

ファイルは名前の順に毎回すべて適用されるので、改善が積み重なった状態で計測される。

## 結果の記録

| ファイル | 内容 |
| --- | --- |
| `results/summary.tsv` | 時刻、名前、ブランチ、コミット、未コミット変更の有無、遅延、中央値、各回のスコア |
| `results/<時刻>-<名前>-<遅延>ms.jsonl` | ベンチの出力そのまま |

`state` が `dirty` の行は未コミットの変更を含むので、コミットだけでは再現できない。

## 比較の注意

- 比較するのは、同じ遅延の中央値どうしにする
- 1回の変更に複数の分類を混ぜない
- 差が各回のばらつきより小さいときは、効果があるとは言えない
- スコアが上がっても、失敗が増えていないか確認する

## 構成や言語を変えるとき

- 言語の変更: `webapp/compose.kokeshi.yml` の `build.context` を変える
- nginxの設定: `webapp/etc/nginx/conf.d` は `measure` で反映される
- MySQLの設定: 今は設定ファイルを読み込んでいない。変更するときは `webapp/compose.kokeshi.yml` にマウントを追加する
- 画像のファイル化: DB以外の状態が増えるので、`measure` で初期状態に戻らない。実施するときに、ファイルの再生成も手順に加える
