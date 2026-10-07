#!/bin/sh
# SPDX-License-Identifier: GPL-2.0

set -e

PAD_ROOTFS_OFFSET_TO=$((4 * 1024 * 1024))

# Constant
HDRLEN=256

die() {
    echo "$1" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
SYNTAX: $0 --kernel <file> --rootfs <file> --version <string> [options]

Options:
  --kernel   Path to kernel lzma file (required)
  --rootfs   Path to rootfs squashfs file
  --version  Version string, max 31 chars (required)
  --endian   Endianness: 'be' for big endian, 'le' for little endian (default: be)
  --model    Model/platform name, max 31 chars (default: empty)
EOF
    exit 1
}

# Defaults
kernel=""
rootfs=""
version=""
endian="be"
model=""

# Parse named arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --kernel)
            kernel="$2"
            shift 2
            ;;
        --rootfs)
            rootfs="$2"
            shift 2
            ;;
        --version)
            version="$2"
            shift 2
            ;;
        --endian)
            endian="$2"
            shift 2
            ;;
        --model)
            model="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# Validate required arguments
[ -n "$kernel" ] || die "Missing required argument: --kernel"
[ -n "$version" ] || die "Missing required argument: --version"

# Validate endianness
case "$endian" in
    be|BE) endian="be" ;;
    le|LE) endian="le" ;;
    *) die "Invalid endianness: $endian (must be 'be' or 'le')" ;;
esac

which zytrx >/dev/null || die "zytrx not found in PATH $PATH"
[ -f "$kernel" ] || die "Kernel file not found: $kernel"
[ -z "$rootfs" ] || [ -f "$rootfs" ] || die "Rootfs file not found: $rootfs"
[ "$(echo "$version" | wc -c)" -lt 32 ] || die "Version string too long: $version"
[ -z "$model" ] || [ "$(printf '%s' "$model" | wc -c)" -lt 32 ] || die "Model string too long: $model"

kernel_len=$(stat -c '%s' "$kernel")
header_plus_kernel_len=$(($HDRLEN + $kernel_len))
rootfs_len=0
if [ -f "$rootfs" ]; then
    rootfs_len=$(stat -c '%s' "$rootfs")
fi

[ "$PAD_ROOTFS_OFFSET_TO" -gt "$header_plus_kernel_len" ] || die "kernel is too large"

padding_len=$(($PAD_ROOTFS_OFFSET_TO - $header_plus_kernel_len))

echo "endian: $endian" >&2
echo "padding_len: $padding_len" >&2

padded_kernel_len=$(($padding_len + $kernel_len))

total_len=$(($PAD_ROOTFS_OFFSET_TO + $rootfs_len))

echo "total_len: $total_len" >&2

padding() {
    head -c $padding_len /dev/zero | tr '\0' '\377'
}

to_hex() {
    hexdump -v -e '1/1 "%02x"'
}

from_hex() {
    perl -pe 's/\s+//g; s/(..)/chr(hex($1))/ge'
}

# Output a 32-bit value in hex with correct endianness
# Usage: hex32 <value>
hex32() {
    val=$(printf '%08x' "$1")
    if [ "$endian" = "le" ]; then
        # Swap bytes for little endian: AABBCCDD -> DDCCBBAA
        echo "$val" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/'
    else
        echo "$val"
    fi
}

trx_crc32() {
    tmpfile=$(mktemp)
    outtmpfile=$(mktemp)
    cat "$kernel" > "$tmpfile"
    padding >> "$tmpfile"
    if [ -f "$rootfs" ]; then
        cat "$rootfs" >> "$tmpfile"
    fi
    zytrx \
        -B NR7101 \
        -v x \
        -i "$tmpfile" \
        -o "$outtmpfile" >/dev/null
    crc_hex=$(dd if="$outtmpfile" bs=4 count=1 skip=3 2>/dev/null | to_hex)
    rm "$tmpfile" "$outtmpfile" >/dev/null
    hex32 "0x$crc_hex"
}

tclinux_trx_hdr() {
    if [ "$endian" = "le" ]; then
        printf 'HDR2' | to_hex
    else
        printf '2RDH' | to_hex
    fi

    # Length of the header
    hex32 "$HDRLEN"

    # Length of header + content
    hex32 "$total_len"

    # crc32 of the content
    trx_crc32

    # version
    echo "$version" | to_hex
    head -c "$((32 - $(echo "$version" | wc -c)))" /dev/zero | to_hex

    # customer version
    head -c 32 /dev/zero | to_hex

    # kernel length
    hex32 "$padded_kernel_len"

    # rootfs length
    hex32 "$rootfs_len"

    # romfile length (0)
    hex32 0

    # model (32 bytes, zero-padded)
    if [ -n "$model" ]; then
        printf '%s' "$model" | to_hex
        head -c "$((32 - $(printf '%s' "$model" | wc -c)))" /dev/zero | to_hex
    else
        head -c 32 /dev/zero | to_hex
    fi

    hex32 0x80020000

    # "reserved" 128 bytes of zeros
    head -c 128 /dev/zero | to_hex
}

tclinux_trx_hdr | from_hex
cat "$kernel"
padding
if [ -f "$rootfs" ]; then
    cat "$rootfs"
fi
