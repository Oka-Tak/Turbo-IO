# RayNeo iO から ChatGPT の dot 通話を開く

この変更は、Turbo IO の iOS 版から、iPhone の ChatGPT アプリにある自分の dot の通話を開く。
対象は OpenAI の ChatGPT dots であり、alc6 のローカル秘書 `~/projects/dot` とは別の機能である。
ChatGPT のアカウントと dot は ChatGPT アプリ内で選ぶ。
Turbo IO に OpenAI の API キー、ChatGPT の Cookie やログイントークンを入力する必要はない。

## 今回の接続範囲

```text
Turbo IO のボタン、または「ドットにつないで」
    → 設定済みの Apple ショートカット
    → ChatGPT の Open your dot / Call
    → ChatGPT アプリで自分の dot と通話
```

音声の出力先と入力マイクは、ChatGPT と iOS の Bluetooth 音声経路によって決まる。
眼鏡のスピーカーから聞けるか、眼鏡のマイクを使えるかは実機で確認する必要がある。
この経路で alc6 や Kairos を経由することはない。

**dot の返答を RayNeo の文字表示へ戻す機能は、今回の変更には含まれない。**
2026-10-18 に確認した公式文書は、ChatGPT 内の通話と Apple ショートカットによる起動を説明している。
dot の会話を OpenAI Chat Completions API として外部から呼び、返答を取得する公開手順は確認できていない。
通常の OpenAI API や alc6 の Kairos へ接続しても、自分の ChatGPT dot の会話や記憶を引き継ぐことにはならない。

## iPhone で準備するもの

1. ChatGPT の最新版を入れ、自分の dot を作成したアカウントでサインインする。公式案内では、dot 用 iOS ショートカットは 1.2026.279 から順次提供される。アカウントに dot へのアクセスが必要である。
2. Apple の「ショートカット」で新規ショートカットを作る。
3. ChatGPT の **Open your dot** アクションを追加し、自分の dot と **Call** モードを選ぶ。
4. 例えば `RayNeoでdot通話` という名前で保存する。
5. ショートカット単体で実行し、自分の dot の通話が開くことを確認する。

ChatGPT のログインや dot の作成、ショートカットの登録は iPhone 側で行う。
ソースコードに dot の名前、アカウント、認証情報を埋め込まない。

## 改造版 Turbo IO の設定

1. 「AIと会話 → ChatGPT dots → dot 通話のショートカットを設定」で、保存したショートカット名を入力する。
2. 「自分の dot との通話を開く」をタップする。
3. iOS がショートカットの起動を受理したかは診断に表示される。これは dot への接続成功や眼鏡の音声出力の証明にはならない。
4. タップ起動が動作したら、必要に応じて「『ドットにつないで』で開く」を有効にする。初期状態は無効であり、ショートカット名を変更すると再び無効になる。

音声起動の対象は「ドットにつないで」「ドットと通話」などの短い発話の完全一致だけ。
途中の音声認識、引用や説明文に含まれる文字列では起動しない。
音声からの起動は、RayNeo 公式アプリが前面にあり、公式の音声停止入口を確認できた場合だけ行う。
停止入口を使って公式の音声処理と Turbo IO の読み上げを終了してから、ショートカットを開く。
アプリが背面の場合や iPhone がロック中の場合の自動起動は対象外である。
ショートカットには名前だけを渡し、認識した質問、会話履歴、クリップボードは渡さない。通話が開いた後で dot に話しかける。

## Mac と alc6 の役割

- **alc6（Linux）**：この変更の作成と、Mac に渡すソースの準備を行う。ChatGPT dot のサーバーは alc6 に作らない。
- **Mac**：Xcode でテスト、拡張ライブラリのビルド、公式アプリの対応コピーへの組み込み、本人の証明書での署名を行う。
- **iPhone**：ChatGPT のログイン、dot の選択、ショートカットの作成、眼鏡の Bluetooth 音声経路を確認する。

既存の fork から次の開発ブランチを取得する。

```sh
git clone --branch codex/ios-dots-20261018 https://github.com/Oka-Tak/Turbo-IO.git
cd Turbo-IO
bash official-addon/test.sh
bash official-addon/build.sh embedded
bash official-addon/preview/build.sh
```

このブランチは、前回の日本語化・Kairos 接続の変更も含む。
既に同じブランチを取得している場合、古い ZIP のパッチを重ねて適用しない。
組み込みと署名は [iOS 拡張の手順](../official-addon/README.md)に従う。
公式アプリ 1.0.5（Build 201）などのバージョン・UUID 検査は維持する。
インストール前に本人が署名済みアプリと手順を確認する。

## 検証する内容

- Mac の Core テスト：空名・制御文字・長すぎる名前を拒否し、日本語や `&?#%+` を含む名前でも URL の query item が一つだけになる。
- Mac の音声コマンド判定テスト：起動フレーズの完全一致だけを受け付け、否定や引用を含む発話を拒否する。
- 画面プレビュー：設定行を表示するが、ChatGPT やショートカットを起動しない。
- 実機：タップ起動、前面での音声起動、Bluetooth 音声、通話終了後に RayNeo の通常会話へ戻れること。

alc6 には Xcode がないため、今回追加した Objective-C テストの実行、iOS ビルド、ChatGPT 通話と眼鏡の音声経路は未確認である。

## 一次資料

- [OpenAI: Message your dot — iOS widgets and shortcuts](https://learn.chatgpt.com/docs/dots/channels)
- [Apple: Run a shortcut using a URL scheme](https://support.apple.com/guide/shortcuts/run-a-shortcut-from-a-url-apd624386f42/ios)
