# 変更ごとの性能比較

改善をブランチごとに分け、同じ状態のDBから計測して比較する。

## 考え方

Gitで戻るのはコードだけで、インデックスなどのDBの状態はColimaのボリュームに残る。そのため、次の2つを固定する。

| 対象 | 固定する方法 |
| --- | --- |
| コード | `kokeshi` から改善ごとにブランチを切る。`kokeshi` のアプリは本家の `master` と同じ |
| DB | 計測のたびに基準データ（`private-isu_mysql_base` ボリューム）へ戻す |

DBの変更は手で実行せず、ブランチの `webapp/sql-changes/` にSQLファイルとして置く。ファイルは名前の順に適用される。これでDBの変更もブランチに含まれる。

## 手順

```bash
git switch kokeshi
git switch -c perf/01-comment-index

# 例: インデックスを追加する
mkdir -p webapp/sql-changes
echo 'CREATE INDEX idx_comments_post_created ON comments (post_id, created_at);' \
  > webapp/sql-changes/01-comment-index.sql
git add webapp/sql-changes
git commit -m "Add comment index"

scripts/practice.sh measure comment-index 0     # 遅延なしで3回
scripts/practice.sh measure comment-index 100   # 100msで3回
scripts/practice.sh compare                     # 一覧を表示
```

`measure` は、アプリの再ビルド、DBの基準データへの復元、SQLの適用、遅延の設定、ベンチ、結果の記録を順に行う。

## 結果の記録

`results/` はGitの管理外なので、ブランチを切り替えても消えない。Colimaではなく、Mac上に残る。

| ファイル | 内容 |
| --- | --- |
| `results/summary.tsv` | 時刻、名前、ブランチ、コミット、未コミット変更の有無、遅延、中央値、各回のスコア |
| `results/<時刻>-<名前>-<遅延>ms.jsonl` | ベンチの出力そのまま |

`state` が `dirty` の行は、未コミットの変更を含むので、コミットだけでは再現できない。

## 比較の注意

- 比較するのは、同じ遅延の中央値どうしにする
- 改善は積み上げて計測する。前の改善を含むブランチから次のブランチを切る
- 差が各回のばらつきより小さいときは、効果があるとは言えない
- 画像をファイルへ移すなど、DB以外の状態を変える改善では、`measure` がそのファイルを戻さない。別途手順を決める
