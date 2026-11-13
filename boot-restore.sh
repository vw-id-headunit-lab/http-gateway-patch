#!/bin/sh
# Restore the verified v5 profile from writable storage after each boot.
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
BASE=/lge/app_rw/http-gateway-public-v5
STATE=/data/lge/http-gateway-public-v5-state
RUNTIME=/run/systemd/system
PROC=/proc
UNIT=http-gateway-public-v5-restore.service
DROPIN=zz-public-internet-v4.conf
UNITS='http-gateway.service http-gateway-b2b.service'
B2C_ALLOWED_CLIENTS='fd53:7cb8:383:3::99,192.168.0.99,::ffff:192.168.0.99'
KEYS='4:1800 4:1810 6:1790 6:1800 6:1810'
fail(){ echo "RESTORE_ERROR: $*" >&2; exit 1; }
hash(){ sha256sum "$1" | { read -r value rest; printf '%s\n' "$value"; }; }
normalize(){ awk '{$1=$1; print}'; }
rule_now(){ family=${1%:*}; priority=${1#*:}; ip -"$family" rule show | awk -v p="$priority:" '$1==p {$1=""; print}' | normalize; }
expected(){
    case "$1" in
      4:1800|6:1800)echo 'from all uidrange 942-943 lookup main suppress_prefixlength 0';;
      4:1810|6:1810)echo 'from all uidrange 942-943 lookup 20';;
      6:1790)echo 'from all to fd53:7cb8:383::/48 uidrange 942-943 lookup main';;
      *)fail 'invalid rule key';;
    esac
}
add_rule(){
    case "$1" in
      4:1800)ip -4 rule add pref 1800 uidrange 942-943 lookup main suppress_prefixlength 0;;
      4:1810)ip -4 rule add pref 1810 uidrange 942-943 lookup 20;;
      6:1790)ip -6 rule add pref 1790 to fd53:7cb8:383::/48 uidrange 942-943 lookup main;;
      6:1800)ip -6 rule add pref 1800 uidrange 942-943 lookup main suppress_prefixlength 0;;
      6:1810)ip -6 rule add pref 1810 uidrange 942-943 lookup 20;;
    esac
}
check_resources(){
    [ "$(id -u)" = 0 ] || fail 'root required'
    [ "$(id -u sint_sec_http-gateway)" = 943 ] && [ "$(id -u sint_sec_http-gateway-b2b)" = 942 ] || fail 'unexpected proxy UIDs'
    for command in ip systemctl systemd-run sha256sum awk cmp readlink nsenter socat; do command -v "$command" >/dev/null 2>&1 || fail "missing $command"; done
    [ "$(hash "$BASE/http-gateway")" = 4223357e411e8c2d064ab7023929b1bec546269c579a7a844fc06dc0991a7b5c ] || fail 'B2C payload differs'
    [ "$(hash "$BASE/http-gateway-b2b")" = e6107cfb385449f94506b37d05d7364bc6a99fce5755ad2335e9b5f81e057143 ] || fail 'B2B payload differs'
    [ "$(hash "$BASE/libgateway_tls.so")" = 1356c2e31f2f306cc4f74611b6ac4221894c37e883d0850ad3a12ec4d2907f3a ] || fail 'TLS payload differs'
    [ -r /etc/ssl/certs/ca-certificates.crt ] || fail 'CA bundle missing'
    [ -f "$STATE/owned" ] || fail 'v5 ownership record missing'
    [ -s "$BASE/resolv.conf" ] || fail 'private DNS file missing'
    for unit in $UNITS; do
        [ "$(systemctl show -p LoadState "$unit")" = LoadState=loaded ] || fail "unit not loaded: $unit"
        source=$STATE/dropin-$unit
        [ -f "$source" ] || fail "saved v5 drop-in missing: $unit"
        case "$unit" in
          http-gateway.service)wanted=2b3ed006cd9e67af66ddbd0440636af52d0d5e2dfc166dd707ba078ad7be1471;;
          http-gateway-b2b.service)wanted=72e81e6ef0d46b24bdf646d484796538abb2c1d761c3995fe7e5970d710fe902;;
        esac
        [ "$(hash "$source")" = "$wanted" ] || fail "saved drop-in differs: $unit"
        if [ "$unit" = http-gateway.service ]; then
            grep -F " allowedClients=$B2C_ALLOWED_CLIENTS" "$source" >/dev/null || fail 'B2C client policy differs'
        fi
        path=$RUNTIME/$unit.d/$DROPIN
        if [ -e "$path" ] || [ -L "$path" ]; then
            [ -f "$path" ] && [ ! -L "$path" ] && cmp -s "$source" "$path" || fail "runtime drop-in changed externally: $unit"
        fi
    done
    [ "$(hash "$BASE/resolv.conf")" = 4d0e8978a113566af3034868e434b3f555694b57bf5065abcf1aa83238456472 ] || fail 'private DNS differs'
    for key in $KEYS; do
        current=$(rule_now "$key")
        [ -z "$current" ] || [ "$current" = "$(expected "$key")" ] || fail "routing priority occupied by different rules: $key"
    done
}
running_ok(){
    unit=$1
    systemctl is-active --quiet "$unit" || return 1
    pid=$(systemctl show -p MainPID --value "$unit")
    case "$pid" in ''|*[!0-9]*|0)return 1;;esac
    [ "$(readlink "$PROC/$pid/exe")" = "$BASE/${unit%.service}" ] || return 1
    if [ "$unit" = http-gateway.service ]; then
        tr '\000' '\n' < "$PROC/$pid/cmdline" | grep -Fx "allowedClients=$B2C_ALLOWED_CLIENTS" >/dev/null || return 1
    fi
    grep -F "$BASE/libgateway_tls.so" "$PROC/$pid/maps" >/dev/null || return 1
    [ "$(nsenter -t "$pid" -m -- cat /etc/resolv.conf)" = "$(cat "$BASE/resolv.conf")" ] || return 1
}
logging(){
    log=$BASE/boot-restore.log
    if [ -f "$log" ] && [ "$(wc -c < "$log")" -ge 262144 ]; then mv -f "$log" "$log.1"; fi
    exec >> "$log" 2>&1
    printf '\n[%s] action=%s boot=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$(cat "$PROC/sys/kernel/random/boot_id")"
}
enabled(){ [ -f "$BASE/persist.enabled" ] && [ ! -f "$STATE/rolled-back" ]; }
# PMTU errors are RELATED to the existing upstream TCP connection.
# Match only fragmentation-needed feedback from the active table20 next hop.
restore_pmtu_feedback(){
    command -v iptables >/dev/null 2>&1 || fail 'missing iptables'
    iptables -w 5 -S ICMP_IN_FILTER >/dev/null || fail 'ICMP filter chain missing'
    pmtu_peer=$(ip -4 route show table 20 | awk '
        $1=="default" {
            peer=""; device=""
            for (i=1;i<NF;i++) {
                if ($i=="via") peer=$(i+1)
                if ($i=="dev") device=$(i+1)
            }
            if (device=="l2tpeth0" && peer!="") print peer
        }')
    case "$pmtu_peer" in ''|*[!0-9.]*)fail 'expected one IPv4 l2tpeth0 gateway in table20';;esac
    if ! iptables -w 5 -C ICMP_IN_FILTER -s "$pmtu_peer/32" -i l2tpeth0 -p icmp \
        --icmp-type 3/4 -m conntrack --ctstate RELATED -j ACCEPT 2>/dev/null; then
        iptables -w 5 -I ICMP_IN_FILTER 1 -s "$pmtu_peer/32" -i l2tpeth0 -p icmp \
            --icmp-type 3/4 -m conntrack --ctstate RELATED -j ACCEPT
    fi
    iptables -w 5 -C ICMP_IN_FILTER -s "$pmtu_peer/32" -i l2tpeth0 -p icmp \
        --icmp-type 3/4 -m conntrack --ctstate RELATED -j ACCEPT || fail 'PMTU rule readback failed'
    echo "PMTU_OK: l2tpeth0 source=$pmtu_peer type=3/code=4 ctstate=RELATED"
}
restore(){
    enabled || { echo 'PERSIST_DISABLED'; return; }
    check_resources
    for key in $KEYS; do
        if [ -z "$(rule_now "$key")" ]; then add_rule "$key"; fi
        [ "$(rule_now "$key")" = "$(expected "$key")" ] || fail "rule readback differs: $key"
    done
    files_changed=0
    for unit in $UNITS; do
        path=$RUNTIME/$unit.d/$DROPIN
        if [ ! -e "$path" ]; then
            mkdir -p "$RUNTIME/$unit.d"
            cp "$STATE/dropin-$unit" "$path.restore.$$"
            chmod 600 "$path.restore.$$"
            mv "$path.restore.$$" "$path"
            files_changed=1
        fi
    done
    [ "$files_changed" = 0 ] || systemctl daemon-reload
    for unit in $UNITS; do
        if ! running_ok "$unit"; then systemctl restart "$unit"; fi
        running_ok "$unit" || fail "service verification failed: $unit"
    done
    restore_pmtu_feedback
    cat "$PROC/sys/kernel/random/boot_id" > "$STATE/last-restored-boot-id"
    date -u > "$STATE/last-restored-at"
    echo 'RESTORE_OK: v5 binaries, TLS library, private DNS, five scoped routing rules and PMTU feedback verified'
}
launch(){
    enabled || { echo 'PERSIST_DISABLED'; return; }
    if [ "$(systemctl show -p LoadState "$UNIT")" = LoadState=loaded ]; then
        systemctl show -p ExecStart "$UNIT" | grep -F "$BASE/boot-restore.sh" >/dev/null || fail 'restore unit name belongs to another command'
        case "$(systemctl show -p ActiveState --value "$UNIT")" in active|activating|reloading)echo RESTORE_ALREADY_SCHEDULED; return;;esac
        systemctl reset-failed "$UNIT" || true
        systemctl start --no-block "$UNIT"
    else
        systemd-run --no-block --unit="$UNIT" \
            --property=Type=simple --property=RemainAfterExit=yes \
            --property=User=root --property=Restart=on-failure --property=RestartSec=10s \
            --property=TimeoutStartSec=120s --property=After=firewall-manager.service \
            --property=RequiresMountsFor="$BASE" \
            /bin/sh "$BASE/boot-restore.sh" restore
    fi
}
case "${1:-launch}" in
  check)check_resources; echo PERSISTENCE_PREFLIGHT_OK;;
  restore)logging restore; restore;;
  pmtu)logging pmtu; enabled || fail 'persistence disabled'; check_resources; restore_pmtu_feedback;;
  launch)logging launch; launch;;
  status)
    if enabled; then echo PERSIST_ENABLED; else echo PERSIST_DISABLED; fi
    systemctl show -p LoadState -p ActiveState -p Result "$UNIT"
    for key in $KEYS; do printf '%s: %s\n' "$key" "$(rule_now "$key")"; done;;
  *)fail 'expected check, launch, restore, pmtu or status';;
esac
