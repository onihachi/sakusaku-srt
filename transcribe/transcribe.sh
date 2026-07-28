#!/usr/bin/env bash

set -euo pipefail

FFMPEG_BIN="/opt/homebrew/bin/ffmpeg"
FFPROBE_BIN="/opt/homebrew/bin/ffprobe"
WHISPER_BIN="/opt/homebrew/bin/whisper-cli"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
DEFAULT_MODEL="${HOME}/.cache/whisper/ggml-large-v3-turbo.bin"
VAD_MODEL="${HOME}/.cache/whisper/ggml-silero-v5.1.2.bin"

script_path="${BASH_SOURCE[0]}"
if [[ "$script_path" == */* ]]; then
    script_dir_part="${script_path%/*}"
else
    script_dir_part="."
fi
SCRIPT_DIR="$(cd -- "$script_dir_part" && pwd -P)"
JSON_CONVERTER="${SCRIPT_DIR}/srt_from_json.py"

usage() {
    cat <<'EOF'
使い方:
  transcribe.sh [options] <file> [more files...]

オプション:
  -m, --model PATH   Whisperモデル（既定: $WHISPER_MODEL または
                     ~/.cache/whisper/ggml-large-v3-turbo.bin）
  -v, --vocab PATH   認識を補助する語彙ファイル（既定: スクリプト横の vocab.txt）
  -o, --outdir DIR   SRTの出力先（既定: 各入力ファイルと同じディレクトリ）
  -l, --lang LANG    音声の言語（既定: ja）
      --max-len N    1字幕の最大文字数。0ならWhisperに任せる（既定: 0）
      --max-chars N  句点がない長文を読点で分割し始める文字数（既定: 80）
      --raw-srt      JSON文分割を使わず、WhisperのSRTをそのまま出力
      --no-vad       VADを使わない
  -h, --help         このヘルプを表示

例:
  ./transcribe.sh myvideo.mp4
  ./transcribe.sh -v custom_vocab.txt video1.mp4 video2.mov
EOF
}

error() {
    printf 'エラー: %s\n' "$*" >&2
}

require_value() {
    if [[ $# -lt 2 || -z "${2-}" ]]; then
        error "$1 には値が必要です。"
        usage >&2
        exit 2
    fi
}

model_path="${WHISPER_MODEL:-$DEFAULT_MODEL}"
vocab_path="${SCRIPT_DIR}/vocab.txt"
custom_outdir=""
lang="ja"
max_len="0"
max_chars="80"
raw_srt=0
disable_vad=0
inputs=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)
            require_value "$@"
            model_path="$2"
            shift 2
            ;;
        -v|--vocab)
            require_value "$@"
            vocab_path="$2"
            shift 2
            ;;
        -o|--outdir)
            require_value "$@"
            custom_outdir="$2"
            shift 2
            ;;
        -l|--lang)
            require_value "$@"
            lang="$2"
            shift 2
            ;;
        --max-len)
            require_value "$@"
            max_len="$2"
            shift 2
            ;;
        --max-chars)
            require_value "$@"
            max_chars="$2"
            shift 2
            ;;
        --raw-srt)
            raw_srt=1
            shift
            ;;
        --no-vad)
            disable_vad=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                inputs+=("$1")
                shift
            done
            ;;
        -*)
            error "不明なオプションです: $1"
            usage >&2
            exit 2
            ;;
        *)
            inputs+=("$1")
            shift
            ;;
    esac
done

if [[ ${#inputs[@]} -eq 0 ]]; then
    error "入力ファイルを1つ以上指定してください。"
    usage >&2
    exit 2
fi

if ! [[ "$max_len" =~ ^[0-9]+$ ]]; then
    error "--max-len には0以上の整数を指定してください: $max_len"
    exit 2
fi

if ! [[ "$max_chars" =~ ^[0-9]+$ ]] || [[ "$max_chars" -lt 1 ]]; then
    error "--max-chars には1以上の整数を指定してください: $max_chars"
    exit 2
fi

if [[ ! -x "$FFMPEG_BIN" ]]; then
    error "ffmpeg が見つかりません: $FFMPEG_BIN"
    printf 'Homebrewで導入する場合: brew install ffmpeg\n' >&2
    exit 1
fi

if [[ ! -x "$FFPROBE_BIN" ]]; then
    error "ffprobe が見つかりません: $FFPROBE_BIN"
    printf 'ffprobeはffmpegに含まれます: brew install ffmpeg\n' >&2
    exit 1
fi

if [[ ! -x "$WHISPER_BIN" ]]; then
    error "whisper-cli が見つかりません: $WHISPER_BIN"
    printf 'Homebrewで導入する場合: brew install whisper-cpp\n' >&2
    exit 1
fi

python_bin=""
if [[ "$raw_srt" -eq 0 ]]; then
    python_bin="$(command -v python3 || true)"
    if [[ -z "$python_bin" ]]; then
        error "python3 が見つかりません。JSONからSRTへの変換にPython 3が必要です。"
        printf 'Homebrewで導入する場合: brew install python\n' >&2
        exit 1
    fi
    if [[ ! -f "$JSON_CONVERTER" ]]; then
        error "JSON→SRT変換スクリプトが見つかりません: $JSON_CONVERTER"
        exit 1
    fi
fi

if [[ ! -f "$model_path" ]]; then
    error "Whisperモデルが見つかりません: $model_path"
    printf 'ダウンロード先ディレクトリを作成してから、次を実行してください:\n' >&2
    printf '  mkdir -p "%s/.cache/whisper"\n' "$HOME" >&2
    printf '  curl -L "%s" -o "%s"\n' "$MODEL_URL" "$DEFAULT_MODEL" >&2
    exit 1
fi

detect_threads() {
    local count
    count="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)"
    if ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]]; then
        count="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    fi
    if ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]]; then
        count=1
    fi
    if [[ "$count" -gt 8 ]]; then
        count=8
    fi
    printf '%s' "$count"
}

build_prompt() {
    local file="$1"
    awk '
        {
            sub(/\r$/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            if (found) printf "、"
            printf "%s", $0
            found = 1
        }
        END { if (found) printf "\n" }
    ' "$file"
}

rotate_backup_if_needed() {
    local backup="$1"
    local number=1
    local rotated

    if [[ ! -e "$backup" ]]; then
        return 0
    fi

    rotated="${backup}.${number}"
    while [[ -e "$rotated" ]]; do
        number=$((number + 1))
        rotated="${backup}.${number}"
    done

    if ! mv -- "$backup" "$rotated"; then
        return 1
    fi
    printf '  既存バックアップを退避: %s → %s\n' "${backup##*/}" "${rotated##*/}"
}

recover_srt_after_failure() {
    local output="$1"
    local backup="$2"
    local had_backup="$3"

    if [[ -e "$output" ]]; then
        if ! rm -f -- "$output"; then
            error "失敗した出力SRTを削除できません: $output"
            return 0
        fi
    fi

    if [[ "$had_backup" -eq 1 ]]; then
        if mv -- "$backup" "$output"; then
            printf '  元のSRTを復元しました: %s\n' "$output" >&2
        else
            error "元のSRTを復元できません。バックアップを確認してください: $backup"
        fi
    fi

    return 0
}

threads="$(detect_threads)"
prompt=""
if [[ -f "$vocab_path" ]]; then
    prompt="$(build_prompt "$vocab_path")"
else
    printf '情報: 語彙ファイルが見つからないため、プロンプトなしで実行します: %s\n' "$vocab_path" >&2
fi

vad_enabled=0
if [[ "$disable_vad" -eq 0 && -f "$VAD_MODEL" ]]; then
    vad_enabled=1
fi

tmp_root="${TMPDIR:-/tmp}"
tmp_dir="$(mktemp -d "${tmp_root%/}/sakusaku_srt.XXXXXX")"
cleanup() {
    if [[ -n "${tmp_dir:-}" && -d "$tmp_dir" ]]; then
        rm -rf -- "$tmp_dir"
    fi
}
trap cleanup EXIT

failed=0
total="${#inputs[@]}"
index=0

for input in "${inputs[@]}"; do
    index=$((index + 1))
    input_name="${input##*/}"

    if [[ ! -f "$input" ]]; then
        error "入力ファイルが見つかりません: $input"
        failed=1
        continue
    fi

    if [[ "$input" == */* ]]; then
        input_dir="${input%/*}"
        if [[ -z "$input_dir" ]]; then
            input_dir="/"
        fi
    else
        input_dir="."
    fi

    stem="${input_name%.*}"
    if [[ -z "$stem" ]]; then
        stem="$input_name"
    fi

    if [[ -n "$custom_outdir" ]]; then
        output_dir="$custom_outdir"
    else
        output_dir="$input_dir"
    fi

    if ! mkdir -p -- "$output_dir"; then
        error "出力ディレクトリを作成できません: $output_dir"
        failed=1
        continue
    fi

    output_base="${output_dir%/}/${stem}"
    if [[ "$output_dir" == "/" ]]; then
        output_base="/${stem}"
    fi
    output_srt="${output_base}.srt"
    temp_wav="${tmp_dir}/audio_${index}.wav"
    temp_json_base="${tmp_dir}/transcription_${index}"
    temp_json="${temp_json_base}.json"
    start_time="$(date +%s)"

    printf '[%d/%d] %s → %s\n' "$index" "$total" "$input_name" "${output_srt##*/}"

    if ! "$FFMPEG_BIN" -nostdin -y -loglevel error -i "$input" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$temp_wav"; then
        error "音声の抽出に失敗しました: $input"
        failed=1
        continue
    fi

    duration=""
    if duration="$("$FFPROBE_BIN" -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$temp_wav" 2>/dev/null)"; then
        duration="${duration%%$'\n'*}"
    else
        duration=""
    fi

    backup_srt="${output_srt}.bak"
    backed_up=0
    if [[ -e "$output_srt" ]]; then
        if ! rotate_backup_if_needed "$backup_srt"; then
            error "既存バックアップを退避できません: $backup_srt"
            failed=1
            continue
        fi
        if ! mv -- "$output_srt" "$backup_srt"; then
            error "既存SRTをバックアップできません: $output_srt"
            failed=1
            continue
        fi
        backed_up=1
        printf '  既存SRTをバックアップ: %s → %s\n' "${output_srt##*/}" "${backup_srt##*/}"
    fi

    if [[ "$raw_srt" -eq 1 ]]; then
        whisper_format_args=(-osrt)
        whisper_output_base="$output_base"
    else
        whisper_format_args=(-oj -ojf)
        whisper_output_base="$temp_json_base"
    fi

    whisper_args=(
        -m "$model_path"
        -f "$temp_wav"
        -l "$lang"
        "${whisper_format_args[@]}"
        -of "$whisper_output_base"
        --carry-initial-prompt
        -sns
        -t "$threads"
        -ml "$max_len"
        -pp
    )

    if [[ -n "$prompt" ]]; then
        whisper_args+=(--prompt "$prompt")
    fi
    if [[ "$vad_enabled" -eq 1 ]]; then
        whisper_args+=(--vad -vm "$VAD_MODEL")
    fi

    if ! "$WHISPER_BIN" "${whisper_args[@]}"; then
        error "文字起こしに失敗しました: $input"
        recover_srt_after_failure "$output_srt" "$backup_srt" "$backed_up"
        failed=1
        continue
    fi

    if [[ "$raw_srt" -eq 0 ]]; then
        if [[ ! -f "$temp_json" ]]; then
            error "whisper-cli は正常終了しましたが、JSONが作成されませんでした: $temp_json"
            recover_srt_after_failure "$output_srt" "$backup_srt" "$backed_up"
            failed=1
            continue
        fi

        if ! "$python_bin" "$JSON_CONVERTER" "$temp_json" "$output_srt" --max-chars "$max_chars"; then
            error "JSONからSRTへの変換に失敗しました: $input"
            recover_srt_after_failure "$output_srt" "$backup_srt" "$backed_up"
            failed=1
            continue
        fi
    fi

    if [[ ! -f "$output_srt" ]]; then
        error "処理は正常終了しましたが、SRTが作成されませんでした: $output_srt"
        recover_srt_after_failure "$output_srt" "$backup_srt" "$backed_up"
        failed=1
        continue
    fi

    end_time="$(date +%s)"
    elapsed=$((end_time - start_time))

    if [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        duration_display="$(awk -v value="$duration" 'BEGIN { printf "%.1f", value }')"
        if [[ "$elapsed" -gt 0 ]]; then
            realtime="$(awk -v audio="$duration" -v seconds="$elapsed" 'BEGIN { printf "%.1f", audio / seconds }')"
            printf '  完了: %s（経過 %d秒 / 音声 %s秒 / %sx realtime）\n' "$output_srt" "$elapsed" "$duration_display" "$realtime"
        else
            printf '  完了: %s（経過 1秒未満 / 音声 %s秒 / realtime係数は計測不能）\n' "$output_srt" "$duration_display"
        fi
    else
        printf '  完了: %s（経過 %d秒 / 音声時間とrealtime係数は取得不能）\n' "$output_srt" "$elapsed"
    fi
done

exit "$failed"
