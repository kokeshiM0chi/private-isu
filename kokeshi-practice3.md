# 練習 3: MySQLのテーブル定義とデータを調べる

slow query logに出たSQLを理解するには、テーブルの定義、インデックス、実際のデータを確認すると役立ちます。この手順では、Goアプリが接続している`isuconp`データベースを例にします。

## 1. MySQLの対話画面に入る

`webapp`ディレクトリで実行します。

```sh
docker compose exec -it mysql mysql -uroot -proot isuconp
```

接続できると`mysql>`プロンプトが表示されます。以下のSQLは、この対話画面に入力します。終了するときは`\q`を入力します。

## 2. テーブル一覧を見る

```sql
SHOW TABLES;
```

private-isuの主なテーブルは`users`、`posts`、`comments`です。

- `users`: アカウント情報
- `posts`: 投稿の本文や投稿者、投稿日時、画像データ
- `comments`: 投稿に付いたコメント、投稿者、コメント日時

## 3. テーブル定義を見る

`DESCRIBE`は列名、データ型、NULL可否、キーなどを簡潔に表示します。

```sql
DESCRIBE users;
DESCRIBE posts;
DESCRIBE comments;
```

キーやテーブル定義を詳しく見るには、`SHOW CREATE TABLE`を使います。`\G`を末尾に付けると、横長の結果を縦向きで表示します。

```sql
SHOW CREATE TABLE comments\G
```

ここでは列の型、主キー、ユニーク制約、インデックスの定義を確認できます。slow query logに現れた`post_id`、`created_at`などがどう定義されているかを見ます。

## 4. インデックスを見る

```sql
SHOW INDEX FROM comments;
```

`Key_name`はインデックス名、`Column_name`はそのインデックスに含まれる列、`Seq_in_index`は列の順番です。複合インデックスでは列の順番が重要です。たとえば`(post_id, created_at)`なら、`post_id`だけで絞る検索と、`post_id`で絞って`created_at`順に読む検索の両方で使える可能性があります。

## 5. 件数とサンプルデータを見る

まず、各テーブルの行数を確認します。

```sql
SELECT COUNT(*) FROM users;
SELECT COUNT(*) FROM posts;
SELECT COUNT(*) FROM comments;
```

数行の内容は`LIMIT`を付けて確認します。パスワードハッシュや大きな画像データは表示せず、調査に必要な列だけを選びます。

```sql
SELECT id, account_name, del_flg
FROM users
LIMIT 5;

SELECT id, user_id, mime, created_at, LEFT(body, 80) AS body
FROM posts
ORDER BY id DESC
LIMIT 5;

SELECT id, post_id, user_id, created_at, LEFT(comment, 80) AS comment
FROM comments
ORDER BY id DESC
LIMIT 5;
```

`posts`には画像データの`imgdata`列があります。バイナリ画像は大きいため、内容を見る目的がなければ`SELECT *`で取得しないようにします。

特定の投稿にコメントがいくつあるかは、次のように確認できます。

```sql
SELECT post_id, COUNT(*) AS comment_count
FROM comments
WHERE post_id = 9980
GROUP BY post_id;
```

コメント数の多い投稿を探す場合は、次を使います。

```sql
SELECT post_id, COUNT(*) AS comment_count
FROM comments
GROUP BY post_id
ORDER BY comment_count DESC
LIMIT 10;
```

## 6. slow query logのSQLを実行計画で調べる

slow query logに出ていたSQLを`EXPLAIN`に渡すと、MySQLがどのインデックスを使い、何行程度を調べると見積もっているか確認できます。

```sql
EXPLAIN
SELECT COUNT(*) FROM comments WHERE post_id = 9980;

EXPLAIN
SELECT * FROM comments
WHERE post_id = 9980
ORDER BY created_at DESC
LIMIT 3;
```

主に見る列は次のとおりです。

- `type`: 参照方法。`ALL`はテーブル全体を読む計画です。
- `key`: 使用予定のインデックス。`NULL`なら使用するインデックスがない計画です。
- `rows`: 調査する行数の見積もりです。実際の行数とは異なる場合があります。
- `Extra`: 並べ替えなど、追加処理に関する情報です。`Using filesort`が表示されることがあります。

`EXPLAIN`の見積もりとslow query logの`Rows_examined`（そのSQLの処理中にテーブルから調べた行数の実測値）を比べます。ログ例では、コメント3件を返すSQLがテーブルから約100,004行を調べていました。これは`post_id`による絞り込みに適切なインデックスが使われていない可能性を示します。`SHOW INDEX`でも列と順序を確認してから、変更を検討します。

## 7. ログから追加調査へ進む考え方

1. slow query logで`Query_time`が長いSQLを探します。
2. `Rows_sent`（返したレコード数）と`Rows_examined`（処理中にテーブルから調べた行数）を比較します。少数のレコードを返すのに多数のテーブル行を調べていれば、絞り込みに注目します。
3. SQLの`WHERE`、`ORDER BY`、`JOIN`に使われる列を確認します。
4. `SHOW CREATE TABLE`と`SHOW INDEX`で列定義とインデックスを確認します。
5. `EXPLAIN`で実際に選ばれるアクセス方法やインデックスを確認します。
6. 原因に対応する変更を一つだけ行い、同じSQLの実測値とベンチマーク結果を比較します。

ログだけで原因を決めつけず、テーブル定義と実行計画で仮説を確かめるのがポイントです。

## 8. 注意点

- `COUNT(*)`や`GROUP BY`は多数の行を調べる場合があります。大きなテーブルに対して何度も実行しないようにします。
- `SELECT *`は不要な列や大きなバイナリ列まで取得することがあります。サンプル確認では列を指定します。
- `EXPLAIN`は実行計画を確認するコマンドです。負荷の高いSQLを実際に計測する前に、まず`EXPLAIN`で計画を確認します。
- スキーマやインデックスを変更する前に現在の定義を記録し、同じ名前のインデックスを重複して追加しないようにします。
- ベンチマークを測るときはslow query logをOFFにし、変更前後で同じデータと環境を使います。
