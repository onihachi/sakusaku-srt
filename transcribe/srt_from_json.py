#!/usr/bin/env python3
"""Convert whisper.cpp token-timestamp JSON into sentence-level SRT."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable


SPECIAL_TOKEN = re.compile(r"^\[.*\]$")
SENTENCE_ENDINGS = ("。", "！", "？", "!", "?")
SECONDARY_ENDINGS = ("、", "，")


class ConversionError(Exception):
    """Raised when input data cannot be converted safely."""


def positive_integer(value: str) -> int:
    try:
        number = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if number < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return number


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="whisper.cppのJSONをトークン時刻で文分割し、SRTへ変換します。"
    )
    parser.add_argument("input_json", type=Path, metavar="INPUT.json")
    parser.add_argument("output_srt", type=Path, metavar="OUTPUT.srt")
    parser.add_argument(
        "--max-chars",
        type=positive_integer,
        default=80,
        metavar="N",
        help="句点がない長文を読点で分割し始める文字数（既定: 80）",
    )
    return parser.parse_args()


def load_transcription(path: Path) -> list[dict[str, Any]]:
    try:
        with path.open("r", encoding="utf-8") as stream:
            data = json.load(stream)
    except FileNotFoundError as exc:
        raise ConversionError(f"JSONファイルが見つかりません: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ConversionError(
            f"JSONの形式が不正です: {path}（{exc.lineno}行{exc.colno}列）"
        ) from exc
    except (OSError, UnicodeError) as exc:
        raise ConversionError(f"JSONを読み込めません: {path}: {exc}") from exc

    if not isinstance(data, dict):
        raise ConversionError("JSONのトップレベルはオブジェクトである必要があります。")

    transcription = data.get("transcription")
    if not isinstance(transcription, list):
        raise ConversionError("JSONに transcription のリストがありません。")

    for segment_number, segment in enumerate(transcription, start=1):
        if not isinstance(segment, dict):
            raise ConversionError(
                f"transcription[{segment_number - 1}] がオブジェクトではありません。"
            )
        if not isinstance(segment.get("tokens"), list):
            raise ConversionError(
                f"transcription[{segment_number - 1}] に tokens のリストがありません。"
            )

    return transcription


def content_tokens(
    transcription: Iterable[dict[str, Any]],
) -> Iterable[tuple[str, int, int]]:
    for segment_number, segment in enumerate(transcription, start=1):
        tokens = segment["tokens"]
        for token_number, token in enumerate(tokens, start=1):
            location = (
                f"transcription[{segment_number - 1}]"
                f".tokens[{token_number - 1}]"
            )
            if not isinstance(token, dict):
                raise ConversionError(f"{location} がオブジェクトではありません。")

            text = token.get("text")
            if not isinstance(text, str):
                raise ConversionError(f"{location}.text が文字列ではありません。")
            if SPECIAL_TOKEN.fullmatch(text):
                continue

            offsets = token.get("offsets")
            if not isinstance(offsets, dict):
                continue
            start = offsets.get("from")
            end = offsets.get("to")
            if start is None or end is None:
                continue
            if (
                not isinstance(start, int)
                or isinstance(start, bool)
                or not isinstance(end, int)
                or isinstance(end, bool)
            ):
                raise ConversionError(
                    f"{location}.offsets の from/to は整数ミリ秒である必要があります。"
                )

            yield text, start, end


def make_blocks(
    transcription: Iterable[dict[str, Any]], max_chars: int
) -> list[tuple[int, int, str]]:
    blocks: list[tuple[int, int, str]] = []
    text_parts: list[str] = []
    block_start: int | None = None
    block_end: int | None = None
    char_count = 0
    previous_end = 0

    def close_block() -> None:
        nonlocal text_parts, block_start, block_end, char_count, previous_end

        text = "".join(text_parts).strip()
        if text and block_start is not None and block_end is not None:
            start = block_start
            end = block_end
            if end <= start:
                end = start + 500
            if start < previous_end:
                start = previous_end
            if start >= end:
                end = start + 500
            blocks.append((start, end, text))
            previous_end = end

        text_parts = []
        block_start = None
        block_end = None
        char_count = 0

    for text, start, end in content_tokens(transcription):
        if block_start is None:
            block_start = start
        block_end = end
        text_parts.append(text)
        char_count += len(text)

        accumulated_text = "".join(text_parts)
        if accumulated_text.endswith(SENTENCE_ENDINGS):
            close_block()
        elif char_count >= max_chars and text.endswith(SECONDARY_ENDINGS):
            close_block()

    close_block()
    return blocks


def format_timestamp(milliseconds: int) -> str:
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    seconds, millis = divmod(remainder, 1_000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{millis:03d}"


def write_srt(path: Path, blocks: Iterable[tuple[int, int, str]]) -> int:
    entries = []
    for number, (start, end, text) in enumerate(blocks, start=1):
        entries.append(
            f"{number}\r\n"
            f"{format_timestamp(start)} --> {format_timestamp(end)}\r\n"
            f"{text}\r\n\r\n"
        )

    try:
        with path.open("w", encoding="utf-8", newline="") as stream:
            stream.write("".join(entries))
    except (OSError, UnicodeError) as exc:
        raise ConversionError(f"SRTを書き込めません: {path}: {exc}") from exc

    return len(entries)


def main() -> int:
    args = parse_args()
    try:
        transcription = load_transcription(args.input_json)
        blocks = make_blocks(transcription, args.max_chars)
        if not blocks:
            raise ConversionError("有効な時刻付きトークンがなく、SRTを作成できませんでした。")
        count = write_srt(args.output_srt, blocks)
    except ConversionError as exc:
        print(f"エラー: {exc}", file=sys.stderr)
        return 1

    print(f"{count} blocks written: {args.output_srt}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
