# ISUCON参加用攻略ガイド: AWSサーバーの調査から改善・計測まで

この文書は、private-isuのようなISUCON形式の競技で、AWS上のLinuxサーバーにログインし、状態確認、ボトルネック調査、変更、検証を進めるための実践ガイドです。コマンド例はこのリポジトリのUbuntu AMIとGo実装を中心にしています。

**実際の競技では、主催者の当日マニュアルとルールを最優先してください。** private-isuの[`public_manual.md`](public_manual.md)にある採点条件はこの練習問題のものです。競技ごとに禁止事項、計測方法、利用できるサーバー、時間配分は異なります。

## 攻略の基本ループ

競技中は、次のループを小さく回します。

1. 現状のスコアと成功・失敗件数を記録する。
2. ログや実行計画から、時間を多く使っている処理を探す。
3. 「この変更で、なぜ速くなるか」を一文で書く。
4. 変更を一つだけ入れる。
5. アプリを再起動し、エラーと基本動作を確認する。
6. 主催者指定の計測方法で再計測する。
7. 成功率とスコアを比べ、悪化したらすぐ戻す。

一度に複数の変更を入れると、どの変更が効いたか判断しにくくなります。ログ採取や`EXPLAIN`で原因を調べる時間と、通常条件でスコアを測る時間は分けます。

### 最初に守ること

- 競技ルールと計測方法を先に読む。独自ベンチマークが許可されているかも確認する。
- 変更前の状態を記録する。コードは`git status`と`git diff`で確認し、DB変更は実行したSQLをメモする。
- `pass`や成功率を保てない変更は採用しない。速さだけでなく、正しい応答を返すことが前提。
- private-isuのルールでは、POSTした内容がレスポンス後すぐにGETへ反映されること、HTMLのDOM構造と静的ファイルの内容を保つこと、再起動後も動くことが採点条件です。他の競技では当日の条件を確認してください。
- 別のインスタンスに処理を委譲するなど、許可されていない外部リソースを使わない。

## 当日の進め方の目安

競技時間や計測間隔は大会によって異なります。以下は作業を整理するための目安です。

### 序盤: 動作確認と基準値

- SSHで入り、使用中のアプリサービスとホスト構成を確認する。
- CPU、メモリ、ディスク、待ち受けポート、サービスログを見る。
- 公開URLまたは指定URLに応答があることを確認する。
- 最初のスコアを取得し、成功数・失敗数・エラー内容を保存する。
- アプリコード、設定、DBスキーマの変更前状態を記録する。

### 中盤: 高い効果が見込める箇所から直す

- 集計レポートで実行時間の合計が大きいSQLを探す。
- 呼び出し回数が多いSQL、`Rows_examined`が多いSQL、タイムアウトが出るURIを優先して見る。
- `SHOW INDEX`と`EXPLAIN`で原因を確認してから、インデックスやクエリを変更する。
- 変更ごとに再計測し、スコアだけでなく失敗件数と機能の正しさも確認する。

### 終盤: 安定性を確認する

- 新しい大きな変更は避け、効果が確認できた変更だけ残す。
- アプリを再起動して正常起動するか確認する。
- スロークエリログをOFFにし、計測設定を通常状態へ戻す。
- 最後に主催者指定の計測を実行し、成功数・失敗数・スコアを確認する。
- 変更点、戻し方、未確認事項を短く記録する。

## どこから調べるか

ログやOS情報を見て、次のように調査先を決めます。

| 見えた症状 | 次に確認するもの | 例 |
| --- | --- | --- |
| 失敗やタイムアウトが出る | アプリ・nginxのエラーログ、該当URI | `journalctl`、nginx `error.log` |
| SQLの合計時間が大きい | 実行回数、`Rows_examined`、テーブル定義 | `mysqldumpslow`、`SHOW INDEX`、`EXPLAIN` |
| 少ない行を返すのに大量のテーブル行を調べる | `WHERE`列とインデックス列の順序 | `SHOW INDEX`、`EXPLAIN` |
| CPU使用率が高い | アプリの処理、繰り返される処理、外部コマンド | `top`、アプリログ、コード |
| メモリ不足やswap利用がある | プロセスごとのメモリ、キャッシュやデータ量 | `free -h`、`top` |
| 変更後に`fail`が増える | 変更した機能の応答・データ反映 | ブラウザ、ログ、採点メッセージ |

最初に見つけた遅いSQLが唯一の原因とは限りません。上位のSQLが1リクエスト中に何回呼ばれるかも見て、合計時間・実行回数・調べたテーブル行数を合わせて優先順位を付けます。

## Dockerを使うかどうか

AWSサーバーで作業するとき、必ず`docker exec`やDockerを使うわけではありません。このリポジトリのAMI構成では、Ubuntu上でアプリ、nginx、MySQLが直接systemdサービスとして動きます。その場合は、サーバーへSSHでログインし、`systemctl`、`journalctl`、`mysql`などを使います。コンテナとして配布された競技環境の場合だけ、主催者の案内に従ってDockerコマンドを使ってください。

このリポジトリのAMIでは、アプリのsystemdサービス名は言語ごとに異なります。Rubyは`isu-ruby`、Goは`isu-go`です。実際にどの構成で起動しているかは、次のコマンドで確認します。

```sh
sudo systemctl list-units --type=service --state=running
```

## 1. AWSサーバーへSSHログイン

主催者から渡されたIPアドレスと秘密鍵を使います。ユーザー名は環境の案内に従ってください。このリポジトリのAMI手順では、最初は`ubuntu`ユーザーでログインします。

```sh
ssh -i ~/.ssh/your-key.pem ubuntu@<AWSのIPアドレス>
```

ログイン後、必要に応じて`isucon`ユーザーに切り替えます。

```sh
sudo su - isucon
cd /home/isucon/private_isu
```

`<AWSのIPアドレス>`と`your-key.pem`は実際の値に置き換えます。秘密鍵をリポジトリへ保存したり、他人に共有したりしないでください。

## 2. まずサーバーとサービスの状態を確認

Goアプリ、nginx、MySQLの状態を確認します。

```sh
sudo systemctl status isu-go nginx mysql --no-pager
```

Rubyが起動中なら、アプリのサービス名を`isu-ruby`に置き換えます。どの言語のサービスがあるか一覧するには、次を使います。

```sh
sudo systemctl list-unit-files 'isu-*'
```

CPU負荷、メモリ、ディスク、待ち受けポートも確認できます。

```sh
uptime
free -h
df -h
sudo ss -lntp
```

## 3. 調査用スナップショットスクリプト

[`scripts/isucon-diag.sh`](scripts/isucon-diag.sh)は、稼働状況、CPU負荷の目安、メモリ、ディスク、待ち受けポート、アプリのsystemdログ、nginxのエラーログ、MySQLのスロークエリ設定を1つのテキストファイルにまとめる読み取り用スクリプトです。サービスを停止・再起動したり、MySQL設定を変更したりはしません。

競技サーバーにリポジトリがない場合、手元のMacからスクリプトだけコピーできます。

```sh
scp -i ~/.ssh/your-key.pem scripts/isucon-diag.sh ubuntu@<AWSのIPアドレス>:~/isucon-diag.sh
```

サーバーへSSHログインした後に実行します。Goアプリなら`isu-go`、Rubyアプリなら`isu-ruby`を引数に指定します。

```sh
chmod +x ~/isucon-diag.sh
~/isucon-diag.sh isu-go
```

実行したユーザーのホームディレクトリに`isucon-diag-日時.txt`が保存されます。スクリプト内で必要な箇所だけ`sudo`を使うため、sudoパスワードを求められたら入力します。結果を確認したり、手元へコピーして共有・分析したりできます。

## 4. Goアプリやnginxのログを見る

直近100行を表示するには次のコマンドを使います。

```sh
sudo journalctl -u isu-go -n 100 --no-pager
```

新しいログが追加されるのを追いかける場合は`-f`を付けます。表示を終えるときは`Ctrl-C`を押します。

```sh
sudo journalctl -f -u isu-go
```

nginxのエラーログとアクセスログは、通常このリポジトリのAMIでは次の場所にあります。

```sh
sudo tail -n 100 /var/log/nginx/error.log
sudo tail -n 100 /var/log/nginx/access.log
```

エラーが出た時間とアクセスログの時間を比べると、どのリクエストで問題が起きたか調べやすくなります。

## 5. Dockerを使わずMySQLに接続

このリポジトリのAMIではMySQLはホスト上で動作します。UbuntuでMySQLの管理者権限が使える場合は、次のように接続します。

```sh
sudo mysql isuconp
```

MySQLの画面でSQLを実行します。

```sql
SHOW TABLES;
SHOW CREATE TABLE comments\G
SHOW INDEX FROM comments;
SELECT COUNT(*) FROM comments;
EXPLAIN SELECT COUNT(*) FROM comments WHERE post_id = 9980;
```

終わるときは`\q`を入力します。管理者接続が使えない場合は、競技環境から指定されたDBユーザーで接続します。private-isuの初期AMIでは`isuconp`データベースユーザーが設定されていますが、実際の競技では主催者の案内を優先します。

## 6. AWSサーバー上でスロークエリログを一時採取

MySQLの設定確認と変更は、ホスト上の`mysql`コマンドから行います。Dockerの`exec`は使いません。

現在の状態とログファイルを確認します。

```sh
sudo mysql -Nse \
  "SELECT @@GLOBAL.slow_query_log, @@GLOBAL.long_query_time, @@GLOBAL.log_output, @@GLOBAL.slow_query_log_file;"
```

### 記録を開始する

`long_query_time`は秒単位です。次の例は10ミリ秒以上のクエリをファイルに記録します。

```sh
sudo mysql -e \
  "SET GLOBAL log_output='FILE'; SET GLOBAL long_query_time=0.01; SET GLOBAL slow_query_log=ON;"
```

`long_query_time`の`GLOBAL`値を変えても、既に接続済みのアプリ接続にある`SESSION`値はそのままです。Goアプリに新しいしきい値を使わせるには、調査用のリクエストを送る前にサービスを再起動し、DB接続を作り直します。

```sh
sudo systemctl restart isu-go
```

サービス再起動は処理中のリクエストを中断します。本番の負荷計測中や競技ルールで禁止されている時間には行わず、許可されたタイミングで実施してください。スロークエリログのON/OFFだけなら、アプリ再起動は不要です。

### 1回だけリクエストする

スロークエリログをONにした状態でベンチマーク全体を走らせると、ログ出力が負荷になり、測定値に影響することがあります。まずは対象ページを1回だけリクエストします。

```sh
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1/
```

### ログを確認・保存する

ログファイルのパスを取得します。

```sh
SLOW_LOG=$(sudo mysql -Nse "SELECT @@GLOBAL.slow_query_log_file;")
printf '%s\n' "$SLOW_LOG"
```

対象リクエストを採取したら、ログファイルを読む前に記録を止めます。OFFにしても、すでに書き込まれたログは残ります。

```sh
sudo mysql -e "SET GLOBAL slow_query_log=OFF;"
sudo mysql -Nse "SELECT @@GLOBAL.slow_query_log;"
```

結果が`0`ならOFFです。ログファイルのパスを`$SLOW_LOG`に保存したので、以降の抽出・集計はMySQLのログ記録を止めた状態で行えます。

MySQLのslow logには、1回ごとのクエリについて時間、テーブルから調べた行数、SQLが記録されます。コメント一覧SQLと直前の実行時間を見る例です。

```sh
sudo grep -n -B 4 -F 'SELECT * FROM `comments` WHERE `post_id`' "$SLOW_LOG"
```

検索結果をファイルに残すには、ホームディレクトリへ出力します。

```sh
sudo grep -n -B 4 -F 'SELECT * FROM `comments` WHERE `post_id`' "$SLOW_LOG" \
  > "$HOME/comments-queries.txt"
```

`grep`は、指定文字列を含む行を表示するLinux標準コマンドです。`-F`はパターンを文字列として扱い、`-B 4`は一致行の前4行も表示します。一致行も含めるので通常は合計5行です。シングルクォート内のバッククォートは文字として扱われ、コマンド実行にはなりません。

### 実行時間の大きいSQLを順に抽出する

個々のログ行を`grep`で探す方法に加えて、MySQL付属の`mysqldumpslow`で似た形のSQLをまとめ、上位から表示できます。**まず合計実行時間の大きい順でファイルに保存し、先頭からSQLを調べる**と、繰り返し実行されて全体の時間を多く使った処理から着手できます。`-s t`は同じSQLパターンの**実行時間の合計**が大きい順、`-s at`は**平均実行時間**が長い順、`-s c`は**実行回数**が多い順です。`-t 20`は表示を上位20パターンに絞り、`-g 'comments'`はSQL文に`comments`を含むものだけに絞ります。

```sh
sudo mysqldumpslow -s t -t 20 "$SLOW_LOG" > "$HOME/slow-by-total-time.txt"
sudo mysqldumpslow -s at -t 20 "$SLOW_LOG" > "$HOME/slow-by-average-time.txt"
sudo mysqldumpslow -s t -t 20 -g 'comments' "$SLOW_LOG" > "$HOME/comments-slow-summary.txt"
```

この3つのファイルはそれぞれ、合計時間順、平均時間順、`comments`を含むSQLの合計時間順です。`less "$HOME/slow-by-total-time.txt"`で開き、上からSQLの形、実行回数、時間を見てください。`mysqldumpslow`は`post_id`などの数値を置き換え、同じ形のクエリをまとめます。出力に実行回数と時間の要約が出ますが、個々の実行の最大値を並べる道具ではありません。各実行の時刻・時間・実際のSQLは元の`$SLOW_LOG`に残っており、先ほどの`grep`で確認できます。

集計結果で調べるSQLを見つけたら、元ログから個々の実行記録を抜き出します。コメント一覧SQLの例です。

```sh
sudo grep -n -B 4 -F 'SELECT * FROM `comments` WHERE `post_id`' "$SLOW_LOG" \
  > "$HOME/comments-queries.txt"
```

`mysqldumpslow: command not found`となる場合は、MySQLのユーティリティが入っていない環境です。競技中にパッケージを追加する前に、まず元ログを`grep`で調べるか、主催者の環境ルールを確認してください。

### 本番サーバーに`mysqldumpslow`がない場合

まずOSと既存のコマンドを確認します。コンテナではなく、SSHで入ったホスト上で実行します。

```sh
cat /etc/os-release
command -v mysqldumpslow
command -v mariadb-dumpslow
```

このリポジトリのAWS練習環境と同じUbuntuでは、`mysqldumpslow`はMySQL Server Coreパッケージに含まれます。導入前に競技ルールと`apt`が表示する変更内容を確認してください。すでに別のMySQL構成があるサーバーで、パッケージ追加がサーバーの置き換えや起動につながりそうならキャンセルします。

```sh
sudo apt update
sudo apt install mysql-server-core-8.0
command -v mysqldumpslow
```

Amazon Linuxなど`dnf`を使うOSでは、利用できるリポジトリにどのパッケージがコマンドを含むかを先に検索します。表示されたパッケージ名を確認してからインストールします。

```sh
sudo dnf provides '*/mysqldumpslow'
```

MariaDBの環境では同じツールが`mariadb-dumpslow`という名前の場合があります。MariaDB公式説明では、Linuxでは`mysqldumpslow`名のシンボリックリンク経由でも利用できるとされています。コマンドが入った後は、見つかった名前で`$SLOW_LOG`を分析します。[1]

パッケージ導入はネットワーク接続、sudo権限、時間を使い、環境によっては追加のサービスやファイルが導入されます。可能なら競技開始前に練習用サーバーで確認しておき、競技中は導入せず`grep`でログを調べる方法も使えるようにしておきます。

## 7. 遅いSQLの実行計画とインデックスを調べる

遅いSQLを見つけたら、ログだけで原因を決めず、テーブル定義・インデックス・実行計画を確認します。たとえばコメント取得クエリなら、ホスト上のMySQLに次のSQLを実行します。

```sh
sudo mysql isuconp -e 'SHOW CREATE TABLE comments; SHOW INDEX FROM comments; EXPLAIN SELECT COUNT(*) FROM comments WHERE post_id = 9980; EXPLAIN SELECT * FROM comments WHERE post_id = 9980 ORDER BY created_at DESC LIMIT 3;'
```

見るポイントは次のとおりです。

- `SHOW CREATE TABLE`は列の型や主キーなど、テーブルの定義を表示します。
- `SHOW INDEX`は存在するインデックスと、その中の列の順番を表示します。
- `EXPLAIN`はMySQLがそのSQLをどのように実行する予定かを表示します。実際の負荷テストを行うものではありません。
- `type`が`ALL`で`key`が`NULL`なら、インデックスを使わずテーブル全体を読む計画の可能性があります。
- `rows`はMySQLの見積もり、slow logの`Rows_examined`はクエリ実行時にテーブルから調べた行数です。両方を見比べます。

今回のコメントSQLでは、`WHERE post_id = ...`で対象を絞り、さらに`created_at`順に並べています。`SHOW INDEX`で`post_id`から始まるインデックスがあるか、その列順が検索に合っているか確認します。インデックスの有無だけでなく、`EXPLAIN`が実際にそのインデックスを選んでいるかも確かめてから変更します。

### 確認後にインデックスを試す例

`SHOW INDEX`で同じ用途のインデックスがなく、`EXPLAIN`でも全件走査になっている場合、次の複合インデックスが候補になります。既存のインデックスを確認せず重複して追加しないでください。

```sh
sudo mysql isuconp -e \
  'CREATE INDEX idx_comments_post_created ON comments (post_id, created_at);'
```

追加後に同じ`EXPLAIN`を実行し、`key`でインデックスが選択されるか確認します。その後、slow logをOFFに戻してから、同じ計測方法でスコアを比較します。このインデックスはDBのスキーマに対する変更なので、アプリを再起動する必要はありません。削除して戻す場合は、作成したインデックス名を指定します。

```sh
sudo mysql isuconp -e \
  'ALTER TABLE comments DROP INDEX idx_comments_post_created;'
```

このインデックス例の詳しい背景と注意点は[MySQL調査の練習手順](kokeshi-practice1.md)を参照してください。

## 8. 競技中のベンチマーク

実際の競技に公式のポータルや計測方法がある場合は、必ずそれを使います。以下はprivate-isuを自分で練習するときのローカル計測例です。

```sh
sudo -iu isucon
/home/isucon/private_isu/benchmarker/bin/benchmarker \
  -u /home/isucon/private_isu/benchmarker/userdata \
  -t http://localhost
```

実際のISUCONでは主催者提供の計測方法・ポータルがある場合はそれを使います。競技ルールを確認せずに独自ベンチマークを並行して走らせると、サーバー負荷が重なり、計測結果に影響します。

実行後は出力から`pass`、`score`、`success`、`fail`、`messages`を記録します。たとえば次のように表にすると、何を変えた結果か後から追いやすくなります。

| 実行 | 変更 | pass | score | success | fail | メモ |
| --- | --- | --- | ---: | ---: | ---: | --- |
| 基準 | 変更前 | true |  |  |  |  |
| 1 | 変更を一つ記録 |  |  |  |  |  |

スコアだけでなく`fail`と`messages`も比較します。エラーが増えてスコアだけが高く見える変更は採用しません。測定結果にばらつきがある場合は同条件で複数回測り、特定の1回だけの上昇で判断しないようにします。

## 9. 変更を反映してアプリを再起動する

まず、現在の変更状態を記録します。

```sh
cd /home/isucon/private_isu
git status --short
git diff
```

Goアプリのコードを変更した場合は、現在の実行ファイルをバックアップし、別名でビルドしてから差し替えます。ビルドに失敗したときに現在の実行ファイルを残しやすくするためです。Goの作業ディレクトリは、このリポジトリのsystemdユニットでは`/home/isucon/private_isu/webapp/golang`です。

```sh
cd /home/isucon/private_isu/webapp/golang
BACKUP="/home/isucon/private_isu/webapp/golang/app.before.$(date +%Y%m%d-%H%M%S)"
cp app "$BACKUP"
printf 'Backup: %s\n' "$BACKUP"
go build -o app.new . && mv app.new app
```

`go build`が失敗した場合は、アプリを再起動せず、エラーを直してからビルドし直します。ビルド成功後にGoアプリだけを再起動します。起動引数と実行ファイルは、systemdユニットで確認できます。

```sh
sudo systemctl cat isu-go
```

再起動後に状態とログを確認します。

```sh
sudo systemctl restart isu-go
sudo systemctl status isu-go --no-pager
sudo journalctl -u isu-go -n 100 --no-pager
```

設定や実行ファイルを確認せず、Ruby用サービスなど別言語のユニットを再起動しないようにします。使用中のサービス名を先に確認してください。

### 変更を戻す

再計測で`fail`が増えたり、スコアが悪化したり、機能が壊れたりしたら、直前の変更を戻して再起動します。直前のバックアップ名は、ビルド時に表示・記録しておきます。

```sh
cp "$BACKUP" /home/isucon/private_isu/webapp/golang/app
sudo systemctl restart isu-go
sudo systemctl status isu-go --no-pager
```

ソースコードの変更は、記録した`git diff`を見て手動で戻すか、変更単位で管理します。競技中に`git reset --hard`などの一括破棄コマンドは、保存していない作業を消す可能性があるため安易に使わないでください。DBインデックスを追加した場合は、実行した`CREATE INDEX`と対応する`DROP INDEX`を必ずメモします。

## 10. 調査時の基本順序

1. SSHで対象サーバーへ入る。
2. `systemctl`でアプリ、nginx、MySQLの状態を見る。
3. `uptime`、`free -h`、`df -h`、`ss -lntp`でサーバー状態を確認する。
4. `journalctl`とnginxログでエラーを確認する。
5. 必要な場合だけスロークエリログを短時間有効にし、1回の対象リクエストを採取する。
6. ログをOFFに戻し、状態が`0`であることを確認する。
7. `mysqldumpslow`または`grep`で、実行時間の大きいSQLや繰り返されるSQLを抽出する。
8. `mysql`で該当テーブルの定義とインデックスを確認し、`EXPLAIN`で実行計画を調べる。
9. 変更を一つに絞って反映し、許可された同じ計測方法で比較する。

調査用のログ採取とスコア測定は分けます。ログを有効にした状態のスコアは、通常状態の比較値にしません。

## 関連資料

- [private-isuの競技ルールと採点条件](public_manual.md)
- [MySQLスロークエリログの採取・分析手順](kokeshi-practice1.md)
- [MySQLのテーブル定義・データ・EXPLAINの確認](kokeshi-practice2.md)
- [Goのpprofとキャッシュの練習](kokeshi-practice3.md)
- [このリポジトリの当日マニュアル](manual.md)

## 参考資料

1. [MariaDB Documentation: mariadb-dumpslow](https://mariadb.com/docs/server/clients-and-utilities/logging-tools/mariadb-dumpslow) — コマンド名とLinuxでの`mysqldumpslow`互換名。
2. [Ubuntu Packages: mysql-server-core](https://packages.ubuntu.com/search?keywords=mysql-server-core) — UbuntuのMySQL Server Coreパッケージ情報。
