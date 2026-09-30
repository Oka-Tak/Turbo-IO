# RayNeo iO から Kairos に質問する

この構成では、眼鏡の音声認識で得た質問を Turbo IO が Kairos へ送り、回答を眼鏡に表示する。
Turbo IO の iOS 版と Android 版は、同じ OpenAI Chat Completions 形式の接続先を使う。
Kairos の予定やタスクの変更は行わない。

## Kairos の準備

Kairos に眼鏡用の `/api/glasses/chat/completions` 経路を導入し、AI モジュールを有効にする。
この経路は通常のログインセッションを受け付けず、専用の API トークンを要求する。
Kairos の「設定 → API と MCP」で「RayNeo iO 用（質問のみ）」を選び、iPhone 用と Android 用のトークンを別々に発行する。
各トークンの権限は `glasses:write` だけにする。
「write」は Kairos に会話履歴を記録するための権限名であり、この経路から予定やタスクは変更できない。
トークンの平文は発行直後だけ表示されるので、それぞれの端末に設定して保管する。

Kairos は現在 tailnet 内で公開されている。
各スマートフォンから Kairos の HTTPS URL に到達するには、その端末で Tailscale を接続する必要がある。
接続先は `https://<Kairos の tailnet ホスト>/api/glasses/chat/completions` とする。
ホスト名やトークンはソースコードや共有するスクリーンショットに書かない。

## iPhone

Mac で [V2 の構築手順](../official-addon/README.md)に従って拡張機能をビルドし、対応する公式 iOS アプリのコピーに組み込み、自分の証明書で署名する。
公式アプリの対応バージョン、Build、Runner UUID の検査は省略しない。
通常の追加機能には眼鏡のファームウェア変更は不要である。

ユーザーの iPhone に入っているアプリは **1.0.5（Build 201）** と確認済み。
Mac で実際に組み込むには、これとは別に、利用権限のある未暗号化の `Payload/Runner.app` が必要になる。
通常の App Store から取得した暗号化済み IPA をそのまま入力にはできない。
Turbo IO の開発元は、1.0.5（Build 201）の[入力用 IPA を GitHub Release で案内している](https://github.com/Turbo1123/Turbo-IO/releases/tag/rayneo-ios-1.0.5-201)。
配布ファイルは公式アプリのバイナリのコピーであり、Turbo IO のソースライセンスがこのバイナリの利用権を与えるわけではない。利用条件と入手元を自分で確認してから使用する。
Release に記載されたファイル名は `RayNeo_AI_1.0.5_201_decrypted_original.ipa`、SHA-256 は `39d12aff8f2b312dc3b40ce784a444e52c536e61378434005255177548df966a`。
Mac で取得したら `shasum -a 256 /path/to/RayNeo_AI_1.0.5_201_decrypted_original.ipa` で照合する。
この版の入力は Bundle ID `com.rayneo.venus.pub`、Runner UUID `748fd301da603095a2449bd0558faca5` に一致する必要がある。
バージョン表示だけを合わせた別のバイナリは使わない。

この Linux 機で作成した最新の変更は、GitHub へ push できない場合でも `turbo-io-kairos-ios-android.patch` から取り込める。
Mac では fork の `codex/ios-ja-first-pass` ブランチを clone し、パッチをコピーした上で、リポジトリのルートで `git am /path/to/turbo-io-kairos-ios-android.patch` を実行する。
その後、完全な Xcode、Node.js 22.16 以上、Python 3 を用意し、次を実行する。

```sh
bash official-addon/test.sh
bash official-addon/build.sh embedded
```

生成される `official-addon/build/embedded/TurboIOPrivateAddon.dylib` はまだインストールできるアプリではない。
[公式アプリとの合成手順](../official-addon/README.md#2-只在本机生成自己的包)で、手元の `Runner.app`、自分の開発用証明書と provisioning profile、iPhone のデバイス ID を指定して IPA を生成する。
入力アプリは上書きしない。既存の公式アプリを削除する前に、生成したアプリの起動と眼鏡接続を確認する。

Turbo IO の「AI と会話 → API とキー」で Kairos の HTTPS URL、モデル名 `kairos`、iPhone 用トークンを入力する。
「診断 → モデル API をテスト」で接続を確認し、「現在の回答方法」で独自モデルを選ぶ。
公式アプリの会話データ形式が確認できるまで、独自モデルへの切り替えは保留される。
追加した日本語のタブ判定は「RayNeo／グラス／メモリー／発見」の四項目がそろったときだけ底部に Turbo IO を表示する。
判定できない場合は浮動ボタンを使う。

## Android

[Android 版の構築手順](../android-addon/README.md)に従い、対応する公式 APK を入力として拡張版を生成し、自分の鍵で署名する。
通常の質問応答に実験用ファームウェアの書き込みは不要である。
既にスマートフォンへ入れた中国語表示の APK は、ソースコードを更新しただけでは日本語版にならない。更新した APK を生成してインストールする必要がある。

Turbo IO の「モデルと会話」で独自モデルを選び、同じ形式の Kairos HTTPS URL、モデル名 `kairos`、Android 用トークンを入力する。
Android の端末内読み上げは、日本語のオフライン音声がインストールされている場合にだけ使う。

## 現時点の検証範囲

Kairos の経路は質問を受け、読み取り専用の回答を OpenAI 互換の SSE で返す実装になっている。
両 OS のクライアントはこの経路では端末側の検索・ToDo ツールを呼ばず、会話履歴は Kairos 側で端末ごとのトークンに分けて保存する。
実機の眼鏡への表示、iOS の Xcode ビルド、Android の APK 生成と署名はまだ確認していない。
