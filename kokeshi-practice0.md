# 練習 0: Goでログを見て、変更前後のスコアを比べる

この練習では、Go実装のトップページを題材に、MySQLのスロークエリログで時間のかかるSQLを確認し、小さく修正してベンチマーク結果を比べます。

## 使う環境

- macOS、Colima、Docker Compose
- アプリは`webapp/compose.yml`から起動するGo実装
- ベンチマーカーはDockerイメージ`private-isu-benchmarker`

以前に取得した`score:1178`はRuby実装の結果なので、Goの変更前スコアとしては使いません。Goに切り替えたあと、Goのベースラインを測って記録してください。

## 1. Colimaを起動し、Go実装に切り替える

```sh
colima start
```

`webapp/compose.yml`を開き、`app`サービスのビルド設定をRubyからGoに変更します。

```yaml
  app:
    build:
      context: golang/
      dockerfile: Dockerfile
```

`context: ruby/`を`context: golang/`に変えるのがポイントです。ほかの設定はそのままにします。

## 2. 初期データを準備

リポジトリのルートディレクトリで実行します。すでに`make init`が完了している場合は、再実行不要です。

```sh
make init
```

## 3. Goアプリを起動して画面を見る

```sh
cd webapp
docker compose up -d --build
docker compose ps
```

ブラウザで`http://localhost/`を開きます。ユーザー登録する場合は`http://localhost/register`を使います。ベンチマーカーは自動でリクエストを行うため、画面上の登録はベンチマーク実行の必須条件ではありません。

Goアプリの起動ログやエラーは、次のコマンドで確認できます。ログ表示を終えるには`Ctrl-C`を押します。

```sh
docker compose logs -f app
```

アプリの応答も確認します。

```sh
curl -i http://localhost/
```

## 4. Go実装の変更前スコアを記録

ベンチマーカーのディレクトリから実行します。アプリは起動したままにしてください。

```sh
cd ../benchmarker
docker run --network host -i private-isu-benchmarker \
  /bin/benchmarker -t http://host.docker.internal -u /opt/userdata
```

`pass`、`score`、`success`、`fail`を記録します。Go実装を変更したあとの比較には、このGoの結果を使います。

## 5. MySQLのスロークエリログを有効にする

`webapp`ディレクトリに戻り、10ミリ秒以上かかったSQLを一時的に記録します。

```sh
cd ../webapp
docker compose exec -T mysql mysql -uroot -proot -e "SET GLOBAL log_output='TABLE'; SET GLOBAL long_query_time=0.01; SET GLOBAL slow_query_log=ON;"
```

分析用のMySQLログをファイルに書き出したい場合

```sh
docker compose exec -T mysql mysql -uroot -proot -e \
  "SET GLOBAL log_output='FILE'; SET GLOBAL long_query_time=0.01; SET GLOBAL slow_query_log=ON;"
```

MySQLコンテナ内のログ

```sh
docker compose exec mysql cat /var/lib/mysql/b39eab4e87c2-slow.log
```

ホスト側にコピーして分析するなら、webappディレクトリで次を実行してください。

```sh
docker compose cp mysql:/var/lib/mysql/b39eab4e87c2-slow.log ./slow.log
```

これでwebapp/slow.logに保存されます。たとえば、postsに関する行を絞って別ファイルに書き出すには：

```sh
grep -n -C 5 -E 'FROM.*posts' slow.log > posts-queries.txt
```

なお、MySQLのパスワードをコマンドラインに渡すことに対する警告は出ていますが、今回はコマンド自体は実行できています。
  Worked for 3s • 20:19

ログを取っている間はMySQLに余分な負荷がかかります。そのため、この間に測ったスコアは変更前後の比較には使いません。

```sh
docker compose exec -T mysql mysql -uroot -proot -e \
  "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('slow_query_log','long_query_time','log_output','slow_query_log_file');"
```

```sh
mysql: [Warning] Using a password on the command line interface can be insecure.
Variable_name	Value
log_output	FILE
long_query_time	0.010000
slow_query_log	ON
slow_query_log_file	/var/lib/mysql/b39eab4e87c2-slow.log
```


トップページにアクセス

```sh
curl -s -o /dev/null http://localhost/
docker compose exec mysql cat /var/lib/mysql/b39eab4e87c2-slow.log
```

```sh
/usr/sbin/mysqld, Version: 9.7.4 (MySQL Community Server - GPL). started with:
Tcp port: 3306  Unix socket: /var/run/mysqld/mysqld.sock
Time                 Id Command    Argument
# Time: 2026-10-23T11:22:23.639578Z
# User@Host: root[root] @ localhost []  Id:   169
# Query_time: 0.150487  Lock_time: 0.000633 Rows_sent: 4  Rows_examined: 4
SET timestamp=1792754543;
SHOW GLOBAL VARIABLES WHERE Variable_name IN ('slow_query_log','long_query_time','log_output','slow_query_log_file');
```

```output
mysql: [Warning] Using a password on the command line interface can be insecure.
Variable_name	Value
log_output	FILE
long_query_time	0.010000
slow_query_log	ON
slow_query_log_file	/var/lib/mysql/b39eab4e87c2-slow.log

```

## 6. トップページを1回だけ開いてSQLログを見る

スロークエリログを有効にしたままベンチマーク全体を実行すると、記録処理自体が負荷になり、リクエストがタイムアウトすることがあります。ベンチマークは実行せず、トップページを1回だけ開いてSQLを記録します。

```sh
curl -s -o /dev/null http://localhost/
```

`webapp`ディレクトリで、時間のかかったSQLを表示します。

```sh
cd ../webapp
docker compose exec -T mysql mysql -uroot -proot -e \
  "SELECT ROUND(TIME_TO_SEC(query_time),4) AS seconds, rows_examined, LEFT(sql_text,200) AS sql FROM mysql.slow_log ORDER BY query_time DESC LIMIT 20;"
```

Go実装のトップページ取得SQLは`webapp/golang/app.go`の`getIndex`関数にあります。次のような、`LIMIT`なしで投稿を取得するクエリがログに出るか確認します。

```go
err := db.SelectContext(ctx, &results, "SELECT `id`, `user_id`, `body`, `mime`, `created_at` FROM `posts` ORDER BY `created_at` DESC")
```

`rows_examined`が大きいかも見ます。ログに出なければ、その実行ではクエリが10ミリ秒を超えなかった可能性があります。

## 7. ログ収集を止める

スコアを比較する前に、スロークエリログを無効にします。

```sh
docker compose exec -T mysql mysql -uroot -proot -e "SET GLOBAL slow_query_log=OFF;"
```

## 8. Goコードを修正して再ビルド

ログでトップページの全件取得SQLを確認できたら、`webapp/golang/app.go`の`getIndex`関数にあるクエリを見直します。単純に`LIMIT 20`を追加すると、削除済みユーザーの投稿が混ざった場合に表示件数が変わる可能性があります。既存の表示挙動を保つには、削除済みユーザーの投稿を除外してから件数を制限する必要があります。

修正後、`webapp`ディレクトリでGoアプリを再ビルドして起動し直します。

```sh
docker compose up -d --build app
```

アプリの応答を確認します。

```sh
curl -i http://localhost/
```

## 9. 変更後のスコアを測る

アプリを起動した状態で、変更前と同じベンチマークを実行します。

```sh
cd ../benchmarker
docker run --network host -i private-isu-benchmarker \
  /bin/benchmarker -t http://host.docker.internal -u /opt/userdata
```

変更前後の`pass`、`score`、`success`、`fail`を比べます。`pass:true`と`fail:0`を保ち、複数回の実行でスコアが安定して上がるか確認します。1回だけの上下は測定のばらつきの可能性があります。

## 補足

- `docker compose logs -f app`はGoアプリの起動ログやエラー確認に使います。通常、SQLごとの実行時間は出ません。この練習ではMySQLのスロークエリログを使います。
- `long_query_time=0.01`は10ミリ秒です。ログが空なら、閾値を一時的に下げて再計測できます。
- スロークエリログを有効にするのは、トップページなどを1回確認するときだけにします。全ベンチマーク中は有効にしないでください。
- ベンチマーカーは初期化リクエストを送るため、変更前後で同じ環境・コマンドを使います。
