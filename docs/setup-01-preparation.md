# 遠隔構成の練習に向けた準備

確認日: 2026-11-02

private-isu を使い、アプリサーバーとDBの間に地域間の遅延がある構成で、性能改善とAWS運用を練習する。この文書は、練習を始める前に用意するものをまとめる。

## 練習方針

private-isu の初期状態は1台構成で、遠隔の要素がない。そのため、アプリとDBを別サーバーに分け、間に遅延を入れる。アプリのDBとmemcachedの接続先は環境変数（`ISUCONP_DB_HOST`、`ISUCONP_MEMCACHED_ADDRESS`）で変更できる。

2026-10-31の本番では、全台が `ap-northeast-1d` にありながら、europe1とamerica1からDBまでのRTTが約100msだった。遅延はRouter側で作られていた可能性が高い（具体的な設定は未確認）。そこで、次の2段階で練習する。

| 段階 | 方法 | 目的 | 費用 |
| --- | --- | --- | --- |
| 1. 主な練習 | 東京の同じAZに置き、`tc netem` で100msの遅延を入れる | 遅延の値を変えながら、性能改善を繰り返す | 低い |
| 2. 仕上げ | アプリを米国オレゴンに置き、東京のDBとVPCピアリングで接続する | 実際のリージョン間のVPC、経路、転送課金を経験する | 転送料金が増える |

## 構成

```text
bench ──> app1 (nginx + Go) ──RTT約1ms───> db (MySQL + memcached)
bench ──> app2 (nginx + Go) ──RTT約100ms─> db
```

| サーバー | 役割 | インスタンスタイプ |
| --- | --- | --- |
| app1 | 近いアプリ | `c7a.large` |
| app2 | 遠いアプリ | `c7a.large` |
| db | MySQL、memcached | `c7a.large` |
| bench | ベンチマーカー | `c7a.xlarge` |

インスタンスタイプはprivate-isuのREADMEの推奨に合わせた。最初は1台で動かして基準スコアを取り、その後 db、app2 の順に分ける。

## AWS側の準備

- [ ] AWS Budgets で月額の上限通知を設定する（最初に済ませる）
- [ ] 作業用のIAMユーザーを作り、MFAを有効にする
- [ ] AWS CLI を導入して設定する（`brew install awscli`、`aws configure`）
- [ ] 東京リージョンで `ami-09201e964bee13733`（`catatsuy_private_isu_amd64_20260524`）が使えるか確認する
- [ ] Service Quotas で `c7a` を4台起動できるか確認する
- [ ] 有料インスタンスを使うことを了承する（無料枠のサーバーでは実用にならない）
- [ ] 練習が終わるたびに、インスタンスを停止または削除する

## 手元のMacの準備

- [ ] Ansible を導入する（`2026-10-31-isucon-practice` の仕組みを流用するため）
- [ ] 無料で練習する場合は `scripts/practice.sh` でColima上の環境を使う

Macのディスクは `scripts/clean-local-disk.sh` で空ける。初期データはColimaの `private-isu_mysql` ボリュームとベンチマーカーのイメージに残っているので、ボリュームを消さない限り `make init` は不要である。

## 既存サーバーの扱い

`isucon2026-aws-kokeshi` のサーバーは、確認時点でSSHがタイムアウトした。停止中か、セキュリティグループのIP制限が原因と考えられるが、未確認である。

固定IPなしで停止と起動をすると接続先の名前が変わるため、aliasの宛先が古くなっている可能性もある。また、ログインユーザーが `ec2-user` であり、Ubuntuの公式AMIとは別物である。このサーバーはAWS CLIや接続の確認に使う。

## 遅延の影響を確認する項目

- クエリの往復回数（RTT 100msではN+1の影響が大きい）
- Go実装のDB接続設定（`interpolateParams` が無効で、接続プールも未設定）
- memcachedのセッション読み取りにかかる遅延
- ローカル保存に変えた画像の、アプリ2台での共有
- nginxからapp1、app2への振り分けの重み

ベンチマーカーの1リクエストのタイムアウトは10秒、実行時間は60秒である。遅延なしと100msのスコアを比べ、距離が効いている箇所を確かめる。

## 文書の命名規則

文書は `docs/` に `<prefix>-<連番2桁>-<内容>.md` の形式で置く。連番はprefixごとに振る。

| prefix | 内容 | 例 |
| --- | --- | --- |
| `setup` | 準備、環境構築 | `setup-01-preparation.md` |
| `arch` | 構成の設計、学習メモ | `arch-01-latency-topology.md` |
| `ops` | AWS運用、手順、課金 | `ops-01-start-stop.md` |
| `perf` | 性能改善の計測と結果 | `perf-01-baseline.md` |
