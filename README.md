# sns-to-obsidian

Bluesky の公開 API、X の RSS と公式アーカイブから自分の投稿を取り出し、Obsidian の Daily note に書き込むためのスクリプトです。
Bluesky の CAR ファイルからの取り込みと、API を使った投稿の取得は別々のコマンドで行います。
Bluesky と X は別々のスクリプトで実行し、同じ Daily note 内の専用ブロックをそれぞれ更新します。

Daily note には以下の形式で挿入します。

```md
<!-- bsky-to-obsidian:start -->
`12:34` [Bluesky](https://bsky.app/profile/did:plc:srzuazebez52n6odhfuplmpq/post/3mvxa4mgkzc4m)
投稿本文全文

`13:20` [Bluesky](https://bsky.app/profile/did:plc:srzuazebez52n6odhfuplmpq/post/3mvxhqb2kxf2a)
投稿本文全文
<!-- bsky-to-obsidian:end -->

<!-- x-to-obsidian:start -->
`14:05` [X](https://x.com/kdmsnr/status/2101309425629979034)
X の投稿本文全文
<!-- x-to-obsidian:end -->
```

Bluesky の投稿リンクは、保存済みの DID と投稿 ID から生成します。
リンクのための追加の API 呼び出しは行いません。
DID や投稿 ID がない古い抽出データは、リンクなしで取り込みます。

挿入した部分を削除するスクリプトも用意しています。

## セットアップ

依存 gem を入れます。

```sh
bundle install
```

`config.example.yml` をコピーして、自分用の `config.yml` を作ります。

```sh
cp config.example.yml config.yml
```

`config.yml` はローカル設定用で、Git 管理しない想定です。
X だけを利用する場合は、`x` と `obsidian` の設定があれば実行できます。
CAR ファイルは不要です。

## 設定

以前の設定ファイルに `bluesky.out_dir` がある場合は、`bluesky.archive_dir` に変更してください。
さらに古い設定でトップレベルの `extract` に `car_path` と `out_dir` がある場合は、`bluesky.car_path` と `bluesky.archive_dir` に変更してください。
値はそのまま使えます。

例:

```yaml
bluesky:
  # handle か did を指定します。両方ある場合は did を優先します。
  handle: bsky.app
  # did: did:plc:example
  car_path: repo.car
  archive_dir: out

x:
  handle: kdmsnr
  # 別の RSS を使う場合だけ指定します。
  # feed_url: https://example.com/feed.xml
  archive_dir: x-archive

obsidian:
  vault_path: "/Users/user/Documents/obsidian"
  timezone: Asia/Tokyo
  daily:
    path_format: "Daily/%Y/%Y-%m-%d.md"
  posts:
    # 省略すると全期間を反映します。
    # days: 7
    exclude_texts: []
    replace_todos: true
```

## Bluesky

### アカウントと公開 API からの取り込み

`bluesky.handle` または `bluesky.did` に、公開 API と CAR ファイルの取得対象を指定します。
両方指定した場合は `did` を優先します。
DID を使うと、ハンドルの変更後も同じアカウントを取得できます。
自分への返信を含めて取り込み、他人への返信と他人の投稿のリポストは除外します。

通常の取り込みでは公開 API から100件ずつ取得し、保存済みの通常投稿（リポストを除く）が現れたページで止めます。
保存済みの投稿が見つからなければ、API が返す最終ページまで取得します。
`posts.jsonl` がまだなく、以前に抽出した `records.jsonl` がある場合は、初回の API 取得時にその履歴も取り込みます。

通常の取得は次のコマンドで実行します。

```sh
bundle exec ruby bsky_to_obsidian.rb
```

`--config PATH` と `--days N` を指定できます。

### CAR ファイルからの取り込み

Bluesky のアカウントを `bluesky.handle`（または `bluesky.did`）に設定します。
ログイン情報と RSS の URL は不要です。
過去分を CAR ファイルからまとめて取り込む場合は、次のどちらかで CAR ファイルを取得します。

1. Bluesky のページで「*設定 > アカウント > 私のデータをエクスポートする > CARファイルをダウンロード*」を選び、ファイルをスクリプトと同じディレクトリに保存する
2. 公開投稿であれば、次のコマンドでダウンロードする

   ```sh
   bundle exec ruby download_car.rb
   ```

ダウンロード先は `bluesky.car_path` で指定します。デフォルトは `repo.car` です。

CAR ファイルから投稿を取り込む場合は、専用コマンドを使います。

```sh
bundle exec ruby bsky_car_to_obsidian.rb path/to/repo.car
```

パスを省略すると、`bluesky.car_path` のファイルを使います。
投稿は保存済みの履歴とマージし、Daily note に反映します。
`obsidian.posts.days` または `--days N` を指定している場合も、履歴には全投稿を保存します。
設定の日数を無視して全期間を反映するには `--all` を指定します。

```sh
bundle exec ruby bsky_car_to_obsidian.rb --all path/to/repo.car
```

`bluesky.handle` を設定している場合は、アカウントの DID を確認するためネットワーク接続が必要です。
`bluesky.did` を設定している場合、CAR の取り込みにネットワーク接続は不要です。

### `bluesky.car_path`

CAR 取り込みコマンドでパスを省略した場合に使うファイルです。
デフォルトは `repo.car` です。
`download_car.rb` の保存先にも使います。

### `bluesky.archive_dir`

Bluesky の投稿履歴の保存先です。
CAR および API から取り込んだ投稿を `posts.jsonl` に蓄積します。
Daily note は `posts.jsonl` を優先し、なければ `records.jsonl` から生成します。
投稿は AT URI（DID と投稿 ID を含む識別子）でマージし、再取得した投稿を更新します。
今回取得しなかった投稿も保持するため、古い投稿の変更や削除は自動では反映しません。
このディレクトリは Git 管理の対象外なので、履歴を残すためにバックアップしてください。
保存先を変更した場合は、必要に応じて `.gitignore` にも追加してください。

## X

### アカウントと RSS からの取り込み

`x.handle` に Daily note に書き込む X のアカウント名を指定します。
RSS に他人の投稿のリポストが含まれていても、その投稿は Daily note には書き込みません。
RSS には返信先を判定する情報がないため、自分の返信は取り込みます。

通常の取得は次のコマンドで実行します。

```sh
bundle exec ruby x_to_obsidian.rb
```

`--config PATH` と `--days N` を指定できます。

### `x.feed_url`

X の RSS 2.0 フィードの URL です（省略可）。
省略時は `x.handle` から `https://fxtwitter.com/<handle>/feed.xml` を組み立てます。
別の RSS 取得先を使う場合だけ指定してください。
Bluesky 用スクリプトでは `x` の設定を使いません。

保存済みの RSS ファイルを取り込む場合:

```sh
bundle exec ruby x_to_obsidian.rb --feed-file path/to/feed.xml
```

`--days N` を併用できます。

### 公式アーカイブからの取り込み

公式アーカイブの取り込みには `x_archive_to_obsidian.rb` を使います。
X からダウンロードした ZIP ファイルを指定してください。
`x.handle` はアーカイブのアカウントに合わせて設定してください。

```sh
bundle exec ruby x_archive_to_obsidian.rb path/to/archive.zip
```

ZIP ファイルが1個入ったディレクトリも指定できます。

```sh
bundle exec ruby x_archive_to_obsidian.rb path/to/downloads
```

展開済みのアーカイブを使う場合は、そのディレクトリを指定します。

```sh
bundle exec ruby x_archive_to_obsidian.rb path/to/unpacked-archive
```

投稿データのファイルを直接指定することもできます。

```sh
bundle exec ruby x_archive_to_obsidian.rb path/to/unpacked-archive/data/tweets.js
```

投稿は RSS から取得した履歴と投稿 ID でマージし、Daily note に反映します。
`obsidian.posts.days` または `--days N` を設定した場合もアーカイブの全投稿を履歴に保存し、指定した期間だけ Daily note に反映します。
`--config PATH` で設定ファイルを指定できます。
設定の日数を無視して全期間を反映するには `--all` を指定します。`--days N` と `--all` は併用できません。

```sh
bundle exec ruby x_archive_to_obsidian.rb --all path/to/archive.zip
```

返信は取り込み、リポストは除外します。本文中の短縮 URL は取得できる範囲で展開します。
画像や動画のファイルは取り込みません。ZIP の読み込みには `unzip` コマンドが必要です。

### `x.archive_dir`

取得した RSS と、RSS および公式アーカイブから取り込んだ投稿履歴の保存先です。
デフォルトは `x-archive` で、Bluesky の抽出先とは独立しています。
投稿は `posts.jsonl` に投稿 ID ごとに蓄積し、再取得した投稿は最新の内容で更新します。
RSS の原本は `feeds/latest.xml` に上書きし、直近の1件だけ残します。
RSS から消えた投稿も履歴には残りますが、取得前に配信範囲から外れた投稿は復元できません。
このディレクトリは Git 管理の対象外ですが、過去の投稿を残すためにバックアップしてください。
保存先を変更した場合は、必要に応じて `.gitignore` にも追加してください。

旧形式の `feeds/<SHA-256>.xml` があれば、次回の取り込み時に未保存の投稿を履歴へ補完します。
履歴と `latest.xml` の保存に成功した後で旧形式の原本を削除します。

## Obsidian の設定

### `obsidian.vault_path`

Obsidian vault のパスです。iCloud Drive 上の vault はパスにスペースが入るので、YAML では引用符で囲んでください。

### `obsidian.daily.path_format`

Daily note の相対パスです。日付は `strftime` の形式で指定します。

たとえば次の設定は:

```yaml
path_format: "Daily/%Y/%Y-%m-%d.md"
```

次のような Daily note に対応します。

```text
Daily/2026/2026-05-15.md
```

### `obsidian.posts.exclude_texts`

本文に含まれていたら Obsidian に書き込まない文字列です。
Bluesky と X の両方に適用します。
Bluesky と X の履歴ファイルには、除外した投稿も残します。

### `obsidian.posts.replace_todos`

`true` を指定すると、Daily note に書き込む本文で、行頭の `* [ ]` と `- [ ]` をそれぞれ `* □` と `- □` に置き換えます。
Bluesky と X の両方に適用します。

```yaml
obsidian:
  posts:
    replace_todos: true
```

`exclude_texts` の判定は置換前の本文に対して行います。
置換は Daily note にのみ反映し、履歴ファイルの本文は変更しません。
`false` を指定するか設定を省略した場合は、従来どおりの形式で書き込みます。

### `obsidian.posts.days`

Bluesky と X のログを Obsidian に反映する日数です。
省略時は全期間を対象にします。
1 以上の整数を指定すると、`obsidian.timezone` での今日を含む直近 N 日分だけ反映します。
たとえば `days: 7` なら、今日から 6 日前までが対象です。

```yaml
obsidian:
  posts:
    days: 7
```

対象期間外の Daily note は変更しません。
取得と履歴保存の範囲は制限しません。
Bluesky の通常実行では保存済みの投稿に追いつくまで API を取得し、CAR の取り込みと X の RSS・公式アーカイブの履歴保存では入力全件を対象にします。
コマンドラインの `--days N` を指定した場合は、設定ファイルの値より優先します。

## Obsidian への書き込み

保存済みの Bluesky と X の履歴をまとめて書き込み直す場合:

```sh
bundle exec ruby upsert_obsidian_daily_notes.rb
```

投稿の再取得は行わず、履歴ファイルがないサービスはスキップします。
`--config PATH` と `--days N` を指定できます。
`--all` を指定すると、設定にかかわらず全期間を反映します。
反映日数を省略した場合は、設定ファイルの `obsidian.posts.days` に従います。

Daily note は保存済みの投稿履歴から日付ごとに生成し、管理ブロック内を時刻順に並べます。
本文の改行とリンク先を残し、元投稿へのリンクを付けます。
内容が変わったファイルだけ書き込み、手書きの本文は保持します。
各サービスの取り込みコマンドでは、そのサービスの管理ブロックだけを更新します。
API や RSS の取得または解析に失敗した場合は、履歴と Daily note を更新せずに終了します。

Bluesky は Daily note 内の次の管理ブロックを更新します。

```md
<!-- bsky-to-obsidian:start -->
...
<!-- bsky-to-obsidian:end -->
```

ブロックがなければ末尾に追加します。対象日の Daily note がなければ作成します。
X は同じルールで `<!-- x-to-obsidian:start -->` から `<!-- x-to-obsidian:end -->` までを更新します。

Bluesky と X の管理ブロックを削除する場合:

```sh
bundle exec ruby delete_obsidian_daily_notes.rb
```

vault 内の Markdown ファイルから両方の管理ブロックを削除します。
反映日数の設定や履歴ファイルの有無によらず全期間が対象で、手書きの本文、ノートファイル、保存済みの投稿履歴は残します。
