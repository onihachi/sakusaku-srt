# ローカル日本語文字起こし

動画・音声ファイルから音声を16 kHzのモノラルWAVへ一時変換し、ローカルの whisper.cpp で日本語SRTを作ります。通常はWhisperのトークン時刻付きJSONを一時ディレクトリへ出力し、句点などを基準に読みやすい字幕へ分割します。JSONは処理後に削除され、入力ファイル自体は変更しません。既存のSRTがある場合は、上書き前に `.srt.bak` へ退避します。

## 必要なもの

- Apple Silicon搭載Mac、zsh / bash
- Homebrew版 `ffmpeg` / `ffprobe`（`/opt/homebrew/bin`）
- Homebrew版 `whisper-cli`（`/opt/homebrew/bin`）
- Python 3（JSONからSRTへの変換に使用、標準ライブラリのみ）
- Whisperモデル（既定: `~/.cache/whisper/ggml-large-v3-turbo.bin`）

VADモデル `~/.cache/whisper/ggml-silero-v5.1.2.bin` があれば自動で使います。ない場合は通常の文字起こしを行います。VADを明示的に止めるには `--no-vad` を指定します。

## 初回セットアップ

whisper.cpp 本体（未導入の場合）:

```bash
brew install whisper-cpp ffmpeg
```

モデルの取得（1回だけ。約1.5GB）:

```bash
mkdir -p ~/.cache/whisper && curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

VADモデル（任意・約1MB）:

```bash
curl -L -o ~/.cache/whisper/ggml-silero-v5.1.2.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
```

## 実測（M1 Max）

- 処理速度: 約 **15倍速**（30秒の音声を約2秒、14分の動画なら1分弱）
- 日本語の専門用語テストでは、語彙ファイルに登録した用語が 10/11 で正しく認識されました（残り1件も、テスト音声側の発音誤りが原因と判明）。語彙なしでは「昇華転写→消化転写」「ボールチェーン→ボールジョン」などの誤りが発生します。

## 使い方

単一ファイル（入力と同じ場所に同名のSRTを作成）:

```bash
./transcribe.sh "/path/to/myvideo.mp4"
```

複数ファイル:

```bash
./transcribe.sh "video 1.mp4" "video 2.mov" interview.m4a
```

独自の語彙ファイルと出力先を指定:

```bash
./transcribe.sh --vocab ./project_vocab.txt --outdir ./srt ./movie.mp4
```

句点のない長い発話を読点で分け始める文字数を変更:

```bash
./transcribe.sh --max-chars 60 ./movie.mp4
```

比較・デバッグ用に、文分割せずWhisperのSRTをそのまま使う場合:

```bash
./transcribe.sh --raw-srt ./movie.mp4
```

モデルを変更する場合は `--model PATH`、または環境変数 `WHISPER_MODEL` を使えます。全オプションは `./transcribe.sh --help` で確認できます。

## vocab.txtについて

同じフォルダの `vocab.txt` は、Whisperが専門用語や商品名を正しく認識しやすくするための語彙集です。1行に1語を書き、コメントは `#` で始めます。語句は `、` で連結して動画全体の初期プロンプトに使われます。ファイルがなければプロンプトなしで処理します。

実地テストでは、語彙を長くすると「昇華転写」「ボールチェーン」などの認識精度が上がる一方、Whisperが長い連続テキストを返しやすくなりました。そのため通常モードでは、JSON内の各トークン時刻を使ってスクリプト側で文を分割します。必要な用語は追加できますが、プロンプトのトークン上限もあるため、すべての単語を詰め込まず、実際に誤認識される語へ絞るのがおすすめです（目安は合計約200文字以内）。

作成したSRTは [さくさくSRT](../sakusaku_srt.html) で開き、誤認識や改行、タイミングを仕上げる用途を想定しています。
