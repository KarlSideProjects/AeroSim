#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 URL OUTPUT SHA512" >&2
    exit 2
fi

url="$1"
output="$2"
expected_sha512="$3"
chunk_size="${AEROSIM_DOWNLOAD_CHUNK_SIZE:-67108864}"
parallelism="${AEROSIM_DOWNLOAD_PARALLELISM:-8}"

if ! [[ "$chunk_size" =~ ^[1-9][0-9]*$ && "$parallelism" =~ ^[1-9][0-9]*$ ]]; then
    echo "chunk size and parallelism must be positive integers" >&2
    exit 2
fi

asset_size="$(
    curl -fsSLI "$url" |
        awk 'tolower($1) == "content-length:" {gsub("\r", "", $2); size = $2} END {if (size == "") exit 1; print size}'
)"
if ! [[ "$asset_size" =~ ^[1-9][0-9]*$ ]]; then
    echo "release asset has no usable content length: $url" >&2
    exit 1
fi

mkdir -p "$(dirname "$output")"
parts_dir="$(mktemp -d "${output}.parts.XXXXXX")"
cleanup() {
    rm -rf "$parts_dir"
}
trap cleanup EXIT

part_count=$(( (asset_size + chunk_size - 1) / chunk_size ))
pids=()
for ((part = 0; part < part_count; part++)); do
    start=$((part * chunk_size))
    end=$((start + chunk_size - 1))
    if ((end >= asset_size)); then
        end=$((asset_size - 1))
    fi
    part_path="$parts_dir/part-$part"
    while (( ${#pids[@]} >= parallelism )); do
        wait "${pids[0]}"
        pids=("${pids[@]:1}")
    done
    curl -fsSL --retry 4 --retry-delay 2 --range "$start-$end" -o "$part_path" "$url" &
    pids+=("$!")
done
for pid in "${pids[@]}"; do
    wait "$pid"
done

rm -f "$output"
for ((part = 0; part < part_count; part++)); do
    start=$((part * chunk_size))
    end=$((start + chunk_size - 1))
    if ((end >= asset_size)); then
        end=$((asset_size - 1))
    fi
    expected_size=$((end - start + 1))
    part_path="$parts_dir/part-$part"
    actual_size="$(stat -c '%s' "$part_path")"
    if [[ "$actual_size" != "$expected_size" ]]; then
        echo "range $part has size $actual_size, expected $expected_size" >&2
        exit 1
    fi
    dd if="$part_path" of="$output" bs=1M status=none oflag=append conv=notrunc
done

actual_size="$(stat -c '%s' "$output")"
if [[ "$actual_size" != "$asset_size" ]]; then
    echo "assembled asset has size $actual_size, expected $asset_size" >&2
    exit 1
fi
echo "$expected_sha512  $output" | sha512sum -c -
