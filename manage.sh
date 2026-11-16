#!/bin/sh
set -eu
umask 077
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE=${GATEWAY_SOURCE:-/lge/app_ro/http-gateway}
COPY=/lge/app_rw/http-gateway-public-v5
STATE=/data/lge/http-gateway-public-v5-state
DROPIN=zz-public-internet-v4.conf
UNITS='http-gateway.service http-gateway-b2b.service'
KEYS='4:1800 4:1810 6:1790 6:1800 6:1810'
fail(){ echo "ERROR: $*" >&2; exit 1; }
hash(){ sha256sum "$1" | { read -r digest rest; printf '%s\n' "$digest"; }; }
rule_show(){ family=${1%:*}; priority=${1#*:}; ip -"$family" rule show | awk -v key="$priority:" '$1 == key'; }
preflight(){
    for command in sha256sum dd cp cat stat cmp chmod touch chown sed sort grep; do command -v "$command" >/dev/null 2>&1 || fail "missing $command"; done
    command -v socat >/dev/null 2>&1 || fail "factory socat is required"
    [ -r /etc/ssl/certs/ca-certificates.crt ] || fail "CA bundle missing"
    [ "$(id -u)" = 0 ] || fail 'root required'
    [ ! -e "$STATE" ] || fail 'state already exists; inspect status or rollback'
    [ ! -e "$COPY" ] || fail 'candidate directory already exists; preserve it for inspection'
    [ "$(id -u sint_sec_http-gateway)" = 943 ] && [ "$(id -u sint_sec_http-gateway-b2b)" = 942 ] || fail 'unexpected proxy UIDs'
    [ "$(hash "$SOURCE/http-gateway")" = 2ca01fa50943dc9188221a54e916d05ebed1e0cc0745a5537006bfa921cd2de2 ] || fail 'B2C factory baseline differs'
    [ "$(hash "$SOURCE/http-gateway-b2b")" = 893b3c8c885bf874fd3c7eadac2420b7a95ab9797916c9e8b27c242ff23f257a ] || fail 'B2B factory baseline differs'
    (cd "$BASE" && sha256sum -c SHA256SUMS) || fail 'package hash mismatch'
    ip -4 route show table 20 | grep -q '^default ' || fail 'hotspot IPv4 uplink absent'
    ip -6 route show table 20 | grep -q '^default ' || fail 'hotspot IPv6 uplink absent'
    for unit in $UNITS; do
        name=${unit%.service}
        [ "$(systemctl show -p LoadState "$unit")" = LoadState=loaded ] || fail "missing $unit"
        current_exec=$(systemctl show -p ExecStart "$unit")
        if printf '%s\n' "$current_exec" | grep -F "path=/lge/app_ro/http-gateway/$name ;" >/dev/null; then :
        else printf '%s\n' "$current_exec" | grep -F "path=/lge/app_rw/http-gateway/$name ;" >/dev/null || fail 'unexpected current execution path'; fi
        [ ! -e "/run/systemd/system/$unit.d/$DROPIN" ] || fail 'drop-in already exists'
    done
    for key in $KEYS; do [ -z "$(rule_show "$key")" ] || fail "routing priority occupied: $key"; done
    echo PREFLIGHT_OK
}
add_rule(){
    key=$1
    : > "$STATE/planned-$key"
    case "$key" in
      4:1800)ip -4 rule add pref 1800 uidrange 942-943 lookup main suppress_prefixlength 0;;
      4:1810)ip -4 rule add pref 1810 uidrange 942-943 lookup 20;;
      6:1790)ip -6 rule add pref 1790 to fd53:7cb8:383::/48 uidrange 942-943 lookup main;;
      6:1800)ip -6 rule add pref 1800 uidrange 942-943 lookup main suppress_prefixlength 0;;
      6:1810)ip -6 rule add pref 1810 uidrange 942-943 lookup 20;;
      *)return 1;;
    esac
    rule_show "$key" > "$STATE/rule-$key"
    [ -s "$STATE/rule-$key" ]
}
del_rule(){
    case "$1" in
      4:1800)ip -4 rule del pref 1800 uidrange 942-943 lookup main suppress_prefixlength 0;;
      4:1810)ip -4 rule del pref 1810 uidrange 942-943 lookup 20;;
      6:1790)ip -6 rule del pref 1790 to fd53:7cb8:383::/48 uidrange 942-943 lookup main;;
      6:1800)ip -6 rule del pref 1800 uidrange 942-943 lookup main suppress_prefixlength 0;;
      6:1810)ip -6 rule del pref 1810 uidrange 942-943 lookup 20;;
      *)return 1;;
    esac
}
rollback(){
    [ -f "$STATE/owned" ] || { echo NO_OWNED_STATE; return; }
    [ ! -f "$STATE/rolled-back" ] || { echo ALREADY_ROLLED_BACK; return; }
    errors=0
    if [ -f "$STATE/stopping" ]; then for unit in $UNITS; do systemctl stop "$unit" || errors=1; done; fi
    for unit in $UNITS; do
        path=/run/systemd/system/$unit.d/$DROPIN
        if [ -f "$STATE/dropin-$unit" ] && [ -e "$path" ]; then
            if cmp -s "$path" "$STATE/dropin-$unit" || { [ -f "$STATE/final-$unit" ] && cmp -s "$path" "$STATE/final-$unit"; }; then rm "$path" || errors=1; else echo "DROPIN_CHANGED: $path" >&2; errors=1; fi
        fi
    done
    for key in $KEYS; do
        if [ -f "$STATE/planned-$key" ]; then
            current=$(rule_show "$key")
            if [ -n "$current" ]; then
                if [ ! -s "$STATE/rule-$key" ] || [ "$current" = "$(cat "$STATE/rule-$key")" ]; then
                    del_rule "$key" || errors=1
                else echo "RULE_CHANGED: $key" >&2; errors=1; fi
            fi
        fi
    done
    systemctl daemon-reload || errors=1
    if [ "$errors" = 0 ] && [ -f "$STATE/stopping" ]; then
        for unit in $UNITS; do
            if [ -f "$STATE/was-active-$unit" ]; then systemctl start "$unit" || errors=1; systemctl is-active --quiet "$unit" || errors=1; fi
        done
    fi
    [ "$errors" = 0 ] || fail 'rollback incomplete; changed external state retained'
    date -u > "$STATE/rolled-back"
    echo ROLLBACK_OK_ORIGINAL_UNIT_PATH_RESTORED
}
apply(){
    preflight
    mkdir "$STATE"
    : > "$STATE/owned"
    cleanup(){ rc=$?; trap - EXIT HUP INT TERM; if [ "$rc" != 0 ]; then rollback || true; fi; exit "$rc"; }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    mkdir "$COPY"
    chmod 755 "$COPY"
    # Reconstruct exact v5 executables from local factory files, never shipped ELFs.
    for name in http-gateway http-gateway-b2b; do
        cp -p "$SOURCE/$name" "$COPY/$name"
        sh "$BASE/patch_binary.sh" apply "$COPY/$name" "$STATE/file-backups"
        chmod 755 "$COPY/$name"
    done
    cp "$BASE/libgateway_tls.so" "$COPY/libgateway_tls.so"
    chmod 644 "$COPY/libgateway_tls.so"
    printf 'nameserver 221.6.4.66\noptions timeout:2 attempts:2\n' > "$COPY/resolv.conf"
    chmod 644 "$COPY/resolv.conf"
    for unit in $UNITS; do if systemctl is-active --quiet "$unit"; then : > "$STATE/was-active-$unit"; fi; done
    : > "$STATE/stopping"
    for unit in $UNITS; do systemctl stop "$unit"; done
    for key in $KEYS; do add_rule "$key"; done
    for unit in $UNITS; do
        name=${unit%.service}; suffix=; [ "$name" != http-gateway-b2b ] || suffix=' -b'
        printf '[Service]\nExecStart=\nExecStart=%s/%s%s\nBindReadOnlyPaths=%s/resolv.conf:/etc/resolv-conf.connman\nEnvironment=LD_PRELOAD=%s/libgateway_tls.so\n' "$COPY" "$name" "$suffix" "$COPY" "$COPY" > "$STATE/dropin-$unit"
        mkdir -p "/run/systemd/system/$unit.d"
        cp "$STATE/dropin-$unit" "/run/systemd/system/$unit.d/$DROPIN"
    done
    systemctl daemon-reload
    for unit in $UNITS; do
        if [ -f "$STATE/was-active-$unit" ]; then systemctl start "$unit"; systemctl is-active --quiet "$unit" || fail "failed to start $unit"; fi
    done
    date -u > "$STATE/applied"
    trap - EXIT HUP INT TERM
    echo PUBLIC_EGRESS_V5_APPLIED_NO_V2_BACKUP_CREATED
}
finalize(){
    [ -f "$STATE/applied" ] && [ ! -f "$STATE/rolled-back" ] || fail 'active owned deployment required'
    for unit in $UNITS; do
        path=/run/systemd/system/$unit.d/$DROPIN
        cmp -s "$path" "$STATE/dropin-$unit" || fail "drop-in changed: $unit"
        sed 's/ allowedClients=fd53:7cb8:383:3::99,::1,127.0.0.1//' "$STATE/dropin-$unit" > "$STATE/final-$unit"
    done
    cleanup_final(){ rc=$?; trap - EXIT HUP INT TERM; if [ "$rc" != 0 ]; then rollback || true; fi; exit "$rc"; }
    trap cleanup_final EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    for unit in $UNITS; do systemctl stop "$unit"; done
    for unit in $UNITS; do
        cp "$STATE/final-$unit" "/run/systemd/system/$unit.d/$DROPIN"
        cp "$STATE/final-$unit" "$STATE/dropin-$unit"
    done
    systemctl daemon-reload
    for unit in $UNITS; do
        if [ -f "$STATE/was-active-$unit" ]; then systemctl start "$unit"; systemctl is-active --quiet "$unit"; fi
    done
    date -u > "$STATE/finalized"
    trap - EXIT HUP INT TERM
    echo FINALIZED_FACTORY_ALLOWED_CLIENTS
}
case "${1:-status}" in
  preflight)preflight;;
  apply)apply;;
  rollback)rollback;;
  finalize)finalize;;
  status)for unit in $UNITS; do systemctl show -p MainPID -p ExecStart -p ActiveState -p SubState -p NRestarts "$unit"; done; for key in $KEYS; do rule_show "$key"; done;;
  *)fail 'expected preflight/apply/finalize/rollback/status';;
esac
