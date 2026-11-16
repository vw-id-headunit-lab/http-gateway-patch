#!/bin/sh
# Shared xattr-v2 metadata preservation; functions use TARGET and BACKUP.
normalize_xattrs(){
    sed '/^#/d;/^[[:space:]]*$/d' "$1" | LC_ALL=C sort
}
restore_xattrs(){
    [ -f "$BACKUP/xattrs.dump" ] || return 0
    command -v getfattr >/dev/null 2>&1 && command -v setfattr >/dev/null 2>&1 || { echo 'ERROR: saved xattrs require getfattr and setfattr for verification' >&2;return 1; }
    for cmd in sed sort grep;do command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: xattr comparison requires $cmd" >&2;return 1; };done
    getfattr --absolute-names -d -m - "$TARGET" > "$BACKUP/xattrs.current" || return 1
    normalize_xattrs "$BACKUP/xattrs.dump" > "$BACKUP/xattrs.expected.sorted"
    normalize_xattrs "$BACKUP/xattrs.current" > "$BACKUP/xattrs.current.sorted"
    if cmp -s "$BACKUP/xattrs.expected.sorted" "$BACKUP/xattrs.current.sorted";then
        echo 'XATTRS_VERIFIED: unchanged; no protected attribute write needed'
        return 0
    fi
    header=$(sed -n '/^# file: /{p;q;}' "$BACKUP/xattrs.dump")
    [ -n "$header" ] || { echo 'ERROR: saved xattr file header absent' >&2;return 1; }
    while IFS= read -r attribute_line;do
        [ -n "$attribute_line" ] || continue
        if grep -F -x -- "$attribute_line" "$BACKUP/xattrs.current.sorted" >/dev/null 2>&1;then continue;fi
        attribute_name=${attribute_line%%=*}
        [ "$attribute_name" != "$attribute_line" ] || { echo 'ERROR: malformed saved xattr entry' >&2;return 1; }
        printf '%s\n%s\n' "$header" "$attribute_line" > "$BACKUP/xattrs.restore-one"
        if ! setfattr --restore="$BACKUP/xattrs.restore-one";then
            echo "ERROR: changed xattr restoration failed: $attribute_name" >&2
            return 1
        fi
    done < "$BACKUP/xattrs.expected.sorted"
    while IFS= read -r attribute_line;do
        [ -n "$attribute_line" ] || continue
        attribute_name=${attribute_line%%=*}
        if ! grep -F -- "$attribute_name=" "$BACKUP/xattrs.expected.sorted" >/dev/null 2>&1;then
            if ! setfattr -x "$attribute_name" "$TARGET";then
                echo "ERROR: extra xattr removal failed: $attribute_name" >&2
                return 1
            fi
        fi
    done < "$BACKUP/xattrs.current.sorted"
    getfattr --absolute-names -d -m - "$TARGET" > "$BACKUP/xattrs.current" || return 1
    normalize_xattrs "$BACKUP/xattrs.current" > "$BACKUP/xattrs.current.sorted"
    cmp -s "$BACKUP/xattrs.expected.sorted" "$BACKUP/xattrs.current.sorted" || { echo 'ERROR: xattrs still differ after restoration' >&2;return 1; }
    echo 'XATTRS_VERIFIED: changed attributes restored and read back'
}
restore_metadata(){
    mode=$(stat -c '%a' "$BACKUP/original")
    owner=$(stat -c '%u:%g' "$BACKUP/original")
    current_owner=$(stat -c '%u:%g' "$TARGET")
    if [ "$owner" != "$current_owner" ];then chown "$owner" "$TARGET" || return 1;fi
    if [ "$(stat -c '%a' "$TARGET")" != "$mode" ];then chmod "$mode" "$TARGET" || return 1;fi
    if [ "$(stat -c '%Y' "$TARGET")" != "$(stat -c '%Y' "$BACKUP/original")" ];then touch -r "$BACKUP/original" "$TARGET" || return 1;fi
    restore_xattrs || return 1
    [ "$(stat -c '%a:%u:%g' "$TARGET")" = "$(stat -c '%a:%u:%g' "$BACKUP/original")" ] || return 1
    : > "$BACKUP/metadata-verified"
}
