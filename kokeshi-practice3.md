# 練習 3: Goのpprofで処理を測り、キャッシュ候補を考える

この練習では、MySQLのslow query logだけでは分からないGoアプリ内のCPU処理やメモリ使用量を調べ、結果からキャッシュを使う場所があるか考えます。アプリのコードは調査対象として読み、計測用の変更はローカル練習環境だけに一時追加します。

## 1. 何を調べるか

ボトルネックによって使う道具が変わります。

| 観察したこと | 調べる場所・方法 |
| --- | --- |
| SQLの実行時間が長い、同じSQLが何度も出る | MySQL slow query log、`mysqldumpslow`、`EXPLAIN` |
| HTTP応答が遅いが、DBのSQL時間は短い | GoのCPU profile、実行トレース、アプリコード |
| GoプロセスのメモリやGCが気になる | Goのheap profile、`docker stats` |
| 同じデータを何度も読み、DB負荷が大きい | SQLの呼び出し回数とアプリの呼び出し元からキャッシュ候補を検討 |

`pprof`のCPU profileは、GoプログラムがCPUを使っている時間を集計します。MySQLの応答待ちやネットワーク待ちの時間は、CPUを使っていないためCPU profile上では目立たないことがあります。DB待ちを疑うときはslow query logも併用します。[1]

このリポジトリのGoアプリはchiのルーターを使い、`http.ListenAndServe(":8080", r)`でHTTPサーバーを起動します。Memcachedはセッション保存に使われていますが、投稿やコメントなどのページデータをキャッシュする処理は現在のGoコードにはありません。Memcachedコンテナが起動していることと、ページデータがキャッシュされていることは別です。[2]

## 2. pprofをローカル練習環境だけで有効にする

`net/http/pprof`をインポートし、別のHTTPサーバーでprofile用のハンドラーを起動します。既存アプリはchiルーターを使うため、DefaultServeMuxに登録されるpprof用のHTTPサーバーを別ポートで起動します。

`webapp/golang/app.go`のimportに一時的に追加します。

```go
_ "net/http/pprof"
```

同じファイルの`main`関数で、通常のアプリサーバーを起動する直前に次を追加します。

```go
go func() {
	if err := http.ListenAndServe(":6060", nil); err != nil {
		log.Printf("pprof server: %v", err)
	}
}()
```

`webapp/compose.yml`の`app`サービスに、ホストのループバックアドレスだけへポートを公開する設定を一時追加します。

```yaml
  app:
    ports:
      - "127.0.0.1:6060:6060"
```

pprofにはメモリや処理内容を調べる情報が含まれるため、インターネットに公開しません。この設定は自分のMacからの接続だけに限定しています。ISUCON本番サーバーには追加しないでください。

アプリをビルドし直して起動します。`webapp`ディレクトリから実行します。

```sh
docker compose up -d --build app
curl -fsS http://127.0.0.1:6060/debug/pprof/ | head
```

HTMLが表示されればprofile用サーバーに接続できています。`curl`が接続できない場合は、アプリのビルド・起動状態、`docker compose logs --tail=80 app`、Composeのport設定を確認します。

## 3. CPUを多く使うGo関数を見つける

CPU profileは調べたい時間帯に実際のリクエストを処理させて採取します。まず1つ目のターミナルで次を実行します。Go SDKが入ったホスト上のターミナルで実行してください。

```sh
go tool pprof -top 'http://127.0.0.1:6060/debug/pprof/profile?seconds=30'
```

このコマンドは30秒間profileを採取し、CPU時間の多い関数を表で表示します。採取中に2つ目のターミナルから対象ページへ繰り返しアクセスします。例はトップページを約10回/秒で開きます。調査目的の負荷なので、ベンチマークスコアの測定には使いません。

```sh
cd webapp
while :; do
  curl -sS -o /dev/null http://localhost/ || break
  sleep 0.1
done
```

profileの採取が終わったら、リクエストを送るループは`Ctrl-C`で止めます。この例はレスポンスが短い場合に最大約10回/秒でトップページへアクセスします。pprofの`top`出力では、主に次を見ます。

- `flat`: その関数自身が使ったCPU時間。
- `cum`: その関数と、そこから呼び出した関数が使ったCPU時間の合計。
- `flat%`、`cum%`: profile全体に占める割合。

特定の関数を調べる場合は、インタラクティブなpprofを起動します。

```sh
go tool pprof 'http://127.0.0.1:6060/debug/pprof/profile?seconds=30'
```

表示された`(pprof)`プロンプトで次を入力します。

```text
top
list getIndex
quit
```

`top`はCPU使用量の多い関数、`list getIndex`は`getIndex`関数のソースコードとprofile値を表示します。関数名は実際の出力に合わせて指定します。関数内のDB呼び出しが遅いかどうかは、CPU profileだけで判断せずslow query logやリクエスト全体の時間と比べます。

## 4. メモリprofileを見る

処理が遅い原因が大量の一時オブジェクトやメモリ確保にあるか調べるにはheap profileを使います。

```sh
go tool pprof -top 'http://127.0.0.1:6060/debug/pprof/heap'
```

heap profileは主に現在メモリ上に残っているデータを見ます。profile中の`inuse_space`は現在使用中のバイト数、`alloc_space`はプログラム開始後に確保した累積バイト数です。頻繁な確保やGCがCPU profileで目立つ場合は、heap profileでどの関数が多くのデータを作っているか確認します。[1][3]

profile採取自体にも負荷があります。pprofを有効にした状態のスコアは通常状態のスコアと比較しません。CPU、heapなどのprofileを同時に何種類も採らず、必要なものを一つずつ調べます。

## 5. profile結果からキャッシュ候補を考える

キャッシュは、毎回行う処理を減らす仕組みです。profileでCPU使用量が多い関数を見つけても、すぐにキャッシュを足すとは限りません。まず、同じ入力に対して同じ結果を何度も作っているか、同じDBデータを何度も読んでいるかを確認します。

### キャッシュを検討しやすい処理

- 複数のリクエストから同じデータが繰り返し読まれる。
- SQLやCPU処理のコストが大きく、結果の再利用でその処理を省ける。
- データが変わったときにキャッシュを更新・削除できる。
- 数秒から数分程度古い値を返しても、機能上問題がない。

### キャッシュに向きにくい処理

- ほとんど毎回異なる入力やユーザー固有のデータで、再利用されない。
- もともと処理が十分速く、キャッシュへの通信・変換の方が高くつく。
- 更新直後の正確な値が必要で、古い値を返すことが許されない。
- キャッシュキーに必要な条件をすべて含められず、別ユーザーや別条件のデータが混ざる。

今回のコメント取得SQLなら、投稿ごとのコメント一覧が複数リクエストで何度も読まれ、遅いSQLとして確認できた場合は候補になります。ただし、先に複合インデックスでデータ取得そのものを十分速くできるかを調べます。軽くなったSQLをキャッシュすると、キャッシュ管理の複雑さだけが増えることがあります。

キャッシュはDBやCPUの仕事を減らす代わりに、アプリとMemcachedのメモリを使います。Colimaの割当が約2 GiBのこの練習環境では、大きなデータを安易にキャッシュせず、`docker stats`で使用量を確認しながら小さく試します。

### キャッシュを試す設計

最小の「cache-aside」方式では、アプリは次の順で動きます。

1. すべての検索条件を含むキーでMemcachedを読む。
2. 値があればそれを返す（cache hit）。
3. 値がなければMySQLから取得する（cache miss）。
4. 取得結果を期限付きでMemcachedへ保存し、レスポンスを返す。
5. 投稿やコメントが更新・削除されたら、関連キーを削除または更新する。

キーには投稿IDだけでなく、表示順・件数・ユーザー権限など結果を変える条件も含めます。ユーザー別の情報を全ユーザー共通のキーに入れないようにします。MySQLを正本データとし、Memcachedの値がなくてもMySQLから再取得できるようにします。TTL（有効期限）は古い値を残す時間の上限で、更新時の整合性を保つ無効化処理の代わりとは限りません。

## 6. キャッシュの効果を確かめる

キャッシュの前後で、同じデータ状態・同じリクエスト・同じ環境を使います。キャッシュ導入後は、少なくとも次を確認します。

- cold cache（空のキャッシュ）とwarm cache（同じリクエスト後）の応答時間。
- cache hit / miss回数とMemcachedへの接続エラー。
- 対象SQLの実行回数・合計時間が減ったか。
- 投稿・コメントを作成、編集、削除した後に画面へ正しい内容が反映されるか。
- Memcached停止やキャッシュmissでもアプリがMySQLから取得して動くか。
- MemcachedとGoアプリのメモリ使用量が許容範囲か。

キャッシュを有効にした直後の最初のアクセスはmissになるため、1回だけの測定では効果を判断できません。cold/warm双方を記録し、同じ状態にリセットして複数回比べます。ベンチマーク中はslow query logをOFFにします。DBのリセット方法とベンチマーク結果の扱いは[`kokeshi-practice1.md`](kokeshi-practice1.md)を参照してください。

## 7. 練習後に一時変更を戻す

`webapp/golang/app.go`からpprof用importとサーバー起動コードを取り除き、`webapp/compose.yml`から`127.0.0.1:6060:6060`のport設定を取り除いてから通常のGoアプリを再ビルドします。自分が追加した行だけを戻し、作業前からあった変更をまとめて破棄しないようにします。

```sh
cd webapp
docker compose up -d --build app
```

## 参考資料

1. [Go Diagnostics](https://go.dev/doc/diagnostics) — CPU profile、heap、block、mutex profileの用途と制約。
2. [Go package `net/http/pprof`](https://pkg.go.dev/net/http/pprof) — profile HTTP endpointの登録と使い方。
3. [Go package `runtime/pprof`](https://pkg.go.dev/runtime/pprof) — heap、allocsなどprofileの意味。
4. [MySQL 9.7 Reference Manual: How MySQL Uses Indexes](https://dev.mysql.com/doc/refman/9.7/en/mysql-indexes.html) — DBアクセスの調査にインデックスを使う仕組み。
