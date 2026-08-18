#!/usr/bin/env bash
# Host-global readers/writer admission for product UI work and Loom's full suite.
# Sourced by tick.sh and tick-test.sh; no filesystem work at source.

HOST_ADMISSION_CLAIM=""
HOST_ADMISSION_PRODUCT_LOCK_HOME=""

host_admission_home() {
    printf '%s\n' "${LOOM_HOST_ADMISSION_HOME:-$HOME/.loom/host-admission}"
}

_host_admission_pid_valid() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -gt 0 ] 2>/dev/null
}

_host_admission_error() {
    echo "host-admission: $*" >&2
    return 2
}

_host_admission_lock_take() { # <global-home> -> 0 ours, 1 busy, 2 unreadable
    local home="$1" lock="$1/aux-admission.lock" tmp="$1/.admission-lock.$$" owner
    if [ -e "$home" ] || [ -L "$home" ]; then
        [ -d "$home" ] && [ ! -L "$home" ] && [ -r "$home" ] && [ -x "$home" ] && [ -w "$home" ] \
          || { _host_admission_error "unreadable state root: $home"; return 2; }
    else
        mkdir -p "$home" 2>/dev/null \
          || { _host_admission_error "cannot create state root: $home"; return 2; }
    fi
    printf '%s\n' "$$" > "$tmp" 2>/dev/null \
      || { _host_admission_error "cannot stage admission lock: $home"; return 2; }
    if ln "$tmp" "$lock" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    [ -e "$lock" ] || [ -L "$lock" ] || { _host_admission_lock_take "$home"; return $?; }
    [ -f "$lock" ] && [ ! -L "$lock" ] && [ -r "$lock" ] \
      || { _host_admission_error "unreadable admission lock: $lock"; return 2; }
    if ! owner=$(cat "$lock" 2>/dev/null); then
        [ -e "$lock" ] || [ -L "$lock" ] || { _host_admission_lock_take "$home"; return $?; }
        _host_admission_error "cannot read admission lock: $lock"; return 2
    fi
    if ! _host_admission_pid_valid "$owner"; then
        [ -e "$lock" ] || [ -L "$lock" ] || { _host_admission_lock_take "$home"; return $?; }
        _host_admission_error "admission lock has no trustworthy owner: $lock"; return 2
    fi
    kill -0 "$owner" 2>/dev/null && return 1
    rm -f "$lock" 2>/dev/null \
      || { _host_admission_error "cannot retire stale admission lock: $lock"; return 2; }
    _host_admission_lock_take "$home"
}

_host_admission_lock_release() { # <global-home>
    local lock="$1/aux-admission.lock" owner
    [ -f "$lock" ] && [ ! -L "$lock" ] && [ -r "$lock" ] \
      || { _host_admission_error "admission lock has an unreadable owner: $lock"; return 2; }
    owner=$(cat "$lock" 2>/dev/null || true)
    [ "$owner" = "$$" ] \
      || { _host_admission_error "admission lock ownership changed: $lock"; return 2; }
    rm -f "$lock" 2>/dev/null \
      || { _host_admission_error "cannot release admission lock: $lock"; return 2; }
}

_host_admission_register_product() { # <global-home> <safe-key> <absolute-product-home>
    local home="$1" key="$2" product="$3" homes="$1/product-homes" record tmp existing
    case "$key" in ''|*[!A-Za-z0-9_-]*) _host_admission_error "invalid product key '$key'"; return 2 ;; esac
    case "$product" in /*) [ "$product" != / ] || { _host_admission_error "unsafe product home: $product"; return 2; } ;;
        *) _host_admission_error "product home is not absolute: $product"; return 2 ;;
    esac
    if [ -e "$homes" ] || [ -L "$homes" ]; then
        [ -d "$homes" ] && [ ! -L "$homes" ] && [ -r "$homes" ] && [ -x "$homes" ] && [ -w "$homes" ] \
          || { _host_admission_error "unreadable product registry: $homes"; return 2; }
    else
        mkdir "$homes" 2>/dev/null \
          || { _host_admission_error "cannot create product registry: $homes"; return 2; }
    fi
    record="$homes/$key"
    if [ -e "$record" ] || [ -L "$record" ]; then
        [ -f "$record" ] && [ ! -L "$record" ] && [ -r "$record" ] \
          || { _host_admission_error "unreadable product registration: $record"; return 2; }
        existing=$(cat "$record" 2>/dev/null || true)
        [ "$existing" = "$product" ] \
          || { _host_admission_error "product key collision at $record"; return 2; }
        return 0
    fi
    tmp="$homes/.product.$$"
    printf '%s\n' "$product" > "$tmp" 2>/dev/null && mv "$tmp" "$record" 2>/dev/null \
      || { rm -f "$tmp" 2>/dev/null || true; _host_admission_error "cannot register product home: $record"; return 2; }
}

_host_admission_maintenance_available() { # <global-home> -> 0 free, 1 live, 2 unreadable
    local claim="$1/heavy-host-maintenance.d" pidfile owner
    [ ! -e "$claim" ] && [ ! -L "$claim" ] && return 0
    [ -d "$claim" ] && [ ! -L "$claim" ] && [ -r "$claim" ] && [ -x "$claim" ] \
      || { _host_admission_error "unreadable maintenance claim: $claim"; return 2; }
    pidfile="$claim/pid"
    [ -f "$pidfile" ] && [ ! -L "$pidfile" ] && [ -r "$pidfile" ] \
      || { _host_admission_error "maintenance claim has an unreadable owner: $claim"; return 2; }
    owner=$(cat "$pidfile" 2>/dev/null || true)
    _host_admission_pid_valid "$owner" \
      || { _host_admission_error "maintenance claim has no trustworthy owner: $claim"; return 2; }
    kill -0 "$owner" 2>/dev/null && return 1
    rm -f "$claim/pid" 2>/dev/null && rmdir "$claim" 2>/dev/null \
      || { _host_admission_error "cannot retire stale maintenance claim: $claim"; return 2; }
    return 0
}

_host_admission_product_active() { # <product-home> -> 0 active/reserved, 1 idle, 2 unreadable
    local home="$1" lanes="$1/lanes" queue="$1/lane-launch-queue"
    local marker value id pidfile pid request field
    if [ -e "$home" ] || [ -L "$home" ]; then
        [ -d "$home" ] && [ ! -L "$home" ] && [ -r "$home" ] && [ -x "$home" ] \
          || { _host_admission_error "unreadable product home: $home"; return 2; }
    else
        return 1
    fi
    if [ -e "$lanes" ] || [ -L "$lanes" ]; then
        [ -d "$lanes" ] && [ ! -L "$lanes" ] && [ -r "$lanes" ] && [ -x "$lanes" ] \
          || { _host_admission_error "unreadable product lane state: $lanes"; return 2; }
        for marker in "$lanes"/*.ui-resource; do
            [ ! -e "$marker" ] && [ ! -L "$marker" ] && continue
            [ -f "$marker" ] && [ ! -L "$marker" ] && [ -r "$marker" ] \
              || { _host_admission_error "unreadable product claim: $marker"; return 2; }
            value=$(cat "$marker" 2>/dev/null) || {
                [ ! -e "$marker" ] && [ ! -L "$marker" ] && continue
                _host_admission_error "cannot read product claim: $marker"; return 2
            }
            [ "$value" = ui ] \
              || { _host_admission_error "invalid product claim: $marker"; return 2; }
            id="${marker##*/}"; id="${id%.ui-resource}"
            pidfile="$lanes/$id.pid"
            [ -f "$pidfile" ] && [ ! -L "$pidfile" ] && [ -r "$pidfile" ] || {
                [ ! -e "$marker" ] && [ ! -L "$marker" ] && continue
                _host_admission_error "product claim has unreadable owner: $marker"; return 2
            }
            pid=$(cat "$pidfile" 2>/dev/null || true)
            _host_admission_pid_valid "$pid" \
              || { _host_admission_error "product claim has no trustworthy owner: $marker"; return 2; }
            kill -0 "$pid" 2>/dev/null && return 0
            rm -f "$marker" 2>/dev/null \
              || { _host_admission_error "cannot retire stale product claim: $marker"; return 2; }
        done
    fi
    [ -f "$home/loop.stopped" ] && return 1
    [ ! -e "$queue" ] && [ ! -L "$queue" ] && return 1
    [ -d "$queue" ] && [ ! -L "$queue" ] && [ -r "$queue" ] && [ -x "$queue" ] \
      || { _host_admission_error "unreadable product launch queue: $queue"; return 2; }
    for request in "$queue"/request-* "$queue"/launching-*; do
        [ ! -e "$request" ] && [ ! -L "$request" ] && continue
        [ -d "$request" ] && [ ! -L "$request" ] && [ -r "$request" ] && [ -x "$request" ] \
          || { _host_admission_error "unreadable product reservation: $request"; return 2; }
        for field in pregate reserve-ui host-probe; do
            [ ! -e "$request/$field" ] && [ ! -L "$request/$field" ] && continue
            [ -f "$request/$field" ] && [ ! -L "$request/$field" ] && [ -r "$request/$field" ] \
              || { _host_admission_error "unreadable product reservation: $request/$field"; return 2; }
        done
        [ "$(cat "$request/pregate" 2>/dev/null || true)" = ui ] && return 0
        [ "$(cat "$request/reserve-ui" 2>/dev/null || true)" = 1 ] && return 0
        [ -s "$request/host-probe" ] && return 0
    done
    return 1
}

_host_admission_any_product_active() { # <global-home>
    local homes="$1/product-homes" record product lines state_rc
    [ ! -e "$homes" ] && [ ! -L "$homes" ] && return 1
    [ -d "$homes" ] && [ ! -L "$homes" ] && [ -r "$homes" ] && [ -x "$homes" ] \
      || { _host_admission_error "unreadable product registry: $homes"; return 2; }
    for record in "$homes"/*; do
        [ ! -e "$record" ] && [ ! -L "$record" ] && continue
        [ -f "$record" ] && [ ! -L "$record" ] && [ -r "$record" ] \
          || { _host_admission_error "unreadable product registration: $record"; return 2; }
        lines=$(wc -l < "$record" 2>/dev/null | tr -d ' ') || {
            _host_admission_error "cannot read product registration: $record"; return 2
        }
        [ "$lines" = 1 ] \
          || { _host_admission_error "invalid product registration: $record"; return 2; }
        product=$(cat "$record" 2>/dev/null || true)
        case "$product" in /*) [ "$product" != / ] || { _host_admission_error "unsafe product registration: $record"; return 2; } ;;
            *) _host_admission_error "invalid product registration: $record"; return 2 ;;
        esac
        state_rc=0; _host_admission_product_active "$product" || state_rc=$?
        case "$state_rc" in 0) return 0 ;; 2) return 2 ;; esac
    done
    return 1
}

host_admission_product_acquire() { # <global-home> <key> <absolute-product-home>
    local home="$1" key="$2" product="$3" lock_rc state_rc
    while :; do
        lock_rc=0; _host_admission_lock_take "$home" || lock_rc=$?
        case "$lock_rc" in 0) break ;; 1) sleep 0.05 ;; 2) return 2 ;; esac
    done
    _host_admission_register_product "$home" "$key" "$product" \
      || { _host_admission_lock_release "$home" >/dev/null 2>&1 || true; return 2; }
    state_rc=0; _host_admission_maintenance_available "$home" || state_rc=$?
    case "$state_rc" in
        0) HOST_ADMISSION_PRODUCT_LOCK_HOME="$home"; return 0 ;;
        1) _host_admission_lock_release "$home" || return 2; return 1 ;;
        2) _host_admission_lock_release "$home" >/dev/null 2>&1 || true; return 2 ;;
    esac
}

host_admission_product_unlock() {
    local home="${HOST_ADMISSION_PRODUCT_LOCK_HOME:-}"
    [ -n "$home" ] || return 0
    HOST_ADMISSION_PRODUCT_LOCK_HOME=""
    _host_admission_lock_release "$home"
}

host_admission_maintenance_acquire() { # <global-home> [key product-home]
    local home="$1" key="${2:-}" product="${3:-}"
    local claim="$1/heavy-host-maintenance.d" lock_rc state_rc deferred=0
    [ -n "$home" ] || { _host_admission_error "host admission home is required"; return 2; }
    while :; do
        lock_rc=0; _host_admission_lock_take "$home" || lock_rc=$?
        case "$lock_rc" in 1) sleep 0.05; continue ;; 2) return 2 ;; esac
        if [ -n "$key" ] || [ -n "$product" ]; then
            [ -n "$key" ] && [ -n "$product" ] \
              || { _host_admission_lock_release "$home" >/dev/null 2>&1 || true; _host_admission_error "product registration needs key and home"; return 2; }
            _host_admission_register_product "$home" "$key" "$product" \
              || { _host_admission_lock_release "$home" >/dev/null 2>&1 || true; return 2; }
        fi
        state_rc=0; _host_admission_maintenance_available "$home" || state_rc=$?
        case "$state_rc" in
            1) _host_admission_lock_release "$home" || return 2; sleep 0.05; continue ;;
            2) _host_admission_lock_release "$home" >/dev/null 2>&1 || true; return 2 ;;
        esac
        state_rc=0; _host_admission_any_product_active "$home" || state_rc=$?
        case "$state_rc" in
            0)
                _host_admission_lock_release "$home" || return 2
                if [ "$deferred" -eq 0 ]; then
                    echo "loom-tests: product UI work owns the heavyweight host; deferring full suite until it releases"
                    deferred=1
                fi
                sleep 0.05
                continue
                ;;
            2) _host_admission_lock_release "$home" >/dev/null 2>&1 || true; return 2 ;;
        esac
        mkdir "$claim" 2>/dev/null \
          || { _host_admission_lock_release "$home" >/dev/null 2>&1 || true; _host_admission_error "cannot create maintenance claim: $claim"; return 2; }
        printf '%s\n' "$$" > "$claim/pid" 2>/dev/null \
          || { rmdir "$claim" 2>/dev/null || true; _host_admission_lock_release "$home" >/dev/null 2>&1 || true; _host_admission_error "cannot stamp maintenance claim: $claim"; return 2; }
        HOST_ADMISSION_CLAIM="$claim"
        _host_admission_lock_release "$home" || return 2
        [ "$deferred" -eq 0 ] \
          || echo "loom-tests: product UI work released; starting full suite"
        return 0
    done
}

host_admission_maintenance_release() {
    local claim="${HOST_ADMISSION_CLAIM:-}" home pidfile owner lock_rc
    [ -n "$claim" ] || return 0
    home="${claim%/heavy-host-maintenance.d}"
    while :; do
        lock_rc=0; _host_admission_lock_take "$home" || lock_rc=$?
        case "$lock_rc" in 0) break ;; 1) sleep 0.05 ;; 2) return 2 ;; esac
    done
    pidfile="$claim/pid"
    [ -f "$pidfile" ] && [ ! -L "$pidfile" ] && [ -r "$pidfile" ] \
      || { _host_admission_lock_release "$home" >/dev/null 2>&1 || true; _host_admission_error "maintenance claim has an unreadable owner: $claim"; return 2; }
    owner=$(cat "$pidfile" 2>/dev/null || true)
    [ "$owner" = "$$" ] \
      || { _host_admission_lock_release "$home" >/dev/null 2>&1 || true; _host_admission_error "maintenance claim ownership changed: $claim"; return 2; }
    rm -f "$claim/pid" 2>/dev/null && rmdir "$claim" 2>/dev/null \
      || { _host_admission_lock_release "$home" >/dev/null 2>&1 || true; _host_admission_error "cannot release maintenance claim: $claim"; return 2; }
    HOST_ADMISSION_CLAIM=""
    _host_admission_lock_release "$home"
}
