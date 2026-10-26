# kokeshi練習資料の目次

private-isuを使って、アプリログ・MySQL・Goコードの順に調査方法を学ぶための資料一覧です。練習編は番号順に進み、最後に本番用の攻略ガイドを参照してください。

## 練習編

| 順番 | 資料 | 内容 |
| --- | --- | --- |
| 0 | [Goでログを見て、変更前後のスコアを比べる](kokeshi-practice0.md) | Goアプリのログ、簡単な変更、ベンチマーク結果の見方を練習します。 |
| 1 | [MySQLスロークエリログから調査し、改善を測る](kokeshi-practice1.md) | slow query logの設定・採取、`mysqldumpslow`、ボトルネックの調査とベンチマーク比較を学びます。 |
| 2 | [MySQLのテーブル定義とデータを調べる](kokeshi-practice2.md) | テーブル、行数、インデックス、`EXPLAIN`を確認し、SQLの動きを理解します。 |
| 3 | [Goのpprofで処理を測り、キャッシュ候補を考える](kokeshi-practice3.md) | `go tool pprof`でCPU・メモリを調べ、計測結果からキャッシュの有効性を判断します。 |

## 本番用攻略ガイド

[ISUCON参加用攻略ガイド: AWSサーバーの調査から改善・計測まで](kokeshi-practice-real.md)

本番ガイドは、サーバー状態の確認、ログ・SQL調査、変更、ベンチマークの進め方を素早く引ける手順書です。練習資料のような背景説明やGo pprofの導入方法は各練習編を参照してください。

## 関連ファイル

- [slow query logのサンプル](log-sample/mysql-slow.log)
- [採取したslow query log](log-sample/mysql-slow-captured.log)
- [ISUCON診断スクリプト](scripts/isucon-diag.sh)
