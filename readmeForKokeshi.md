# private-isuをColimaで起動してベンチマークを取る

この手順はmacOS上でColimaとDockerを使い、private-isuを起動してベンチマークを実行する方法です。

## 1. Colimaを起動

```sh
colima start
docker info
```

`docker info`の`Server`欄にColima上のDocker情報が表示されれば、Dockerデーモンに接続できています。

## 2. Dockerの認証ヘルパーエラーが出る場合

`docker-credential-osxkeychain: executable file not found`と表示された場合、Docker設定が存在しない認証ヘルパーを参照している可能性があります。設定をバックアップします。

```sh
cp ~/.docker/config.json ~/.docker/config.json.bak
```

`~/.docker/config.json`をエディタで開き、`"credsStore": "osxkeychain"`の項目だけを削除して保存します。たとえば、次の設定なら空のJSONにします。

```json
{
  "credsStore": "osxkeychain"
}
```

```json
{}
```

ほかの設定がある場合は残します。Docker Desktopを使っている場合は再起動してから、`docker info`で接続を確認します。

## 3. 初期データを準備

リポジトリのルートディレクトリで実行します。

```sh
cd /path/to/private-isu
make init
```

`/path/to/private-isu`は、このリポジトリを置いた実際のパスに読み替えてください。初期データのダウンロードが終わるまで待ちます。

## 4. アプリケーションを起動

```sh
cd webapp
docker compose up -d --build
docker compose ps
```

`nginx`、`app`、`mysql`、`memcached`の各サービスが一覧に表示されることを確認します。初回はMySQLの初期化に時間がかかる場合があります。ログは次のコマンドで確認でき、表示を終えるには`Ctrl-C`を押します。

```sh
docker compose logs -f
```

アプリが応答するか確認します。

```sh
curl -i http://localhost/
```

Compose設定ではnginxがホストの80番ポートを使います。

## 5. ベンチマーカーのDockerイメージをビルド

別のターミナル、またはアプリを起動したターミナルから、リポジトリのベンチマーカーのディレクトリへ移動します。

```sh
cd /path/to/private-isu/benchmarker
docker build -t private-isu-benchmarker .
```

## 6. ベンチマークを実行

アプリケーションを起動したまま、次を実行します。

```sh
docker run --network host -i private-isu-benchmarker \
  /bin/benchmarker -t http://host.docker.internal -u /opt/userdata
```

成功時の例：

```json
{"pass":true,"score":1178,"success":1017,"fail":0,"messages":[]}
```

`pass:true`かつ`fail:0`なら、ベンチマークは成功です。スコアは実行環境や負荷によって変わります。

## トラブルシューティング

### `初期化リクエストに失敗しました`

ベンチマーカーからアプリに接続できていない可能性があります。`webapp`ディレクトリで`docker compose ps`を実行し、サービスが起動しているか確認します。サービスが表示されなければ、`docker compose up -d --build`で起動してください。

```sh
curl -i http://localhost/
```

このコマンドでアプリの応答も確認してください。初期化中なら、`docker compose logs -f`でMySQLやアプリのログを見て、起動後にベンチマークを再実行します。

### `meta.db: input/output error`

Colima内のDockerストレージで読み書きに失敗している可能性があります。まずColimaを再起動し、Dockerの基本動作を確認します。

```sh
colima stop
colima start
docker run --rm hello-world
```

容量とinodeの使用率は次で確認できます。`df -h`の`Use%`は容量の使用率、`df -i`の`IUse%`はinodeの使用率です。

```sh
colima ssh -- df -h / /var/lib/docker
colima ssh -- df -i / /var/lib/docker
```

この環境では容量・inodeに空きがあり、`hello-world`も成功した後にベンチマーカーのイメージを再ビルドできました。原因確認前に`docker system prune`や`colima delete`を実行すると、ほかのDockerデータを消す可能性があるため注意してください。
