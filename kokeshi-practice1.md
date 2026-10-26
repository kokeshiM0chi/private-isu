# 練習 1: MySQLスロークエリログから調査し、改善を測る（Go）

この練習では、Go版アプリを動かしたままMySQLのスロークエリログを採取し、ログから時間のかかるSQLを見つけ、追加調査をして改善前後を比較します。

今回のログは、アプリのGoログではなく**MySQLが出力したログ**です。会話で共有されたログ抜粋を[`log-sample/mysql-slow.log`](log-sample/mysql-slow.log)に保存しています。これは実際に貼られた範囲の抜粋で、slow logファイル全体ではありません。

## 0. 用語とログ1件の読み方

最初に、設定値とログに出る数字を区別します。

- **クエリ**: アプリがMySQLに送るSQL命令です。例は`SELECT ... FROM comments ...`です。
- **スロークエリログ**: MySQLが、条件に当てはまったクエリと実行情報を記録したものです。Goアプリのログとは別です。
- **`long_query_time`**: クエリをログに記録するか判断する時間のしきい値です。単位は秒です。`0.01`は10ミリ秒、`0.1`は100ミリ秒、`0.0001`は0.1ミリ秒です。
- **しきい値**: 記録するかどうかを分ける境目です。しきい値を変えても、SQLの処理や調べる行数は変わりません。変わるのはログに残るクエリです。
- **1件のログ**: 基本的に1回実行されたSQLの記録です。ページを1回表示すると、その処理中に複数のSQLが実行され、それぞれ別の記録になることがあります。

`long_query_time=0`にすると、実行時間による条件としては、0秒より長くかかった通常のクエリがほぼすべて記録対象になります。ただし「データベースにある全行を取得する」という意味ではありません。また、MySQLはしきい値以外にも、クエリ処理中にテーブルから調べた行数が最低条件を満たすか、管理用SQLかどうかなどを記録条件に使います。通常のアプリの`SELECT`を調べるこの練習では、0にすると短いクエリも含めて記録できます。

記録には、スロークエリログがONであることと、出力先が`FILE`または`TABLE`であることも必要です。さらに`min_examined_row_limit`（クエリ処理中にテーブルから調べた行数が、この値以上であること）が適用されます。この環境では通常0なので、テーブル行数による足切りはありません。管理用SQLは初期設定では記録されない場合があります。公式資料は末尾の参考資料を参照してください。[1]

次の例は、**1回のクエリ**についてMySQLが記録した情報です。

```text
# Query_time: 0.035331  Lock_time: 0.000001 Rows_sent: 3  Rows_examined: 100004
SET timestamp=1792754762;
SELECT * FROM `comments` WHERE `post_id` = 9980 ORDER BY `created_at` DESC LIMIT 3;
```

- **`Query_time`**: そのクエリにかかった時間。単位は秒で、`0.035331`は約35ミリ秒です。
- **`Lock_time`**: そのクエリがロックを取るために待った時間。例では約0.001ミリ秒です。
- **`Rows_sent`**: そのクエリがアプリへ返した行数。例では3行です。
- **`Rows_examined`**: そのクエリの処理中にMySQLのサーバー部分がテーブルから調べた行数（レコード数）です。例では100,004行です。slow logファイルのログ行数でも、テーブルに保存されている総行数でもありません。また、ディスクから読み込んだ回数と同じ意味でもありません。
- **`SET timestamp=...`**: クエリの時刻をMySQLが記録するための行です。次に続くSQLそのものではありません。
- **SQLの行**: 実際にアプリから実行されたクエリです。

したがって、`long_query_time=0`は「短いクエリもログに載せる」設定であり、`Rows_examined`は「ログに載った個々のクエリの処理中に、テーブルから何行調べたか」を示します。しきい値を0にしても、`Rows_examined`が0になるわけでも、テーブル全行を取得するわけでもありません。

この例では、クエリは3行を返す一方でテーブルから約10万行を調べています。返すレコード数に比べて調べたテーブル行数が多いため、検索方法を追加調査する手掛かりになります。

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

負荷をかける直前に、MySQLの現在の状態を確認できます。`Value`が`OFF`ならログ記録は停止中です。`ON`なら、ベンチマーク前にOFFへ切り替えます。

```sh
docker compose exec -T mysql mysql -uroot -proot -e \
  "SHOW GLOBAL VARIABLES LIKE 'slow_query_log';"
```

出力を機械的に確認したい場合は、値だけを表示します。`0`はOFF、`1`はONです。

```sh
docker compose exec -T mysql mysql -uroot -proot -Nse \
  "SELECT @@GLOBAL.slow_query_log;"
```

```sh
cd ../benchmarker
docker run --network host -i private-isu-benchmarker \
  /bin/benchmarker -t http://host.docker.internal -u /opt/userdata
```

`pass`、`score`、`success`、`fail`を記録します。`fail`が0でなければ、まずタイムアウトやアプリ起動状態を直し、有効な基準値を取り直します。過去のRuby実装のスコアはGo版の比較値には使いません。

## 3. スロークエリログを一時的に有効にする

MySQLのスロークエリログは、設定された条件に当てはまるSQLと、そのSQLごとの実行情報をMySQL自身が記録する機能です。`long_query_time`はその条件の一つで、時間を秒単位で指定します。たとえば`0.01`は10ミリ秒です。

練習中は、短いSQLも見つけられるように一時的に0秒を指定し、**ベンチマーク全体ではなく、ページを1回だけリクエスト**します。通常のアプリSQLはすべて記録対象になる設定ですが、記録するクエリ数が増え、その分MySQLに記録処理の負荷がかかります。この設定のままベンチマークを回さないでください。

`webapp`ディレクトリで実行します。

```sh
docker compose exec -T mysql mysql -uroot -proot -e \
  "SET GLOBAL log_output='FILE'; SET GLOBAL long_query_time=0; SET GLOBAL slow_query_log=ON;"
```

### しきい値の変更とGoアプリのDB接続

このGoアプリは`sqlx.Open`でデータベース用のハンドルを作り、Goの`database/sql`がその中で接続プールを管理します。ハンドルを作った時点で必ずMySQLへ接続するわけではありません。クエリを実行すると、プールにある接続を再利用するか、必要に応じて新しい接続を作ります。同じ接続を複数のクエリで使うことがあり、クエリのたびに必ず新しい接続を作るわけでも、一定時間ごとに接続するわけでもありません。[3][4]

MySQLの`long_query_time`には、サーバー全体の`GLOBAL`値と、各接続で使われる`SESSION`値があります。新しい接続の`SESSION`値は、その接続が作られた時点の`GLOBAL`値を引き継ぎます。`SET GLOBAL long_query_time=...`を実行しても、すでにプール内にある接続の`SESSION`値は変更されません。[2]

そのため、この練習ではしきい値を変えたあとにアプリを再起動し、プール内の古い接続を閉じます。再起動直後にDB接続ができるとは限らず、次にアプリがSQLを実行したときに新しい接続が作られます。その接続が変更後のしきい値を引き継ぎます。

```sh
docker compose restart app
```

一方、`slow_query_log`はサーバー全体に対する`GLOBAL`設定です。`SET GLOBAL slow_query_log=ON`または`OFF`を実行すればMySQLのログ記録が切り替わるため、アプリ再起動は不要です。`SET SESSION long_query_time=...`をMySQLの対話画面で実行した場合は、その対話画面の接続だけに適用され、Goアプリの接続プールには適用されません。[1][2]

### しきい値を変えた前後のログ

`long_query_time`を変更しても、既に記録されたログは消えず、後から新しいしきい値で判定し直されることもありません。`slow_query_log`をOFFにしても、すでにファイルに出力された記録は消えません。OFFにすると、その時点以降の記録を止めるだけです。ログファイルには、ONの間に条件を満たしたクエリが時刻順に追加されます。

アプリの接続プールに古い接続が残っている状態で`SET GLOBAL long_query_time=...`を行うと、古い接続は変更前の`SESSION`値を使い続け、新しい接続は変更後の値を使います。その間に記録されたクエリは同じログファイルに混在する可能性があります。ログの各記録には、そのクエリに適用された`long_query_time`の値は書かれません。[1][2]

変更後のしきい値だけで調査したい場合は、しきい値を設定し、アプリを再起動して接続プールを作り直してから、調査対象のリクエストを送ります。採取開始前に既存ログをホストへコピーしておくか、ログ内の時刻を記録しておくと、変更前後の記録を区別できます。スロークエリログがOFFだった期間のクエリは、後からONにしても記録されません。

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

ここからのコマンドは、`webapp`ディレクトリで同じターミナルから続けて実行します。最初にMySQLへ問い合わせてコンテナ内のログパスを取得し、次にそのファイルをホストへコピーし、ホスト側のコピーを`mysqldumpslow`で分析します。`mysqldump`ではなく`mysqldumpslow`がslow log分析用のコマンドです。

```sh
# MySQLコンテナに問い合わせ、スロークエリログのコンテナ内パスを取得する。
SLOW_LOG_CONTAINER=$(docker compose exec -T mysql mysql -uroot -proot -Nse \
  "SELECT @@global.slow_query_log_file;")
# 取得したパスを表示する。これはコンテナ内のパス。
printf 'コンテナ内のログ: %s\n' "$SLOW_LOG_CONTAINER"

# ホスト側でログを保存するパスを変数に入れる。
HOST_LOG=../log-sample/mysql-slow-captured.log
# MySQLコンテナ内のログをホストへコピーする。
docker compose cp "mysql:$SLOW_LOG_CONTAINER" "$HOST_LOG"
# コピーできたことと、ファイルサイズを確認する。
ls -lh "$HOST_LOG"

# -s: sort（並べ替え）の基準を指定するオプション。
# -s t: sort by total query time（クエリ実行時間の合計順）。
# -t 20: top 20（上位20件）を表示する。
# "$HOST_LOG": 集計対象にする、ホスト上へコピーしたログファイル。
# >: 画面出力をこのファイルへ保存する。既存ファイルがあれば上書きする。
mysqldumpslow -s t -t 20 "$HOST_LOG" \
  > ../log-sample/slow-by-total-time.txt
# less: 保存した集計結果をページ単位で読む。qキーで終了する。
less ../log-sample/slow-by-total-time.txt
```

この一連の処理で、コンテナ内のログパス確認、ホストへのコピー、ファイル存在確認、合計実行時間順の集計、結果の閲覧まで行います。`-s`はsort（並べ替え）の基準を指定し、`-s t`はsort by total query time（クエリ実行時間の合計順）です。`-t 20`はtop 20（上位20件）を表示します。ホスト側に`log-sample/mysql-slow-captured.log`が元ログとして残り、集計結果は`log-sample/slow-by-total-time.txt`に保存されます。MySQLが停止中なら先に起動してください。ホストで`mysqldumpslow`が見つからない場合は、後述のHomebrew手順で導入してから分析コマンドを実行します。ファイルが大きい場合は、採取対象の時間を短くするか、元ログをコピーした後で必要な範囲を抽出します。

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
2. `Rows_sent`と`Rows_examined`を比べる。3レコードを返すために、テーブルから約10万行を調べています。
3. SQLの`WHERE`と`ORDER BY`を読む。ここでは`post_id`で絞り、`created_at`の降順に並べています。
4. 同じ形のSQLが何度も記録されていないか確認する。Go実装の`makePosts`は投稿ごとにコメント数とコメント一覧を問い合わせるため、トップページでこの処理が繰り返されます。

このログだけでインデックス欠如を断定せず、次の調査で実行計画と既存インデックスを確かめます。

SQL時間だけではHTTP応答の遅さを説明できない場合に、Goコード内のCPU処理やメモリ、キャッシュ候補を調べる方法は[練習3: Goのpprofとキャッシュ](kokeshi-practice3.md)を参照してください。

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

Query確認方法

```sh
docker compose exec -T mysql mysql -uroot -proot isuconp -e \
  "SELECT COUNT(*) FROM comments WHERE post_id = 9980;"
```

```sh
docker compose exec -T mysql mysql -uroot -proot isuconp -e \
  "SELECT * FROM comments WHERE post_id = 9980 ORDER BY created_at DESC LIMIT 3;"
```

## 8. 改善候補: 複合インデックスを追加

既存のインデックスに`post_id`から始まる適切なものがなく、実行計画でも全件走査と確認できた場合の候補は、次の複合インデックスです。

```sql
CREATE INDEX idx_comments_post_created ON comments (post_id, created_at);
```

`post_id`を先頭列にすると、コメント数を`post_id`で数えるクエリと、同じ列で絞るコメント一覧の両方で利用できる可能性があります。`created_at`を次の列に置くと、コメント一覧の並び替えにも使える可能性があります。実際に使われるかは、追加後に実行計画とログで確認します。

この練習はGoアプリで計測していますが、インデックスはMySQLの共有スキーマに対する変更です。データの返し方は変わらず、同じクエリを使うRuby、PHP、Python、Node.jsの実装にも影響します。

インデックスを追加する**前**に、比較用のベンチマーク結果を保存します。スロークエリログがOFFで、アプリとデータが準備できていることを確認してください。`webapp`ディレクトリから実行します。

```sh
cd ../benchmarker
docker run --network host -i private-isu-benchmarker \
  /bin/benchmarker -t http://host.docker.internal -u /opt/userdata \
  > ../log-sample/benchmark-before-index.json
cd ../webapp
```

ベンチマークの標準出力をホスト上の`log-sample/benchmark-before-index.json`へ保存しています。`fail`が`0`で、`messages`が空であることを確認してから、正常な測定結果として扱います。`pass:true`だけでは失敗がなかったとは限らないため、`fail`と`messages`も確認してください。

このベンチマーカーは標準設定で負荷を60秒かけ、その後10秒待ってから結果を出力します。初期化時間も加わるため、完了まで1分強かかることがあります。`>`で結果をファイルへリダイレクトしているので、実行中はJSONが画面に表示されず、完了してプロンプトに戻るとファイルへ結果が書き込まれています。完了を待ち、同じベンチマークを重ねて起動しないでください。

```sh
cat ../log-sample/benchmark-before-index.json
```

ベースラインを保存した後、スロークエリログをOFFにした状態でMySQLにインデックスを追加します。

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

ベンチマーク開始直前にも、値が`0`（OFF）になったことを確認します。

```sh
docker compose exec -T mysql mysql -uroot -proot -Nse \
  "SELECT @@GLOBAL.slow_query_log;"
```

インデックス追加後、変更前と同じコマンドを実行し、別ファイルに保存します。アプリ、ベンチマーカー、ColimaのCPU・メモリ割り当て、データを揃えます。

```sh
cd ../benchmarker
docker run --network host -i private-isu-benchmarker \
  /bin/benchmarker -t http://host.docker.internal -u /opt/userdata \
  > ../log-sample/benchmark-after-index.json
cd ../webapp
```

この実行も標準設定では負荷が60秒、その後の待機が10秒あり、初期化時間も加わります。出力はファイルへリダイレクトされるため、完了してプロンプトに戻るまでJSONは画面に表示されません。

`fail:0`かつ`messages:[]`であることを確認し、2つのJSONの`score`、`success`、`fail`などを比較します。`pass:true`はベンチマーク処理が終了したことを示しますが、処理中にタイムアウトなどの失敗が記録されている場合もあるため、失敗数とメッセージを合わせて読みます。保存した結果を表示する例です。

```sh
cat ../log-sample/benchmark-before-index.json
cat ../log-sample/benchmark-after-index.json
```

`>`は標準出力をファイルへ保存し、同名ファイルがあれば上書きします。1回だけのスコアの上下は測定のばらつきかもしれないため、可能なら変更前後それぞれ複数回測り、正常に完走した結果を比べます。ベースライン時にタイムアウトがあった場合、その結果は正常な比較値として扱わず、同じ条件で取り直します。今回保存した例では、インデックス追加前が`score:0`、`fail:53`で、`GET /`、`POST /login`、`POST /register`にタイムアウトがありました。追加後は`score:11864`、`fail:0`です。前者はインデックスなしで性能問題が起きた記録としては有用ですが、正常完了したベースラインスコアではありません。

### 失敗を含む結果の読み方と追試験

`pass:true`でも、`fail`が0とは限りません。今回のインデックスなしの結果は`pass:true`でしたが、`fail:53`で、GETとPOSTの複数リクエストにタイムアウトが出ていました。これは測定処理自体は最後まで進んだものの、要求されたリクエストを正常に処理できなかった結果です。インデックス追加後は`fail:0`となり、タイムアウトも記録されていません。したがって、今回の結果から「インデックスなしでは性能問題があり、追加後はこのベンチマークを失敗なく処理できた」と読めます。`score:0`と`score:11864`の差を、厳密なスコア改善量として扱うことはできません。

インデックスの効果を改めて追試験する場合は、**インデックス有無以外の条件をそろえ、両方とも同じデータ状態から始めます**。ベンチマーカーはログイン、登録、投稿などのリクエストを実行するため、ベンチマーク後のデータベースは開始前と同じ状態とは限りません。MySQLコンテナやアプリを再起動しただけでは、データボリューム内のデータは初期状態に戻りません。毎回同じ初期データへ戻す手順を決め、アプリ、ベンチマーカーのuserdata、Colimaの割当、slow log OFFもそろえてから測定します。

### Docker ComposeのDBを初期状態へ戻す

以下は**DB内のデータをすべて消して、初期データを入れ直す手順**です。作成した投稿・コメント・ユーザー、追加したインデックス、MySQLコンテナ内のslow logも消えます。必要なログやデータは先にホストへ保存してください。`docker compose down -v`はこの初期化を意図して行うときだけ実行します。

まずリポジトリのルートで、初期データの圧縮ファイルがあることを確認します。存在しない場合は`make init`で準備します。

```sh
test -s webapp/sql/dump.sql.bz2 || make init
```

続けて`webapp`でMySQLのデータボリュームを削除し、MySQLだけを起動します。

```sh
cd webapp
docker compose down -v
docker compose up -d mysql
docker compose logs -f mysql
```

ログに初期化完了後の`ready for connections`が出たら、`Ctrl-C`でログ表示だけを終了します。MySQLコンテナは動作を続けます。その後、アプリなど残りのサービスを起動します。

```sh
docker compose up -d
docker compose ps
```

初期状態の**インデックスなし**を測るには、リセット後そのままベンチマークを実行します。**インデックスあり**を測るには、もう一度同じリセットを行い、MySQLが初期化された後に同じインデックスを作成してからベンチマークします。これで両方の測定を同じ初期データから始められます。結果ファイルはホストにあるため、異なるファイル名へ保存すればリセット後も残ります。

今回のようにインデックスなしでタイムアウトが出る場合は、追試験でも同じ失敗が再現する可能性があります。追試験は原因の再確認には使えますが、失敗を含む結果を正常なスコア比較値にはしません。現在保存されている前後の結果は、インデックスなしの測定後にDBを初期化せずインデックスを加えて測定しているため、開始時のデータ状態が厳密には一致していません。改善の傾向を示す参考結果として扱い、厳密な追試験では上記のDBリセットを前後それぞれの測定前に行います。結果ファイルは現在のものを残したまま別名で保存し、初期化手順と実行順を記録してください。

## 10. 追加したインデックスを戻す方法

この練習で作ったインデックスだけを削除するには、次を実行します。

```sh
cd ../webapp
docker compose exec -T mysql mysql -uroot -proot isuconp -e \
  "ALTER TABLE comments DROP INDEX idx_comments_post_created;"
```

既存のインデックスを削除しないよう、名前を確認してから実行します。

## ログを検索・抽出するコマンド

Linux標準の`grep`を使います。UbuntuなどのAWSサーバーでは通常使えます。Alpine Linuxでは`grep`はBusyBoxの機能として入っていることが多く、`rg`（ripgrep）は別途インストールしないと使えないことがあります。

以下は、コピーしたログからコメントSQLと前後のログ行を表示する例です。`webapp`ディレクトリから実行します。

```sh
grep -n -C 3 -E 'Query_time:|FROM `comments`' ../log-sample/mysql-slow-captured.log
```

`grep`は、ファイルの中から検索パターンを含む行を表示します。この例では`-E`で拡張正規表現を使い、`|`は「または」を表すので、`Query_time:`を含む行か、`FROM `comments``を含む行のどちらも表示します。特定の文字列をそのまま探す場合は、次の例のように`-F`を指定します。バッククォートを含むパターンはシングルクォートで囲み、シェルが別の意味に解釈しないようにします。

特定のコメント一覧クエリと、その直前にある`Query_time`などを表示するには次のようにします。

```sh
grep -n -B 4 -F 'SELECT * FROM `comments` WHERE `post_id`' ../log-sample/mysql-slow-captured.log
```

`-n`はログファイル内の行番号、`-B 4`は一致した行の前4行も一緒に表示します。一致した行自体も表示されるので、最大で合計5行です。slow logでは実行時間がSQLの直前に記録されるので、SQLだけでなく`Query_time`も読めます。

検索パターンにあるバッククォートは、SQLのテーブル名や列名を囲む文字として探しています。`-F`を付けた例では、バッククォートも含めて書いた文字列をそのまま検索します。コマンドをシングルクォートで囲んでいるため、シェルはバッククォートをコマンド実行記号として扱わず、検索文字として`grep`に渡します。

抽出結果をファイルに保存するには、`>`で出力先を指定します。

```sh
grep -n -B 4 -F 'SELECT * FROM `comments` WHERE `post_id`' ../log-sample/mysql-slow-captured.log > ../log-sample/comments-queries.txt
```

`>`は指定ファイルを上書きし、`>>`は末尾に追記します。元のslow logを残し、検索結果は別ファイルに保存します。`grep`は文字列を検索する道具であり、数値の`Query_time`を数値として並べ替える機能はありません。似たSQLの集計や時間順の並べ替えには`mysqldumpslow`などを使います。

## Docker環境で遅いSQLを並べる

今回のMySQLコンテナには`mysqldumpslow`が入っていません。そのため、`docker compose exec mysql mysqldumpslow ...`は実行できません。これはコマンドの書式ではなく、コンテナ内に実行ファイルがないためです。スロークエリログをOFFにし、手順5でログをホストへコピーしてから分析します。

### MySQLコンテナには追加インストールしない

この練習環境では、MySQLコンテナ内で`microdnf install mariadb-server-utils`を実行すると、パッケージ管理が長時間メタデータを取得した後、コンテナが終了することがあります。今回の終了状態は`ExitCode=137`、`OOMKilled=true`でした。これはMySQLコンテナがメモリ不足で強制終了されたことを示します。Colimaのメモリが約2 GiBの環境では、稼働中のDBコンテナに分析ツールを追加しないでください。

ログはMySQLコンテナからホストへコピーし、ホストに導入した`mysqldumpslow`で分析してください。ホストにコマンドがなければ、この節の後半にあるHomebrewの導入手順を使います。

ホストに`mysqldumpslow`があるか確認します。見つかった場合はコピー済みのログに使えます。

```sh
command -v mysqldumpslow
```

macOSでHomebrewを使っている場合は、MySQLのFormulaを入れると`mysqldumpslow`も利用できます。`mysql-client` Formulaには含まれていないため、`mysql-client`を入れてもこのコマンドが使えないことがあります。[6]

```sh
brew install mysql
command -v mysqldumpslow
```

この練習ではDockerのMySQLを使うので、Homebrew版のMySQLサーバーを起動する必要はありません。`brew services start mysql`は実行せず、インストールされた`mysqldumpslow`でコピー済みログを分析します。インストール後も`command -v`で見つからない場合は、Homebrewのインストール先から直接実行します。

```sh
"$(brew --prefix mysql)/bin/mysqldumpslow" -s t -t 20 ../log-sample/mysql-slow-captured.log
```

`mysqldumpslow`はslow logのSQLを似た形ごとにまとめます。`-s t`は各SQLパターンの実行時間合計が大きい順、`-s at`は平均実行時間順、`-s c`は実行回数順です。`-t 20`は上位20パターン、`-g comments`はSQLに`comments`を含むものだけに絞ります。

```sh
mysqldumpslow -s t -t 20 ../log-sample/mysql-slow-captured.log
mysqldumpslow -s at -t 20 ../log-sample/mysql-slow-captured.log
mysqldumpslow -s t -t 20 -g comments ../log-sample/mysql-slow-captured.log
```

合計時間順の結果をファイルに保存し、上から調べる例です。

```sh
mysqldumpslow -s t -t 20 ../log-sample/mysql-slow-captured.log \
  > ../log-sample/slow-by-total-time.txt
```

集計でコメント取得SQLが上位に出たら、元ログから個々の実行時間とSQLを`grep`で確認します。`mysqldumpslow`は似たSQLをまとめた結果で、個々の実行記録は元のslow logに残っています。

ホストにも`mysqldumpslow`がない場合は、追加インストールなしで、slow logに記録された個々のSQL実行を時間の長い順に並べられます。次の例は、実行時間と1行のSQLを取り出して、時間を数値として降順に並べ、上位20件を表示します。

```sh
awk '
/^# Query_time:/ { query_time = $3; next }
tolower($0) ~ /^(select|insert|update|delete|replace)/ && query_time != "" {
  print query_time "\t" $0
  query_time = ""
}
' ../log-sample/mysql-slow-captured.log | sort -nr | head -20
```

コメントSQLだけを上位表示する場合は、`grep`を間に挟みます。

```sh
awk '
/^# Query_time:/ { query_time = $3; next }
tolower($0) ~ /^(select|insert|update|delete|replace)/ && query_time != "" {
  print query_time "\t" $0
  query_time = ""
}
' ../log-sample/mysql-slow-captured.log | grep comments | sort -nr | head -20
```

この簡易例はSQLが1行で記録されている場合に使います。同じSQLパターンの実行回数や合計時間を集計せず、個々の実行を並べます。

## ログ設定の確認

現在の設定は次で確認できます。

```sh
docker compose exec -T mysql mysql -uroot -proot -e \
  "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('slow_query_log','long_query_time','log_output','slow_query_log_file');"
```

ベンチマーク前の目安は`slow_query_log=OFF`です。`log_output=FILE`は出力先の形式、`slow_query_log_file`はコンテナ内の保存場所です。MySQLのパスワードをコマンドに直接書くと警告が出ますが、今回のCompose環境ではrootパスワードが`root`に設定されています。

## 参考資料

1. [MySQL 9.7 Reference Manual: The Slow Query Log](https://dev.mysql.com/doc/refman/9.7/en/slow-query-log.html) — ログに記録する条件、`long_query_time`、ログ項目の説明。
2. [MySQL 9.7 Reference Manual: Using System Variables](https://dev.mysql.com/doc/refman/9.7/en/using-system-variables.html) — `GLOBAL`値と`SESSION`値、新しい接続が設定を引き継ぐタイミング。
3. [The Go Programming Language: Opening a Database Handle](https://go.dev/doc/database/open-handle) — `sql.Open`が接続プールのハンドルを作り、実接続は必要時に行う説明。
4. [The Go Programming Language: Managing Connections](https://go.dev/doc/database/manage-connections) — クエリ時にプールから接続を取得・再利用し、必要なら接続を作成する説明。
5. [MySQL 9.7 Reference Manual: mysqldumpslow](https://dev.mysql.com/doc/refman/9.7/en/mysqldumpslow.html) — slow log内の似たSQLを集計し、実行時間や回数で並べ替える方法。
6. [Homebrew Formulae: mysql](https://formulae.brew.sh/formula/mysql) — macOSでMySQLと`mysqldumpslow`をインストールする方法。`mysql-client`のFormulaには`mysqldumpslow`が含まれないため、MySQL Formulaを使います。

## 備考: 今回のコンテナ停止とColimaのメモリ

今回、MySQLコンテナ内で`microdnf install mariadb-server-utils`を実行した後、MySQLコンテナが停止しました。`docker compose ps -a`では`Exited (137)`、`docker inspect`では`OOMKilled=true`と確認できました。`OOMKilled=true`は、コンテナのプロセスがメモリ不足時にOSから強制終了されたことを表します。パッケージ取得中に停止したため、インストール処理が重なったことが引き金になった可能性があります。ただし、どのプロセスが何MB使っていたかまでは、この情報だけでは断定できません。

Colima VMに割り当てられたメモリ容量は`docker info`のServer欄で確認できます。今回の表示は`Total Memory: 1.914GiB`でした。これはVMに割り当てられた総容量で、停止時点の使用量や空き容量ではありません。実際の使用量は`docker stats`やColima VM内の`free -h`で別に確認します。

```sh
docker info | grep 'Total Memory'
docker stats --no-stream
colima ssh -- free -h
```

コンテナがメモリ不足で終了したか確認する例です。まず`docker compose ps -a`でMySQLのコンテナ名を調べ、その名前を指定します。

```sh
docker compose ps -a
docker inspect --format 'ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}' private-isu-mysql-1
```

`ExitCode=137 OOMKilled=true`なら、MySQLの設定変更やログ設定だけではなく、コンテナのメモリ不足を調べます。今回はコンテナ内へ分析ツールを追加する操作とメモリ不足が重なったため、以後はログをホストへコピーしてホスト上で分析します。ホスト上の分析でもホストのCPU・メモリは使いますが、MySQLコンテナと同じColima VM内で分析用パッケージを追加する負荷は避けられます。

停止したMySQLを再開するには、`webapp`ディレクトリで次を実行し、起動状態とログを確認します。DBボリュームを削除する`docker compose down -v`は実行しません。

```sh
docker compose up -d mysql
docker compose ps
docker compose logs --tail=80 mysql
```
