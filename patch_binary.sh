#!/bin/sh
# Apply factory-to-v5 deltas to a local copy, preserving the target inode.
set -eu
umask 077
LC_ALL=C
export LC_ALL
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ACTION=${1:-help}
[ "$ACTION" != version ] || { echo 'http-gateway-patch public-egress-v5-delta-only';exit 0; }
[ "$#" -ge 2 ] || { echo 'Usage: sh patch_binary.sh check|apply|rollback|repair TARGET [BACKUP_ROOT]' >&2;exit 1; }
TARGET=$(CDPATH= cd -- "$(dirname -- "$2")" && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$2")")
BACKUP_ROOT=${3:-/data/lge/http-gateway-public-v5-file-backups}
fail(){ echo "ERROR: $*" >&2;exit 1; }
for cmd in sha256sum dd cp cat stat cmp chmod touch;do command -v "$cmd" >/dev/null 2>&1 || fail "missing $cmd";done
[ -f "$TARGET" ] && [ ! -L "$TARGET" ] || fail 'regular non-symlink target required'
hash(){ sha256sum "$1" | { read -r value rest;printf '%s\n' "$value"; }; }
. "$BASE/metadata.sh"
identify(){
    CURRENT_SHA=$(hash "$TARGET")
    while read -r kind variant input output input_size output_size payload;do
        case "$kind" in ''|'#'*)continue;;esac
        if [ "$CURRENT_SHA" = "$output" ];then
            KIND=$kind;VARIANT=$variant;INPUT_SHA=$input;OUTPUT_SHA=$output;INPUT_SIZE=$input_size;OUTPUT_SIZE=$output_size;PAYLOAD=$BASE/$payload;STATE=PATCHED;return 0
        fi
        if [ "$CURRENT_SHA" = "$input" ];then
            KIND=$kind;VARIANT=$variant;INPUT_SHA=$input;OUTPUT_SHA=$output;INPUT_SIZE=$input_size;OUTPUT_SIZE=$output_size;PAYLOAD=$BASE/$payload
            STATE=ORIGINAL
            return 0
        fi
    done < "$BASE/targets.tsv"
    return 1
}
load_backup(){
    for name in http-gateway http-gateway-b2b;do
        candidate=$BACKUP_ROOT/$name
        if [ -f "$candidate/target" ] && [ "$(cat "$candidate/target")" = "$TARGET" ];then
            KIND=$name;BACKUP=$candidate;INPUT_SHA=$(cat "$BACKUP/input.sha");OUTPUT_SHA=$(cat "$BACKUP/output.sha");return 0
        fi
    done
    return 1
}
recover(){
    [ "$(hash "$BACKUP/original")" = "$INPUT_SHA" ] || { echo 'ERROR: original backup hash mismatch' >&2;return 1; }
    current=$(hash "$TARGET")
    if [ "$current" != "$INPUT_SHA" ] && [ "$current" != "$OUTPUT_SHA" ];then
        [ "${AUTO_RECOVER:-0}" = 1 ] || { echo 'ERROR: target changed externally; preserved' >&2;return 1; }
        size=$(stat -c '%s' "$TARGET");expected_size=$(stat -c '%s' "$BACKUP/candidate")
        [ "$size" -le "$expected_size" ] || { echo 'ERROR: unexpected target size; preserved' >&2;return 1; }
        dd if="$BACKUP/candidate" of="$BACKUP/recovery-prefix" bs=1 count="$size" 2>/dev/null || return 1
        cmp -s "$TARGET" "$BACKUP/recovery-prefix" || { echo 'ERROR: target is not an owned partial write; preserved' >&2;return 1; }
    fi
    if [ "$current" != "$INPUT_SHA" ];then cat "$BACKUP/original" > "$TARGET" || return 1;fi
    [ "$(hash "$TARGET")" = "$INPUT_SHA" ] || return 1
    restore_metadata || return 1
    printf '%s\n' ROLLED_BACK > "$BACKUP/status"
    echo "BINARY_ROLLBACK_OK: $KIND; exact pre-upgrade version and metadata restored"
}

case "$ACTION" in
  check)
    identify || fail 'unsupported ELF hash/version'
    echo "$STATE $KIND $CURRENT_SHA";;
  apply)
    identify || fail 'unsupported ELF hash/version'
    [ "$STATE" != PATCHED ] || { echo "ALREADY_PATCHED: $KIND";exit 0; }
    [ -w "$TARGET" ] || fail 'target file/filesystem is read-only'
    mkdir -p "$BACKUP_ROOT"
    BACKUP_ROOT=$(CDPATH= cd -- "$BACKUP_ROOT" && pwd -P)
    BACKUP=$BACKUP_ROOT/$KIND
    if [ -e "$BACKUP" ];then
        [ -f "$BACKUP/target" ] && [ "$(cat "$BACKUP/target")" = "$TARGET" ] || fail 'backup belongs to another target'
        [ "$(cat "$BACKUP/input.sha")" = "$INPUT_SHA" ] || fail 'backup input version differs'
        [ "$(hash "$BACKUP/original")" = "$INPUT_SHA" ] || fail 'existing backup corrupt'
        if [ -f "$BACKUP/xattrs.dump" ];then restore_metadata || fail 'existing metadata not restored';fi
    else
        mkdir "$BACKUP"
        printf '%s\n' "$TARGET" > "$BACKUP/target"
        printf '%s\n' "$INPUT_SHA" > "$BACKUP/input.sha"
        printf '%s\n' "$OUTPUT_SHA" > "$BACKUP/output.sha"
        cp -a "$TARGET" "$BACKUP/original"
        [ "$(hash "$BACKUP/original")" = "$INPUT_SHA" ] || fail 'backup verification failed'
    fi
    if [ ! -f "$BACKUP/xattrs.dump" ] && command -v getfattr >/dev/null 2>&1 && command -v setfattr >/dev/null 2>&1;then
        getfattr --absolute-names -d -m - "$TARGET" > "$BACKUP/xattrs.dump" || fail 'xattr capture failed'
    fi
    cp "$BACKUP/original" "$BACKUP/candidate"
    chmod u+w "$BACKUP/candidate"
    while read -r offset size filename;do
        case "$offset" in ''|'#'*)continue;;esac
        case "$offset:$size" in *[!0-9:]*)fail 'invalid delta range';;esac
        [ "$(stat -c '%s' "$PAYLOAD/$filename")" = "$size" ] || fail 'payload chunk size differs'
        dd if="$PAYLOAD/$filename" of="$BACKUP/candidate" bs=1 seek="$offset" conv=notrunc 2>/dev/null || fail 'candidate delta write failed'
    done < "$PAYLOAD/ranges.tsv"
    [ "$(hash "$BACKUP/candidate")" = "$OUTPUT_SHA" ] || fail 'candidate hash mismatch'
    [ "$(stat -c '%s' "$BACKUP/candidate")" = "$OUTPUT_SIZE" ] || fail 'candidate length mismatch'
    [ "$(hash "$TARGET")" = "$INPUT_SHA" ] || fail 'target changed while preparing'
    inode=$(stat -c '%d:%i' "$TARGET")
    : > "$BACKUP/armed"
    printf '%s\n' ARMED > "$BACKUP/status"
    cleanup(){ rc=$?;trap - EXIT HUP INT TERM;if [ "$rc" != 0 ];then AUTO_RECOVER=1;recover || echo "BINARY_ROLLBACK_INCOMPLETE: record=$BACKUP" >&2;fi;exit "$rc"; }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    cat "$BACKUP/candidate" > "$TARGET" || fail 'in-place commit failed'
    [ "$(hash "$TARGET")" = "$OUTPUT_SHA" ] || fail 'committed hash mismatch'
    [ "$(stat -c '%d:%i' "$TARGET")" = "$inode" ] || fail 'target inode changed'
    restore_metadata || fail 'metadata verification failed'
    printf '%s\n' APPLIED > "$BACKUP/status"
    trap - EXIT HUP INT TERM
    echo "BINARY_PATCH_OK: $KIND; exact v5 delta applied to local ELF; same inode; baseline=$VARIANT";;
  rollback|repair)
    if ! load_backup;then
        identify || fail 'no matching patch record and unknown file version'
        echo "NO_OWNED_PATCH: $KIND; supported version left unchanged";exit 0
    fi
    if [ ! -f "$BACKUP/armed" ];then
        [ "$(hash "$TARGET")" = "$INPUT_SHA" ] || fail 'unarmed backup conflicts with target'
        echo "BASELINE_UNCHANGED: $KIND; no commit was attempted";exit 0
    fi
    if [ "$ACTION" = repair ];then
        current=$(hash "$TARGET");[ "$current" = "$INPUT_SHA" ] || [ "$current" = "$OUTPUT_SHA" ] || fail 'repair requires supported full-file hash'
        restore_metadata || fail 'metadata repair failed'
        echo "METADATA_REPAIR_OK: $KIND";exit 0
    fi
    recover;;
  *)fail 'expected check, apply, repair or rollback';;
esac
