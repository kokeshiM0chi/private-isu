# 練習 0: ログを見て、変更前後のスコアを比べる

この練習では、Ruby実装のトップページを題材に、MySQLのスロークエリログで時間のかかるSQLを確認し、小さく修正してベンチマーク結果を比べます。

## 使う環境

- macOS、Colima、Docker Compose
- アプリは`webapp/compose.yml`のデフォルト設定（Ruby実装）
- ベンチマーカーはDockerイメージ`private-isu-benchmarker`

この環境では、変更前のベンチマークは次の結果でした。スコアは実行環境や負荷で変わるため、目安として記録します。

```json
{"pass":true,"score":1178,"success":1017,"fail":0,"messages":[]}
```

## 1. アプリを起動して画面を見る

Colimaが起動していることを確認します。

```sh
colima start
```

リポジトリのルートで初期データを用意します。すでに`make init`が完了している場合は、再実行不要です。

```sh
make init
```

アプリを起動します。

```sh
cd webapp
docker compose up -d --build
docker compose ps
```

ブラウザで`http://localhost/`を開きます。画面にユーザー登録リンクがあれば、`http://localhost/register`から任意のアカウントを登録してログインできます。ベンチマーカーは自動でリクエストを行うため、画面上の登録はベンチマーク実行の必須条件ではありません。

## 2. 変更前のスコアを記録

ベンチマーカーのディレクトリから、変更前のベンチマークを実行します。アプリは起動したままにしてください。

```sh
cd ../benchmarker
docker run --network host -i private-isu-benchmarker \
  /bin/benchmarker -t http://host.docker.internal -u /opt/userdata
```

`pass`、`score`、`success`、`fail`を記録します。比較するときは、同じマシン、同じアプリ構成で実行します。

## 3. MySQLのスロークエリログを有効にする

`webapp`ディレクトリに戻り、10ミリ秒以上かかったSQLを一時的に記録します。

```sh
cd ../webapp
docker compose exec -T mysql mysql -uroot -proot -e "SET GLOBAL log_output='TABLE'; SET GLOBAL long_query_time=0.01; SET GLOBAL slow_query_log=ON;"
```

この設定は実行中のMySQLに対する一時設定です。ログを取っている間は処理に余分な負荷がかかるため、その間のベンチマークスコアは比較用に使いません。

## 4. ベンチマークを実行してログを確認

スロークエリログに対象SQLを記録させるため、ベンチマークを1回実行します。

```sh
cd ../benchmarker
docker run --network host -i private-isu-benchmarker \
  /bin/benchmarker -t http://host.docker.internal -u /opt/userdata
```

`webapp`ディレクトリで、実行時間が長かったSQLを表示します。

```sh
cd ../webapp
docker compose exec -T mysql mysql -uroot -proot -e \
  "SELECT ROUND(TIME_TO_SEC(query_time),4) AS seconds, rows_examined, LEFT(sql_text,200) AS sql FROM mysql.slow_log ORDER BY query_time DESC LIMIT 20;"
```

トップページの投稿一覧取得SQLは、Ruby実装の`webapp/ruby/app.rb`にあります。`get '/'`の中にある次のクエリを探してください。

```ruby
results = db.query('SELECT `id`, `user_id`, `body`, `created_at`, `mime` FROM `posts` ORDER BY `created_at` DESC')
```

このSQLには`LIMIT`がありません。ログにこのクエリが出ているか、`rows_examined`が多いかを確認します。ログに出なければ、その実行では10ミリ秒を超えなかった可能性があります。

アプリログも別途確認できます。これは主に起動メッセージやエラーの確認用で、通常はSQLの実行時間までは記録しません。

```sh
docker compose logs -f app
```

ログ表示を終えるには`Ctrl-C`を押します。

## 5. ログ収集を止める

スコア比較の前に、スロークエリログを無効にします。

```sh
docker compose exec -T mysql mysql -uroot -proot -e "SET GLOBAL slow_query_log=OFF;"
```

## 6. 小さく修正して再ビルド

ログでトップページの全件取得SQLを確認できたら、まず`webapp/ruby/app.rb`の`get '/'`にあるクエリを見直します。投稿を20件だけ取得する単純な変更は、削除済みユーザーの投稿が混ざる場合に画面の表示件数が変わることがあります。出力される投稿の挙動を保つには、削除済みユーザーをSQL側で除外してから件数を制限する必要があります。

修正したら、`webapp`ディレクトリでRubyアプリを再ビルドして起動し直します。

```sh
docker compose up -d --build app
```

その後、トップページが表示できることを確認します。

```sh
curl -i http://localhost/
```

## 7. 変更後のスコアを測る

アプリを起動した状態で、同じコマンドを使ってベンチマークを再実行します。

```sh
cd ../benchmarker
docker run --network host -i private-isu-benchmarker \
  /bin/benchmarker -t http://host.docker.internal -u /opt/userdata
```

変更前後の`pass`、`score`、`success`、`fail`を比べます。`pass:true`と`fail:0`を保ったまま、複数回の実行でスコアが安定して上がるか確認します。1回だけの上下は測定のばらつきの可能性があります。

## 補足

- 通常の`docker compose logs app`ではSQLごとの時間は分かりません。この練習ではMySQLのスロークエリログを使います。
- `long_query_time=0.01`は10ミリ秒です。ログが空なら、閾値を一時的に下げて再計測できます。
- ログ収集を有効にした状態のスコアは、修正前後の比較に使わないでください。
- ベンチマーカーは初期化リクエストを送るため、同じ環境で各測定を行ってください。
