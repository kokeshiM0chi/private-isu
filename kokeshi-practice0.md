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

ログを取っている間はMySQLに余分な負荷がかかります。そのため、この間に測ったスコアは変更前後の比較には使いません。

## 6. ベンチマークを実行してSQLログを見る

ログに対象SQLを記録するため、ベンチマークを1回実行します。

```sh
cd ../benchmarker
docker run --network host -i private-isu-benchmarker \
  /bin/benchmarker -t http://host.docker.internal -u /opt/userdata
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
- スロークエリログを有効にした状態のスコアは比較に使わないでください。
- ベンチマーカーは初期化リクエストを送るため、変更前後で同じ環境・コマンドを使います。
