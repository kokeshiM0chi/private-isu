# 練習 2: MySQLスロークエリログから調査し、改善を測る（Go）

この練習では、Go版アプリを動かしたままMySQLのスロークエリログを採取し、ログから時間のかかるSQLを見つけ、追加調査をして改善前後を比較します。

今回のログは、アプリのGoログではなく**MySQLが出力したログ**です。会話で共有されたログ抜粋を[`log-sample/mysql-slow.log`](log-sample/mysql-slow.log)に保存しています。これは実際に貼られた範囲の抜粋で、slow logファイル全体ではありません。

## 0. ログの読み方

ログの1レコードは、おおむね次の項目で構成されています。

```text
# Query_time: 0.035331  Lock_time: 0.000001 Rows_sent: 3  Rows_examined: 100004
SET timestamp=1792754762;
SELECT * FROM `comments` WHERE `post_id` = 9980 ORDER BY `created_at` DESC LIMIT 3;
```

- `Query_time`: SQL実行にかかった秒数。`0.035331`なら約35ミリ秒。
- `Lock_time`: ロック待ちにかかった時間。
- `Rows_sent`: クライアントへ返した行数。この例では3行。
- `Rows_examined`: MySQLが調査した行数。この例では100,004行。
- `SET timestamp`: クエリ実行時刻を表す補助行。
- 次のSQL行: 実際に実行されたクエリ。

時間だけでなく、返却行数と調査行数も一緒に見ます。3行しか返していないのに約10万行を調べている点が、この例の重要な手掛かりです。

## 1. Goアプリを起動する

Colimaを起動します。

```sh
colima start
```

`webapp/compose.yml`の`app.build.context`が`golang/`になっていることを確認します。

```yaml
  app:
    build:
      context: golang/
      dockerfile: Dockerfile
```

リポジトリのルートで初期データを用意します。すでに`make init`が完了していれば再実行は不要です。

```sh
make init
```

続けてアプリを起動します。

```sh
cd webapp
docker compose up -d --build
docker compose ps
curl -i http://localhost/
```

`nginx`、`app`、`mysql`、`memcached`が起動し、トップページに応答があることを確認します。Goアプリのエラーや標準出力は次で見られます。

```sh
docker compose logs -f app
```

これはアプリのログです。SQLごとの実行時間を見るには、以下のMySQLスロークエリログを使います。

## 2. 変更前の基準スコアを取る

ログを有効にする前に、Go実装のベースラインを記録します。スロークエリログはOFFの状態で測ってください。

```sh
cd ../benchmarker
docker run --network host -i private-isu-benchmarker \
  /bin/benchmarker -t http://host.docker.internal -u /opt/userdata
```

`pass`、`score`、`success`、`fail`を記録します。`fail`が0でなければ、まずタイムアウトやアプリ起動状態を直し、有効な基準値を取り直します。過去のRuby実装のスコアはGo版の比較値には使いません。

## 3. スロークエリログを一時的に有効にする

MySQLのスロークエリログは、実行時間がしきい値を超えたSQLをMySQL自身が記録する機能です。しきい値は`long_query_time`で秒単位に指定します。たとえば`0.01`は10ミリ秒です。

練習中は、まず対象SQLを漏らさないために一時的に0秒を指定し、**ベンチマーク全体ではなく、ページを1回だけリクエスト**します。すべてのSQLが記録対象になるため、この設定のままベンチマークを回さないでください。

`webapp`ディレクトリで実行します。

```sh
docker compose exec -T mysql mysql -uroot -proot -e \
  "SET GLOBAL log_output='FILE'; SET GLOBAL long_query_time=0; SET GLOBAL slow_query_log=ON;"
```

`long_query_time`はMySQL接続ごとの設定にもなります。すでに接続しているGoアプリに新しいしきい値を反映させるため、アプリを再起動します。

```sh
docker compose restart app
```

## 4. 1回だけリクエストしてログを採取する

トップページを1回だけ開きます。HTTPステータスも確認します。

```sh
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost/
```

記録先のファイル名をMySQLに問い合わせます。

```sh
docker compose exec -T mysql mysql -uroot -proot -Nse \
  "SELECT @@global.slow_query_log_file;"
```

表示される`/var/lib/mysql/...-slow.log`は**MySQLコンテナ内のパス**です。Mac上の`cat /var/lib/mysql/...`では開けません。コンテナ内で末尾を表示できます。

```sh
docker compose exec mysql tail -n 100 /var/lib/mysql/実際のファイル名-slow.log
```

### スロークエリログをコンテナ起動時から有効にする方法

普段は上の`SET GLOBAL`による一時切り替えが扱いやすいです。MySQLコンテナの起動時から有効にしたい場合は、`webapp/compose.yml`の`mysql`サービスに起動オプションを追加します。

```yaml
  mysql:
    command:
      - --slow-query-log=ON
      - --long-query-time=0.01
      - --log-output=FILE
```

設定を反映するにはMySQLコンテナを再作成します。

```sh
docker compose up -d --force-recreate mysql
```

この方法では以後MySQLを起動するたびにスロークエリログが有効になります。通常のスコア測定に戻す前に起動オプションを外してMySQLを再作成するか、実行中に`SET GLOBAL slow_query_log=OFF`を実行してください。設定ファイルを残したままコンテナを再起動すると、ログが再び有効になる点に注意します。

## 5. ログをファイルに保存する

slow logはコンテナの中にあるため、リポジトリ内で分析するにはホストへコピーします。ここでは`webapp`ディレクトリから、リポジトリの`log-sample`へコピーする例です。ファイル名は手順4で確認したものに置き換えます。

```sh
docker compose cp mysql:/var/lib/mysql/実際のファイル名-slow.log ../log-sample/mysql-slow-captured.log
```

ホスト側に`log-sample/mysql-slow-captured.log`ができます。ファイルが大きい場合は、最初に`tail`で必要範囲だけ確認するか、分析用に抽出した結果だけ保存します。

## 6. ログからボトルネックを見つける

今回の抜粋では、次の2つが目立ちます。

```text
Query_time: 0.011440 ... Rows_sent: 1 Rows_examined: 100001
SELECT COUNT(*) AS `count` FROM `comments` WHERE `post_id` = 9980;
```

```text
Query_time: 0.035331 ... Rows_sent: 3 Rows_examined: 100004
SELECT * FROM `comments` WHERE `post_id` = 9980 ORDER BY `created_at` DESC LIMIT 3;
```

判断の手順は次のとおりです。

1. `Query_time`が大きいSQLを探す。例ではコメント一覧が約35ミリ秒です。
2. `Rows_sent`と`Rows_examined`を比べる。3行を返すために約10万行を調べています。
3. SQLの`WHERE`と`ORDER BY`を読む。ここでは`post_id`で絞り、`created_at`の降順に並べています。
4. 同じ形のSQLが何度も記録されていないか確認する。Go実装の`makePosts`は投稿ごとにコメント数とコメント一覧を問い合わせるため、トップページでこの処理が繰り返されます。

このログだけでインデックス欠如を断定せず、次の調査で実行計画と既存インデックスを確かめます。

## 7. 次の調査: インデックスと実行計画を確認

まず既存のインデックスを確認します。

```sh
docker compose exec -T mysql mysql -uroot -proot isuconp -e \
  "SHOW INDEX FROM comments;"
```

次に、問題の2クエリの実行計画を確認します。

```sh
docker compose exec -T mysql mysql -uroot -proot isuconp -e \
  "EXPLAIN SELECT COUNT(*) FROM comments WHERE post_id = 9980; EXPLAIN SELECT * FROM comments WHERE post_id = 9980 ORDER BY created_at DESC LIMIT 3;"
```

`type`が`ALL`で、`key`が`NULL`ならテーブル全体を調べる計画です。`rows`は見積もりなので、slow logの実測`Rows_examined`と合わせて見ます。`post_id`から始まるインデックスがあるのに全件走査している場合は、インデックスの列順や統計情報も調べます。インデックスを重複して作らないよう、`SHOW INDEX`の結果を先に確認してください。

## 8. 改善候補: 複合インデックスを追加

既存のインデックスに`post_id`から始まる適切なものがなく、実行計画でも全件走査と確認できた場合の候補は、次の複合インデックスです。

```sql
CREATE INDEX idx_comments_post_created ON comments (post_id, created_at);
```

`post_id`を先頭列にすると、コメント数を`post_id`で数えるクエリと、同じ列で絞るコメント一覧の両方で利用できる可能性があります。`created_at`を次の列に置くと、コメント一覧の並び替えにも使える可能性があります。実際に使われるかは、追加後に実行計画とログで確認します。

この練習はGoアプリで計測していますが、インデックスはMySQLの共有スキーマに対する変更です。データの返し方は変わらず、同じクエリを使うRuby、PHP、Python、Node.jsの実装にも影響します。

インデックスを追加する場合は、ベンチマークのスロークエリログをOFFにした状態で、MySQLに実行します。

```sh
docker compose exec -T mysql mysql -uroot -proot isuconp -e \
  "CREATE INDEX idx_comments_post_created ON comments (post_id, created_at);"
```

追加後、同じ`EXPLAIN`を再実行して`key`が使われるか、見積もり行数が減ったか確認します。必要なら再びスロークエリログを一時的にONにして、トップページを1回だけ開き、`Rows_examined`と`Query_time`が下がったか確認します。確認後はすぐOFFにします。

## 9. ベンチマークで効果を比べる

スコアを測る前に必ずスロークエリログをOFFにします。

```sh
docker compose exec -T mysql mysql -uroot -proot -e \
  "SET GLOBAL slow_query_log=OFF;"
```

変更前後で同じコマンドを実行します。アプリ、ベンチマーカー、ColimaのCPU・メモリ割り当て、データを揃えます。

```sh
cd ../benchmarker
docker run --network host -i private-isu-benchmarker \
  /bin/benchmarker -t http://host.docker.internal -u /opt/userdata
```

`pass:true`かつ`fail:0`を維持していることを先に確認し、複数回のスコアを比べます。1回だけの上下は測定のばらつきかもしれません。ベースライン時にタイムアウトがあった場合、そのスコアは比較に使わず、正常に完走した結果を取り直します。

## 10. 追加したインデックスを戻す方法

この練習で作ったインデックスだけを削除するには、次を実行します。

```sh
cd ../webapp
docker compose exec -T mysql mysql -uroot -proot isuconp -e \
  "ALTER TABLE comments DROP INDEX idx_comments_post_created;"
```

既存のインデックスを削除しないよう、名前を確認してから実行します。

## ログを検索・抽出するコマンド

ホストへコピーしたログから、コメントSQLと前後の実行時間情報を表示できます。

```sh
rg -n -C 3 "Query_time:|FROM .comments." ../log-sample/mysql-slow-captured.log
```

結果を別ファイルに保存するには、出力先をリダイレクトします。

```sh
rg -n -C 3 "Query_time:|FROM .comments." ../log-sample/mysql-slow-captured.log \
  > ../log-sample/comments-analysis.txt
```

`>`は指定ファイルを上書きし、`>>`は末尾に追記します。生ログを保管し、抽出結果は別ファイルに分けておくと、元データと分析メモを区別できます。

## ログ設定の確認

現在の設定は次で確認できます。

```sh
docker compose exec -T mysql mysql -uroot -proot -e \
  "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('slow_query_log','long_query_time','log_output','slow_query_log_file');"
```

ベンチマーク前の目安は`slow_query_log=OFF`です。`log_output=FILE`は出力先の形式、`slow_query_log_file`はコンテナ内の保存場所です。MySQLのパスワードをコマンドに直接書くと警告が出ますが、今回のCompose環境ではrootパスワードが`root`に設定されています。
