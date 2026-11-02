# 基準スコア

計測日: 2026-11-02

Macのcolimaで、改善前のGo実装を計測した。別環境のスコアとは比べられない。同じ環境での改善前後の比較に使う。

## 環境

| 項目 | 値 |
| --- | --- |
| Colima | 4 CPU、メモリ5GiB |
| app、mysql | 各1 CPU、メモリ1GiB（`webapp/compose.yml` の制限） |
| ベンチ | 同じVMのコンテナから実行 |
| InnoDBバッファプール | 128MB |
| データ量 | posts約1.2GB（画像BLOB込み） |

## 手順

```bash
scripts/practice.sh up
scripts/practice.sh bench 3
scripts/practice.sh delay 100
scripts/practice.sh bench 3
scripts/practice.sh delay off
```

遅延はappからmysql、memcachedへの通信だけに入る。アプリを再ビルドすると遅延は外れる。

## 結果

### 改善前（インデックスなし）

| 条件 | 1回目 | 2回目 | 3回目 |
| --- | --- | --- | --- |
| 遅延なし | score 0（成功293、失敗59） | score 0（成功309、失敗60） | score 0（成功357、失敗59） |
| 100ms | score 0、`pass:false`（成功4、失敗6） | score 0、`pass:false`（成功4、失敗6） | score 0、`pass:false`（成功4、失敗6） |

遅延なしでも `GET /` と `POST /login` などが10秒でタイムアウトする。

### 参考: 以前のインデックスが残っていた状態

`comments(post_id, created_at)` のインデックスが残った状態では、遅延なしで13,874、2,075、10,586だった。1本のインデックスで大きく変わるが、ばらつきも大きい。

このインデックスは基準の計測前に削除した。作り直す場合は次を実行する。

```sql
CREATE INDEX idx_comments_post_created ON comments (post_id, created_at);
```

## 注意

`/initialize` は追加行を消すだけで、インデックスや画像の移行は元に戻らない。改善前に戻すには、インデックスなどを手で戻すか、初期データを入れ直す。
