#!/usr/bin/env bash
# chauffeur uninstaller (Rust implementation only). Mirrors uninstall.ps1 on
# Windows: one canonical script per shell, no private `_uninstall-rust.sh`
# helper.
#
# Behaviour by host + flag:
#   all hosts + no flag             → Rust uninstall
#   --backend=rust/swift            → no-op (Rust is the only supported backend)
#   --experimental-rust             → legacy alias (no-op)
#
# Swift uninstall removes:
#   - ~/.local/bin/chauffeur symlink (+ legacy /usr/local/bin/chauffeur)
#   - /Applications/Chauffeur.app bundle
#   - ~/.chauffeur/ (telemetry id + install marker)
#   - ~/Library/Application Support/Chauffeur/ (config.json)
#   - ~/Library/Caches/chauffeur/ (daemon/cache state)
#   - Skill symlinks under ~/.claude/skills/chauffeur, ~/.agents/skills/
#     chauffeur, ~/.openclaw/skills/chauffeur, ~/.config/opencode/
#     skills/chauffeur (only when they point at our app bundle)
#   - Claude MCP registrations in ~/.claude.json (chauffeur / chauffeur-computer-use)
#
# Rust uninstall removes:
#   Linux:
#     - ~/.local/bin/chauffeur symlink (only when it resolves to a
#       chauffeur path — a Swift-driver symlink is left in place)
#     - versioned packages/current symlink under ~/.chauffeur/
#     - telemetry id, preference, and registration markers are preserved by
#       default so a reinstall remains the same pseudonymous installation
#     - ~/.config/systemd/user/chauffeur.service (if --autostart
#       was used via install-local.sh — stop + disable + remove), plus the
#       legacy chauffeur-rs.service unit
#     - Skill symlinks under ~/.claude/skills/chauffeur(-rs), ~/.agents/
#       skills/…, ~/.openclaw/skills/…, ~/.config/opencode/skills/…
#   macOS:
#     - /Applications/Chauffeur.app bundle (+ legacy ChauffeurRs.app)
#     - ~/.local/bin/chauffeur symlink (only when it resolves into
#       /Applications/Chauffeur.app)
#     - runtime payloads under ~/.chauffeur/ and legacy ~/.chauffeur-rs/;
#       telemetry state remains unless --purge is passed
#     - ~/Library/LaunchAgents/com.memjar.chauffeur.plist (if --autostart
#       was used via install-local.sh — unload + remove), plus the legacy
#       com.memjar.chauffeur-rs.plist LaunchAgent
#     - Skill symlinks under ~/.claude/skills/chauffeur(-rs), etc.
#
# Shared-path safety: /Applications/Chauffeur.app + its ~/.local/bin
# symlink use the same bundle id (com.axe.chauffeur) as the Swift driver,
# so they're only removed when an unambiguous Rust marker is on disk
# (~/.chauffeur/packages/, legacy ~/.chauffeur-rs/, ChauffeurRs.app,
# the LaunchAgent/systemd unit, or current Rust telemetry state).
#
# Also scrubs Claude MCP registrations in ~/.claude.json that match
# the active backend.
#
# Revokes TCC grants on macOS by default (Accessibility + Screen Recording)
# so the next install prompts cleanly under the new signing identity. Pass
# --keep-tcc to preserve grants across uninstall/reinstall.
#
# Usage:
#   /bin/bash -c "$(curl -fsSL https://chauffeur.ai/driver/uninstall.sh)"
#   /bin/bash -c "$(curl -fsSL https://chauffeur.ai/driver/uninstall.sh)" -- --purge
#
# Env overrides (mirror install side):
#   CHAUFFEUR_HOME       Rust package home to remove (default ~/.chauffeur)
#   CHAUFFEUR_RS_HOME    Legacy alias for CHAUFFEUR_HOME
set -euo pipefail

# ----------------------------------------------------------------------
# Flag parsing — same two-pass shape as install.sh so the argv shapes
# stay bit-compatible across install/uninstall and a future Rust-only
# flag flows through without edits.
# ----------------------------------------------------------------------
USE_RUST_BACKEND=1
RESET_TCC=1
PURGE_DATA=0
FORWARDED_ARGS=()
PASSTHROUGH=0
while [[ $# -gt 0 ]]; do
    if [[ "$PASSTHROUGH" == "1" ]]; then
        FORWARDED_ARGS+=("$1"); shift; continue
    fi
    case "$1" in
        --experimental-rust) shift ;;  # legacy alias for default Rust path
        --backend=rust)      shift ;;
        --backend=swift)     shift ;;  # retired Swift (no-op)
        --reset-tcc)         RESET_TCC=1; shift ;;  # legacy/explicit default: revoke TCC grants
        --keep-tcc)          RESET_TCC=0; shift ;;  # preserve TCC grants across reinstall
        --purge)             PURGE_DATA=1; shift ;;  # also delete pseudonymous identity + preference
        --backend=*)
            printf 'error: unknown backend %q; supported: rust\n' "${1#*=}" >&2
            exit 2
            ;;
        --)                  PASSTHROUGH=1; shift ;;  # forward the rest verbatim
        *)                   FORWARDED_ARGS+=("$1"); shift ;;
    esac
done

# Legacy --backend=swift is accepted as a no-op for backward compat.
OS="$(uname -s 2>/dev/null || echo unknown)"
if [[ "$USE_RUST_BACKEND" == "1" ]]; then
    if [[ "$OS" != "Darwin" ]]; then
        printf 'note: detected non-macOS host (%s); uninstalling chauffeur via the Rust implementation.\n' "$OS" >&2
    else
        printf 'note: uninstalling chauffeur via the Rust implementation.\n' >&2
    fi
fi

# ----------------------------------------------------------------------
# Shared helpers
# ----------------------------------------------------------------------
log() { printf '==> %s\n' "$*"; }

purge_macos_history() {
    local app_bundle="$1"
    local helper="$2"
    local rust_install_present="$3"
    local codesign_tool="$4"
    if [[ "$rust_install_present" != "1" || ! -x "$helper" ]] \
        || ! "$codesign_tool" --verify --deep --strict "$app_bundle" >/dev/null 2>&1; then
        printf 'history_purge_incomplete: installed signed Chauffeur helper unavailable; preserved history state for retry\n' >&2
        return 1
    fi
    if ! "$helper" history purge-offline --yes; then
        printf 'history_purge_incomplete: exact-namespace key destruction was not verified; preserved history state and app for retry\n' >&2
        return 1
    fi
}

purge_linux_history() {
    local helper="$1"
    local rust_install_present="$2"
    if [[ "$rust_install_present" != "1" || ! -x "$helper" ]]; then
        printf 'history_purge_incomplete: installed Chauffeur helper unavailable; preserved history state for retry\n' >&2
        return 1
    fi
    if ! "$helper" history purge-offline --yes; then
        printf 'history_purge_incomplete: exact-namespace Secret Service key destruction was not verified; preserved history state and runtime for retry\n' >&2
        return 1
    fi
}

daemon_pid_file_path() {
    case "$OS" in
        Darwin) printf '%s/Library/Caches/chauffeur/chauffeur.pid' "$HOME" ;;
        Linux)  printf '%s/.cache/chauffeur/chauffeur.pid' "$HOME" ;;
        *)      printf '/tmp/chauffeur.pid' ;;
    esac
}

read_daemon_pid() {
    local pid
    [[ -r "$1" ]] || return 1
    IFS= read -r pid < "$1" || true
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s' "$pid"
}

daemon_pid_alive() { kill -0 "$1" 2>/dev/null; }

daemon_process_generation() {
    local start=""
    command -v ps >/dev/null 2>&1 || return 2
    start="$(LC_ALL=C ps -ww -o lstart= -p "$1" 2>/dev/null)" || return 2
    start="${start#"${start%%[![:space:]]*}"}"
    start="${start%"${start##*[![:space:]]}"}"
    [[ -n "$start" ]] || return 2
    printf '%s' "$start"
}

daemon_pid_matches_generation() {
    local pid="$1" expected="$2" current="" identity_status=0
    daemon_pid_alive "$pid" || return 1
    current="$(daemon_process_generation "$pid")" || return 2
    [[ "$current" == "$expected" ]] || return 1
    daemon_pid_is_release "$pid" || identity_status=$?
    [[ "$identity_status" == "0" ]] && return 0
    [[ "$identity_status" == "2" ]] && return 2
    return 1
}

daemon_signal_if_current() {
    local status=0
    daemon_pid_matches_generation "$1" "$2" || status=$?
    [[ "$status" == "2" ]] && return 2
    [[ "$status" == "0" ]] || return 1
    kill -"$3" "$1" 2>/dev/null || return 1
}

daemon_wait_for_exit() {
    local pid="$1" attempts=0
    while daemon_pid_alive "$pid"; do
        [[ "$attempts" -lt 20 ]] || return 1
        sleep 0.1 2>/dev/null || sleep 1 || true
        attempts=$((attempts + 1))
    done
}

daemon_process_identity() {
    local pid="$1" identity=""
    if [[ -L "/proc/$pid/exe" ]]; then
        identity="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
        identity="${identity% (deleted)}"
    fi
    if [[ -z "$identity" ]]; then
        command -v ps >/dev/null 2>&1 || return 2
        identity="$(ps -ww -o command= -p "$pid" 2>/dev/null)" || return 2
    fi
    identity="${identity#"${identity%%[![:space:]]*}"}"
    identity="${identity%"${identity##*[![:space:]]}"}"
    [[ -n "$identity" ]] || return 1
    printf '%s' "$identity"
}

daemon_identity_matches_install() {
    case "$1" in
        "$APP_BUNDLE"/Contents/MacOS/chauffeur|"$APP_BUNDLE"/Contents/MacOS/chauffeur[[:space:]]*|\
        "$LEGACY_APP_BUNDLE"/Contents/MacOS/chauffeur|"$LEGACY_APP_BUNDLE"/Contents/MacOS/chauffeur[[:space:]]*|\
        "$USER_BIN_LINK"|"$USER_BIN_LINK"[[:space:]]*|\
        "$HOME_DIR"/packages/current/chauffeur|"$HOME_DIR"/packages/current/chauffeur[[:space:]]*|\
        "$HOME_DIR"/packages/releases/*/chauffeur|"$HOME_DIR"/packages/releases/*/chauffeur[[:space:]]*|\
        "$LEGACY_HOME_DIR"/packages/current/chauffeur|"$LEGACY_HOME_DIR"/packages/current/chauffeur[[:space:]]*|\
        "$LEGACY_HOME_DIR"/packages/releases/*/chauffeur|"$LEGACY_HOME_DIR"/packages/releases/*/chauffeur[[:space:]]*) return 0 ;;
        *) return 1 ;;
    esac
}

daemon_pid_is_release() {
    local identity
    identity="$(daemon_process_identity "$1" 2>/dev/null)" || return 2
    daemon_identity_matches_install "$identity"
}

release_daemon_fallback_pids() {
    command -v pgrep >/dev/null 2>&1 || return 2
    command -v ps >/dev/null 2>&1 || return 2
    local uid pid identity candidates="" pgrep_status=0
    uid="$(id -u 2>/dev/null || true)"
    [[ "$uid" =~ ^[0-9]+$ ]] || return 2

    candidates="$(pgrep -U "$uid" -f '(^|[[:space:]/])chauffeur([[:space:]]|$)' 2>/dev/null)" || pgrep_status=$?
    case "$pgrep_status" in
        0) ;;
        1) return 0 ;;
        *) return 2 ;;
    esac

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 2
        identity="$(daemon_process_identity "$pid" 2>/dev/null)" || return 2
        if daemon_identity_matches_install "$identity"; then
            printf '%s\n' "$pid"
        fi
    done <<< "$candidates"
}

verify_release_daemon_absent() {
    local pids="" status=0
    pids="$(release_daemon_fallback_pids 2>/dev/null)" || status=$?
    if [[ "$status" != "0" ]]; then
        printf 'daemon_stop_incomplete: process inspection failed while verifying release daemon shutdown.\n' >&2
        return 1
    fi
    if [[ -n "$pids" ]]; then
        printf 'daemon_stop_incomplete: release chauffeur process remains but cannot be safely classified or signalled.\n' >&2
        return 1
    fi
}

stop_release_daemon() {
    local pid="" helper="${DAEMON_STOP_HELPER:-}" generation="" status=0 helper_stderr=""
    if [[ -n "${DAEMON_PID_FILE:-}" ]] \
        && pid="$(read_daemon_pid "$DAEMON_PID_FILE" 2>/dev/null)" \
        && daemon_pid_alive "$pid"; then
        daemon_pid_is_release "$pid" || status=$?
        if [[ "$status" == "2" ]]; then
            printf 'daemon_stop_incomplete: failed to identify live daemon pid %s safely.\n' "$pid" >&2
            return 1
        fi
        if [[ "$status" == "0" ]]; then
            [[ -n "$helper" && -x "$helper" ]] || {
                printf 'daemon_stop_incomplete: trusted installed chauffeur stop helper is unavailable for pid %s.\n' "$pid" >&2
                return 1
            }
            generation="$(daemon_process_generation "$pid")" || {
                printf 'daemon_stop_incomplete: failed to capture process generation for daemon pid %s.\n' "$pid" >&2
                return 1
            }
            status=0
            helper_stderr="$("$helper" --expected-pid "$pid" stop 2>&1 >/dev/null)" || status=$?
            if [[ "$status" != "0" ]]; then
                printf 'note: trusted stop helper exited %s for pid %s; falling back to signals.\n' "$status" "$pid" >&2
                [[ -z "$helper_stderr" ]] || printf '%s\n' "$helper_stderr" >&2
            fi
            if ! daemon_wait_for_exit "$pid"; then
                status=0
                daemon_signal_if_current "$pid" "$generation" TERM || status=$?
                [[ "$status" != "2" ]] || {
                    printf 'daemon_stop_incomplete: failed to revalidate daemon pid %s before TERM.\n' "$pid" >&2
                    return 1
                }
                if [[ "$status" == "0" ]] && ! daemon_wait_for_exit "$pid"; then
                    status=0
                    daemon_signal_if_current "$pid" "$generation" KILL || status=$?
                    [[ "$status" != "2" ]] || {
                        printf 'daemon_stop_incomplete: failed to revalidate daemon pid %s before KILL.\n' "$pid" >&2
                        return 1
                    }
                    if [[ "$status" == "0" ]] && ! daemon_wait_for_exit "$pid"; then
                        printf 'daemon_stop_incomplete: validated release daemon pid %s is still running.\n' "$pid" >&2
                        return 1
                    fi
                fi
            fi
        fi
    fi
    sleep 0.2 2>/dev/null || true
    verify_release_daemon_absent
}

reject_root_invocation() {
    local effective_uid="$1"
    if [[ "$effective_uid" == "0" ]]; then
        printf 'error: do not run the Chauffeur uninstaller with sudo; run it as the login user so Computer History is purged from the correct home directory and native credential store. The script elevates only protected app removal when needed.\n' >&2
        return 77
    fi
}

# TCC revocation is on by default so uninstall leaves the next macOS install
# in a clean promptable state. The bundle id com.axe.chauffeur is shared with
# the retired Swift driver, so `--keep-tcc` remains available for users who
# intentionally want grants to survive uninstall/reinstall.
# When enabled, revoke Accessibility + Screen-Recording + Automation for
# com.axe.chauffeur. macOS-only; no-op elsewhere.
maybe_reset_tcc() {
    [[ "$RESET_TCC" == "1" ]] || return 0
    if [[ "$OS" != "Darwin" ]]; then
        log "TCC reset is macOS-only; nothing to revoke on $OS"
        return 0
    fi
    if ! command -v tccutil >/dev/null 2>&1; then
        log "TCC reset: tccutil not found; skipping"
        return 0
    fi
    # `tccutil reset <svc> com.axe.chauffeur` resolves the bundle id through
    # LaunchServices. If the bundle isn't registered — or this runs AFTER the
    # app was removed — tccutil fails with -10814 and the grant silently
    # survives. This MUST run while /Applications/Chauffeur.app still exists;
    # force a synchronous LaunchServices registration first so a present-but-
    # not-yet-registered bundle (fresh install race) still resolves.
    local app_bundle="/Applications/Chauffeur.app"
    if [[ -d "$app_bundle" ]]; then
        local lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        if [[ -x "$lsregister" ]]; then
            "$lsregister" -f "$app_bundle" >/dev/null 2>&1 || true
        fi
    else
        log "  warning: Chauffeur.app already removed; TCC reset may not resolve the bundle id"
    fi
    log "revoking TCC grants for com.axe.chauffeur"
    log "  note: com.axe.chauffeur is shared with the retired Swift driver;"
    log "  this clears grants for both. Pass --keep-tcc to preserve them."
    for SVC in Accessibility ScreenCapture AppleEvents; do
        if tccutil reset "$SVC" com.axe.chauffeur >/dev/null 2>&1; then
            log "  reset $SVC"
        else
            log "  $SVC: nothing to reset (or reset failed)"
        fi
    done
}

# Resolve a symlink target to an absolute path. realpath -e fails when
# the target is missing — we want to inspect dangling symlinks too (a
# leftover from a half-removed install should still be cleaned up), so
# fall back to readlink + manual normalize when realpath errors out.
resolve_link() {
    local link="$1"
    if [[ ! -L "$link" ]]; then
        printf ''; return 0
    fi
    local target
    if target="$(realpath "$link" 2>/dev/null)"; then
        printf '%s' "$target"
        return 0
    fi
    target="$(readlink "$link" 2>/dev/null || true)"
    case "$target" in
        /*) printf '%s' "$target" ;;
        *)  printf '%s/%s' "$(cd -- "$(dirname -- "$link")" && pwd)" "$target" ;;
    esac
}

select_daemon_stop_helper() {
    local candidate resolved
    for candidate in \
        "$APP_BUNDLE/Contents/MacOS/chauffeur" \
        "$LEGACY_APP_BUNDLE/Contents/MacOS/chauffeur" \
        "$PACKAGES_DIR/current/chauffeur" \
        "$LEGACY_HOME_DIR/packages/current/chauffeur"; do
        [[ -x "$candidate" ]] || continue
        resolved="$(realpath "$candidate" 2>/dev/null || true)"
        [[ -n "$resolved" ]] || resolved="$candidate"
        case "$resolved" in
            "$APP_BUNDLE/Contents/MacOS/chauffeur"|"$LEGACY_APP_BUNDLE/Contents/MacOS/chauffeur"|\
            "$HOME_DIR"/packages/releases/*/chauffeur|"$LEGACY_HOME_DIR"/packages/releases/*/chauffeur)
                printf '%s' "$resolved"
                return 0
                ;;
        esac
    done
    return 1
}

release_supervisor() {
    local action="$1" path name found=0
    case "$OS" in
        Linux)
            for path in "$SYSTEMD_USER_UNIT" "$LEGACY_SYSTEMD_USER_UNIT"; do
                [[ -f "$path" ]] || continue
                found=1
                name="${path##*/}"
                if [[ "$action" == "stop" ]]; then
                    command -v systemctl >/dev/null 2>&1 \
                        && systemctl --user stop "$name" >/dev/null 2>&1 || {
                            printf 'daemon_stop_incomplete: failed to stop systemd user unit %s.\n' "$name" >&2
                            return 1
                        }
                else
                    command -v systemctl >/dev/null 2>&1 \
                        && systemctl --user disable "$name" >/dev/null 2>&1 || true
                    rm -f "$path"
                    log "disabled + removed systemd --user unit $name"
                fi
            done
            if [[ "$action" == "remove" ]]; then
                [[ "$found" == "1" ]] || log "no current or legacy systemd --user unit found (skipping)"
                command -v systemctl >/dev/null 2>&1 \
                    && systemctl --user daemon-reload >/dev/null 2>&1 || true
            fi
            ;;
        Darwin)
            for path in "$LAUNCHAGENT_PLIST" "$LEGACY_LAUNCHAGENT_PLIST"; do
                [[ -f "$path" ]] || continue
                found=1
                if [[ "$action" == "stop" ]]; then
                    command -v launchctl >/dev/null 2>&1 \
                        && launchctl unload "$path" >/dev/null 2>&1 || {
                            printf 'daemon_stop_incomplete: failed to unload LaunchAgent %s.\n' "$path" >&2
                            return 1
                        }
                else
                    rm -f "$path"
                    log "removed LaunchAgent $path"
                fi
            done
            if [[ "$action" == "remove" && "$found" == "0" ]]; then
                log "no current or legacy LaunchAgent found (skipping)"
            fi
            ;;
    esac
}

if [[ "${CHAUFFEUR_UNINSTALL_TEST_SOURCE_ONLY:-0}" == "1" ]]; then
    return 0
fi

if ! reject_root_invocation "$(id -u)"; then
    exit 77
fi

# ----------------------------------------------------------------------
# Rust uninstall branch (default on Linux + macOS).
# ----------------------------------------------------------------------
if [[ "$USE_RUST_BACKEND" == "1" ]]; then
    USER_BIN_LINK="$HOME/.local/bin/chauffeur"
    # Canonical bundle path (post-rename — shares bundle id
    # `com.axe.chauffeur` with the Swift driver). The Rust install
    # replaces Swift here; both uninstallers target this path.
    APP_BUNDLE="/Applications/Chauffeur.app"
    # Legacy bundle path from earlier Rust releases that coexisted with
    # Swift under a separate name. Cleaned up if found.
    LEGACY_APP_BUNDLE="/Applications/ChauffeurRs.app"
    # Canonical package home is ~/.chauffeur (renamed from ~/.chauffeur-rs
    # in v0.2.16 / PR #1644). The old name is swept too — uninstall.sh
    # was missed in that rename and kept defaulting to the stale dir, so a
    # current install left nothing matching and the whole uninstall no-op'd.
    HOME_DIR="${CHAUFFEUR_HOME:-${CHAUFFEUR_RS_HOME:-$HOME/.chauffeur}}"
    LEGACY_HOME_DIR="$HOME/.chauffeur-rs"
    # The versioned package store (`packages/releases/*` + `current`) is
    # written only by the Rust install-local / self-updater path — it's the
    # one unambiguous on-disk Rust discriminator now that the .app bundle +
    # bundle id are shared with Swift.
    PACKAGES_DIR="$HOME_DIR/packages"
    LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/com.memjar.chauffeur.plist"
    LEGACY_LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/com.memjar.chauffeur-rs.plist"
    SYSTEMD_USER_UNIT="$HOME/.config/systemd/user/chauffeur.service"
    LEGACY_SYSTEMD_USER_UNIT="$HOME/.config/systemd/user/chauffeur-rs.service"
    SKILL_PACK_NAME="chauffeur"
    # Pre-rename skill pack name — swept alongside the current one so
    # users who installed under the legacy name end up clean after
    # `uninstall.sh --backend=rust`.
    LEGACY_SKILL_PACK_NAME="chauffeur-rs"

    # Rust-install marker. The Rust bundle path `/Applications/Chauffeur.app`
    # is shared with the Swift driver (same bundle id `com.axe.chauffeur`),
    # so we can't use that path alone as a discriminator — a Swift-only Mac
    # that runs `uninstall.sh --backend=rust` by mistake would lose its
    # Swift bundle, symlink, and Claude MCP registrations. This marker says
    # "there's at least one unambiguously-Rust artifact on disk." We gate
    # every shared-path removal below on it.
    #
    # Markers (any one suffices):
    #   - ~/.chauffeur/packages/ exists (Rust install-local / updater store)
    #   - ~/.chauffeur-rs/ exists (legacy Rust state dir, pre-rename)
    #   - /Applications/ChauffeurRs.app exists (legacy bundle, pre-rename)
    #   - current or legacy LaunchAgent plist / systemd unit exists
    #     (autostart was used)
    #   - current telemetry identity/registration marker exists (release
    #     installs on macOS live in /Applications and have no packages dir)
    RUST_INSTALL_PRESENT=0
    if [[ -d "$PACKAGES_DIR" || -d "$LEGACY_HOME_DIR" || -d "$LEGACY_APP_BUNDLE" || -f "$LAUNCHAGENT_PLIST" || -f "$LEGACY_LAUNCHAGENT_PLIST" || -f "$SYSTEMD_USER_UNIT" || -f "$LEGACY_SYSTEMD_USER_UNIT" || -f "$HOME_DIR/.telemetry_id" || -f "$HOME_DIR/.installation_recorded" ]]; then
        RUST_INSTALL_PRESENT=1
    fi

    DAEMON_PID_FILE="$(daemon_pid_file_path)"
    DAEMON_STOP_HELPER="$(select_daemon_stop_helper || true)"

    if [[ "$RUST_INSTALL_PRESENT" == "1" ]]; then
        if ! release_supervisor stop; then
            log "could not stop the release supervisor; runtime preserved"
            exit 1
        fi
        if ! stop_release_daemon; then
            log "could not safely stop and verify the release daemon; runtime preserved"
            exit 1
        fi
        log "verified no running release chauffeur daemon"
    else
        log "no Rust install marker; leaving any running chauffeur process untouched"
    fi

    # --- CLI symlink ---
    # Only remove ~/.local/bin/chauffeur when it resolves into a
    # chauffeur-rs install. Pre-rename installs at
    # /Applications/ChauffeurRs.app are unambiguously Rust and always
    # removed. Post-rename, the Rust install lives at
    # /Applications/Chauffeur.app — the SAME path the Swift driver
    # uses — so we only remove that link when $RUST_INSTALL_PRESENT.
    if [[ -L "$USER_BIN_LINK" ]]; then
        RESOLVED="$(resolve_link "$USER_BIN_LINK")"
        case "$RESOLVED" in
            *"ChauffeurRs.app"*|*"$HOME_DIR"*|*".chauffeur-rs"*)
                # Unambiguous Rust paths.
                rm -f "$USER_BIN_LINK"
                log "removed $USER_BIN_LINK -> $RESOLVED"
                ;;
            *"/Applications/Chauffeur.app"*)
                # Shared with the Swift driver — require a Rust marker.
                if [[ "$RUST_INSTALL_PRESENT" == "1" ]]; then
                    rm -f "$USER_BIN_LINK"
                    log "removed $USER_BIN_LINK -> $RESOLVED"
                else
                    log "$USER_BIN_LINK -> $RESOLVED (shared with Swift driver and no Rust marker on disk; skipping)"
                fi
                ;;
            *)
                log "$USER_BIN_LINK resolves to $RESOLVED (not a chauffeur-rs path; skipping)"
                ;;
        esac
    elif [[ -e "$USER_BIN_LINK" ]]; then
        log "$USER_BIN_LINK exists but is not a symlink (skipping; refusing to clobber a real file)"
    else
        log "no CLI symlink at $USER_BIN_LINK (skipping)"
    fi

    release_supervisor remove

    # Cryptographic history purge must run while the exact installed helper
    # executable still exists. The helper uses the production KeyProvider and
    # its own bundle-derived namespace, then takes the exclusive writer lease;
    # failure leaves the runtime and all retryable history state in place.
    if [[ "$OS" == "Darwin" && "$PURGE_DATA" == "1" ]]; then
        HISTORY_PURGE_HELPER="$APP_BUNDLE/Contents/MacOS/chauffeur"
        if ! purge_macos_history \
            "$APP_BUNDLE" "$HISTORY_PURGE_HELPER" "$RUST_INSTALL_PRESENT" /usr/bin/codesign; then
            exit 1
        fi
        log "cryptographically purged release Computer History key and local history state"
    elif [[ "$OS" == "Darwin" ]]; then
        log "preserved encrypted Computer History if present; reinstall to reopen it or run uninstall.sh --purge to destroy it"
    elif [[ "$OS" == "Linux" && "$PURGE_DATA" == "1" ]]; then
        HISTORY_PURGE_HELPER="$PACKAGES_DIR/current/chauffeur"
        if ! purge_linux_history "$HISTORY_PURGE_HELPER" "$RUST_INSTALL_PRESENT"; then
            exit 1
        fi
        log "cryptographically purged release Computer History Secret Service key and local history state"
    elif [[ "$OS" == "Linux" ]]; then
        log "preserved encrypted Computer History if present; reinstall to reopen it or run uninstall.sh --purge to destroy it"
    fi

    # --- Revoke TCC grants BEFORE removing the app ---
    # tccutil resolves com.axe.chauffeur through LaunchServices, so the reset
    # only works while /Applications/Chauffeur.app is still installed. Running
    # it here (not at the closing message) is what makes the revoke actually
    # take — otherwise it fails with -10814 and the grant silently survives.
    maybe_reset_tcc

    # --- .app bundle (macOS only) ---
    # Legacy /Applications/ChauffeurRs.app is unambiguously Rust and
    # always removed when present. /Applications/Chauffeur.app is the
    # current canonical Rust path BUT also where the Swift driver
    # lives (same bundle id `com.axe.chauffeur`), so we only remove
    # it when $RUST_INSTALL_PRESENT — protects a Swift-only Mac from
    # losing its bundle if `uninstall.sh --experimental-rust` is run
    # by mistake.
    if [[ "$OS" == "Darwin" ]]; then
        if [[ -d "$LEGACY_APP_BUNDLE" ]]; then
            SUDO=""
            if [[ ! -w "$(dirname "$LEGACY_APP_BUNDLE")" ]]; then
                SUDO="sudo"
            fi
            $SUDO rm -rf "$LEGACY_APP_BUNDLE"
            log "removed $LEGACY_APP_BUNDLE"
        else
            log "no app bundle at $LEGACY_APP_BUNDLE (skipping)"
        fi
        if [[ -d "$APP_BUNDLE" ]]; then
            if [[ "$RUST_INSTALL_PRESENT" == "1" ]]; then
                SUDO=""
                if [[ ! -w "$(dirname "$APP_BUNDLE")" ]]; then
                    SUDO="sudo"
                fi
                $SUDO rm -rf "$APP_BUNDLE"
                log "removed $APP_BUNDLE"
            else
                log "$APP_BUNDLE exists but no Rust marker on disk (~/.chauffeur/packages/, ~/.chauffeur-rs/, ChauffeurRs.app, current/legacy LaunchAgent or systemd unit); leaving it (looks like a Swift-only install)"
            fi
        else
            log "no app bundle at $APP_BUNDLE (skipping)"
        fi
    fi

    # --- Package home ---
    # A normal uninstall deliberately keeps the pseudonymous installation ID,
    # persisted telemetry preference, and install/release markers. This lets a
    # later reinstall be counted as a returning installation without sending
    # any events while disabled. `--purge` is the explicit identity reset.
    # All removal remains gated on the Rust marker so a mistaken invocation
    # cannot damage a Swift-only Mac's shared ~/.chauffeur state.
    if [[ -d "$HOME_DIR" ]]; then
        if [[ "$RUST_INSTALL_PRESENT" == "1" || "$PURGE_DATA" == "1" ]]; then
            if [[ "$PURGE_DATA" == "1" ]]; then
                rm -rf "$HOME_DIR"
                log "purged $HOME_DIR (including telemetry identity and preference)"
            else
                # Remove only installer/runtime-owned payloads. Unknown files
                # and all telemetry state remain untouched.
                rm -rf "$HOME_DIR/packages" "$HOME_DIR/skills"
                rm -f \
                    "$HOME_DIR/.tcc-signing-identity" \
                    "$HOME_DIR/serve.out.log" \
                    "$HOME_DIR/serve.err.log"
                log "removed runtime payloads from $HOME_DIR"
                log "preserved telemetry identity, preference, and registration markers"
            fi
        else
            log "$HOME_DIR exists but no Rust marker on disk; leaving it (looks like a Swift-only / shared config dir)"
        fi
    else
        log "no package home at $HOME_DIR (skipping)"
    fi
    # Preserve legacy telemetry state during a normal uninstall so the
    # runtime's existing one-shot migration can carry the same identity into
    # ~/.chauffeur on reinstall.
    if [[ -d "$LEGACY_HOME_DIR" ]]; then
        if [[ "$PURGE_DATA" == "1" ]]; then
            rm -rf "$LEGACY_HOME_DIR"
            log "purged legacy package home $LEGACY_HOME_DIR"
        else
            rm -rf "$LEGACY_HOME_DIR/packages" "$LEGACY_HOME_DIR/skills"
            rm -f \
                "$LEGACY_HOME_DIR/.tcc-signing-identity" \
                "$LEGACY_HOME_DIR/serve.out.log" \
                "$LEGACY_HOME_DIR/serve.err.log"
            log "removed legacy runtime payloads and preserved legacy telemetry state"
        fi
    fi

    # --- Swift-era macOS data dirs (leave nothing behind) ---
    # The .app bundle + bundle id are shared with the retired Swift driver,
    # so a default (Rust) uninstall already removes the shared bundle. Sweep
    # the two Swift-only support/cache dirs here too so one `uninstall.sh`
    # leaves nothing behind regardless of which backend originally installed
    # — no second `--backend=swift` pass needed. Gated on the Rust marker
    # for the same reason the shared bundle is: a Swift-only Mac that runs
    # the default uninstall by mistake keeps its data.
    if [[ "$OS" == "Darwin" && "$RUST_INSTALL_PRESENT" == "1" ]]; then
        for SWIFT_DATA_DIR in \
            "$HOME/Library/Application Support/Chauffeur" \
            "$HOME/Library/Caches/chauffeur"; do
            if [[ -d "$SWIFT_DATA_DIR" ]]; then
                rm -rf "$SWIFT_DATA_DIR"
                log "removed $SWIFT_DATA_DIR"
            fi
        done
    fi

    # --- Agent skill symlinks ---
    # Only remove when the link is a symlink — never clobber a real
    # directory (a dev user with a hand-managed skills dir is safe).
    # We don't check the target here because `chauffeur skills install`
    # writes platform-dependent targets (the local copy under $HOME_DIR/
    # skills/chauffeur-rs/). The [[ -L ]] check is the load-bearing
    # safety bar.
    if [[ "$RUST_INSTALL_PRESENT" == "1" ]]; then
        for SKILL_LINK in \
            "$HOME/.claude/skills/$SKILL_PACK_NAME" \
            "$HOME/.agents/skills/$SKILL_PACK_NAME" \
            "$HOME/.openclaw/skills/$SKILL_PACK_NAME" \
            "$HOME/.config/opencode/skills/$SKILL_PACK_NAME" \
            "$HOME/.gemini/skills/$SKILL_PACK_NAME" \
            "$HOME/.hermes/skills/$SKILL_PACK_NAME" \
            "$HOME/.claude/skills/$LEGACY_SKILL_PACK_NAME" \
            "$HOME/.agents/skills/$LEGACY_SKILL_PACK_NAME" \
            "$HOME/.openclaw/skills/$LEGACY_SKILL_PACK_NAME" \
            "$HOME/.config/opencode/skills/$LEGACY_SKILL_PACK_NAME" \
            "$HOME/.gemini/skills/$LEGACY_SKILL_PACK_NAME" \
            "$HOME/.hermes/skills/$LEGACY_SKILL_PACK_NAME"; do
            if [[ -L "$SKILL_LINK" ]]; then
                rm -f "$SKILL_LINK"
                log "removed skill symlink $SKILL_LINK"
            elif [[ -d "$SKILL_LINK" ]]; then
                log "$SKILL_LINK is a real directory, not a symlink (skipping)"
            else
                log "no skill symlink at $SKILL_LINK (skipping)"
            fi
        done
    else
        log "no Rust install marker; leaving agent skill symlinks untouched"
    fi

    # --- Claude Code MCP registrations ---
    # Same scrub shape as the Swift branch, keyed on the chauffeur-rs
    # binary name + the per-platform install paths. Unrelated MCP
    # servers are left alone.
    CLAUDE_JSON="$HOME/.claude.json"
    if [[ -f "$CLAUDE_JSON" ]] && command -v python3 >/dev/null 2>&1; then
        PY_OUTPUT="$(
            CLAUDE_JSON="$CLAUDE_JSON" HOME_DIR="$HOME_DIR" RUST_INSTALL_PRESENT="$RUST_INSTALL_PRESENT" python3 <<'PY'
import json
import os
import shutil
import sys
import tempfile
import time

path = os.environ["CLAUDE_JSON"]
home_dir = os.environ.get("HOME_DIR", "")
rust_install_present = os.environ.get("RUST_INSTALL_PRESENT", "0") == "1"

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    print(f"could not read Claude config {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)

removed = []

def text_parts(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [item for item in value if isinstance(item, str)]
    return []

def invokes_chauffeur_rs(server):
    if not isinstance(server, dict):
        return False
    parts = []
    parts.extend(text_parts(server.get("command")))
    parts.extend(text_parts(server.get("args")))
    joined = " ".join(parts)
    # Match the Rust-port-specific anchors: bundle name, package home,
    # explicit ".chauffeur-rs" segment. Plain "chauffeur" alone is
    # ambiguous (the Swift binary uses the same filename). The shared
    # /Applications/Chauffeur.app path is ALSO ambiguous (Rust took
    # over the Swift bundle id) — only count it as Rust when a Rust
    # install marker is on disk; otherwise it is almost certainly a
    # Swift registration we should not scrub.
    if home_dir and home_dir in joined:
        return True
    if "ChauffeurRs.app" in joined or ".chauffeur-rs" in joined or "chauffeur-rs" in joined:
        return True
    if rust_install_present and "/Applications/Chauffeur.app" in joined:
        return True
    return False

def should_remove(name, server):
    return name in {"chauffeur-rs"} or invokes_chauffeur_rs(server)

def scrub_servers(servers, scope):
    if not isinstance(servers, dict):
        return
    for name in list(servers.keys()):
        if should_remove(name, servers[name]):
            del servers[name]
            removed.append(f"{scope}:{name}")

scrub_servers(data.get("mcpServers"), "user")

projects = data.get("projects")
if isinstance(projects, dict):
    for project in projects.values():
        if isinstance(project, dict):
            scrub_servers(project.get("mcpServers"), "project")

if not removed:
    raise SystemExit(0)

backup = f"{path}.bak-chauffeur-rs-uninstall-{int(time.time())}"
shutil.copy2(path, backup)

directory = os.path.dirname(path) or "."
fd, tmp_path = tempfile.mkstemp(
    prefix=".claude.json.",
    suffix=".tmp",
    dir=directory,
    text=True,
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp_path, path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise

print(f"removed Claude MCP registration(s): {', '.join(removed)}")
print(f"backed up Claude config to {backup}")
PY
        )"
        if [[ -n "$PY_OUTPUT" ]]; then
            while IFS= read -r line; do
                log "$line"
            done <<< "$PY_OUTPUT"
        else
            log "no Claude MCP registrations for chauffeur-rs found in $CLAUDE_JSON"
        fi
    else
        log "no Claude config cleanup via python3 (missing $CLAUDE_JSON or python3)"
    fi

    # Best-effort CLI cleanup. `claude mcp remove` only touches the
    # active project / user scopes — fine to run; it's a no-op when the
    # entries were already scrubbed above.
    if command -v claude >/dev/null 2>&1; then
        for SERVER in chauffeur-rs; do
            for SCOPE in local project user; do
                if claude mcp remove "$SERVER" -s "$SCOPE" >/dev/null 2>&1; then
                    log "removed Claude MCP server $SERVER from $SCOPE scope"
                fi
            done
        done
    else
        log "claude CLI not found (skipping Claude MCP CLI cleanup)"
    fi

    # --- Closing message ---
    # TCC grants were already revoked above, before the app was removed, so
    # the reset could still resolve the bundle id through LaunchServices.
    if [[ "$OS" == "Darwin" ]]; then
        echo ""
        echo "chauffeur uninstalled."
        if [[ "$PURGE_DATA" == "0" ]]; then
            cat << 'TELEMETRYUNMSG'

Telemetry identity and preference were preserved for a future reinstall.
To delete them too, re-run with --purge:

  /bin/bash -c "$(curl -fsSL https://chauffeur.ai/driver/uninstall.sh)" -- --purge
TELEMETRYUNMSG
        fi
        if [[ "$RESET_TCC" != "1" ]]; then
            cat << 'FINALUNMSG'

TCC grants (Accessibility + Screen Recording) remain in System
Settings > Privacy & Security because uninstall was run with --keep-tcc.
Reset them explicitly if you want a clean re-install flow:

  tccutil reset Accessibility com.axe.chauffeur
  tccutil reset ScreenCapture com.axe.chauffeur
FINALUNMSG
        fi
    else
        cat << 'FINALUNMSG'

chauffeur uninstalled.
FINALUNMSG
        if [[ "$PURGE_DATA" == "0" ]]; then
            cat << 'TELEMETRYUNMSG'

Telemetry identity and preference were preserved for a future reinstall.
To delete them too, re-run with --purge:

  /bin/bash -c "$(curl -fsSL https://chauffeur.ai/driver/uninstall.sh)" -- --purge
TELEMETRYUNMSG
        fi
    fi
    exit 0
fi

USER_BIN_LINK="$HOME/.local/bin/chauffeur"
SYSTEM_BIN_LINK="/usr/local/bin/chauffeur"
APP_BUNDLE="/Applications/Chauffeur.app"
USER_DATA="$HOME/.chauffeur"
CONFIG_DIR="$HOME/Library/Application Support/Chauffeur"
CACHE_DIR="$HOME/Library/Caches/chauffeur"
# Legacy — remove if present from older installs.
LEGACY_UPDATE_SCRIPT="/usr/local/bin/chauffeur-update"
LEGACY_UPDATER_PLIST="$HOME/Library/LaunchAgents/com.memjar.chauffeur_updater.plist"

# CLI symlinks. Try the user-bin first (no sudo), then the legacy
# /usr/local/bin path (needs sudo on default macOS).
for BIN_LINK in "$USER_BIN_LINK" "$SYSTEM_BIN_LINK"; do
    if [[ -L "$BIN_LINK" ]] || [[ -e "$BIN_LINK" ]]; then
        SUDO=""
        [[ ! -w "$(dirname "$BIN_LINK")" ]] && SUDO="sudo"
        $SUDO rm -f "$BIN_LINK"
        log "removed $BIN_LINK"
    fi
done

# Legacy update script + LaunchAgent (present in installs before 0.0.6).
if [[ -f "$LEGACY_UPDATE_SCRIPT" ]]; then
    SUDO=""; [[ ! -w "$(dirname "$LEGACY_UPDATE_SCRIPT")" ]] && SUDO="sudo"
    $SUDO rm -f "$LEGACY_UPDATE_SCRIPT"
    log "removed legacy $LEGACY_UPDATE_SCRIPT"
fi
if [[ -f "$LEGACY_UPDATER_PLIST" ]]; then
    launchctl unload "$LEGACY_UPDATER_PLIST" 2>/dev/null || true
    rm -f "$LEGACY_UPDATER_PLIST"
    log "removed legacy $LEGACY_UPDATER_PLIST"
fi

# .app bundle (in /Applications, usually writable by the user).
if [[ -d "$APP_BUNDLE" ]]; then
    SUDO=""
    if [[ ! -w "$(dirname "$APP_BUNDLE")" ]]; then
        SUDO="sudo"
    fi
    $SUDO rm -rf "$APP_BUNDLE"
    log "removed $APP_BUNDLE"
else
    log "no app bundle at $APP_BUNDLE (skipping)"
fi

# User-data directory (telemetry id + install marker).
if [[ -d "$USER_DATA" ]]; then
    rm -rf "$USER_DATA"
    log "removed $USER_DATA"
else
    log "no user data at $USER_DATA (skipping)"
fi

# Persisted config.
if [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
    log "removed $CONFIG_DIR"
else
    log "no config at $CONFIG_DIR (skipping)"
fi

# Cache / daemon state.
if [[ -d "$CACHE_DIR" ]]; then
    rm -rf "$CACHE_DIR"
    log "removed $CACHE_DIR"
else
    log "no cache at $CACHE_DIR (skipping)"
fi

# Agent skill symlinks (Claude Code + Codex). Only remove when the link
# is ours — a dev user pointing the symlink at a working copy of the
# repo keeps theirs untouched.
SKILL_TARGET_EXPECTED="$APP_BUNDLE/Contents/Resources/Skills/chauffeur"
for SKILL_LINK in \
    "$HOME/.claude/skills/chauffeur" \
    "$HOME/.agents/skills/chauffeur" \
    "$HOME/.openclaw/skills/chauffeur" \
    "$HOME/.config/opencode/skills/chauffeur" \
    "$HOME/.gemini/skills/chauffeur" \
    "$HOME/.hermes/skills/chauffeur"; do
    if [[ -L "$SKILL_LINK" ]] && [[ "$(readlink "$SKILL_LINK")" == "$SKILL_TARGET_EXPECTED" ]]; then
        rm -f "$SKILL_LINK"
        log "removed $SKILL_LINK"
    else
        log "no install-created skill symlink at $SKILL_LINK (skipping)"
    fi
done

# Claude Code MCP registrations. `claude mcp remove` only removes from
# the current project / user scopes, while ~/.claude.json can also
# contain stale project entries for other directories. Scrub only
# registrations explicitly named chauffeur or whose command points at
# a chauffeur binary, so unrelated servers named "computer-use" are
# left alone.
CLAUDE_JSON="$HOME/.claude.json"
if [[ -f "$CLAUDE_JSON" ]] && command -v python3 >/dev/null 2>&1; then
    PY_OUTPUT="$(
        CLAUDE_JSON="$CLAUDE_JSON" python3 <<'PY'
import json
import os
import shutil
import sys
import tempfile
import time

path = os.environ["CLAUDE_JSON"]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    print(f"could not read Claude config {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)

removed = []

def text_parts(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [item for item in value if isinstance(item, str)]
    return []

def invokes_chauffeur(server):
    if not isinstance(server, dict):
        return False
    parts = []
    parts.extend(text_parts(server.get("command")))
    parts.extend(text_parts(server.get("args")))
    joined = " ".join(parts)
    return "chauffeur" in joined or "Chauffeur.app" in joined

def should_remove(name, server):
    return name in {"chauffeur", "chauffeur-computer-use"} or invokes_chauffeur(server)

def scrub_servers(servers, scope):
    if not isinstance(servers, dict):
        return
    for name in list(servers.keys()):
        if should_remove(name, servers[name]):
            del servers[name]
            removed.append(f"{scope}:{name}")

scrub_servers(data.get("mcpServers"), "user")

projects = data.get("projects")
if isinstance(projects, dict):
    for project in projects.values():
        if isinstance(project, dict):
            scrub_servers(project.get("mcpServers"), "project")

if not removed:
    raise SystemExit(0)

backup = f"{path}.bak-chauffeur-uninstall-{int(time.time())}"
shutil.copy2(path, backup)

directory = os.path.dirname(path) or "."
fd, tmp_path = tempfile.mkstemp(
    prefix=".claude.json.",
    suffix=".tmp",
    dir=directory,
    text=True,
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp_path, path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise

print(f"removed Claude MCP registration(s): {', '.join(removed)}")
print(f"backed up Claude config to {backup}")
PY
    )"
    if [[ -n "$PY_OUTPUT" ]]; then
        while IFS= read -r line; do
            log "$line"
        done <<< "$PY_OUTPUT"
    else
        log "no Claude MCP registrations for chauffeur found in $CLAUDE_JSON"
    fi
else
    log "no Claude config cleanup via python3 (missing $CLAUDE_JSON or python3)"
fi

# Best-effort CLI cleanup for the active Claude project. This covers
# .mcp.json / current-working-directory scopes when present and is
# harmless when the entries were already removed above.
if command -v claude >/dev/null 2>&1; then
    for SERVER in chauffeur chauffeur-computer-use; do
        for SCOPE in local project user; do
            if claude mcp remove "$SERVER" -s "$SCOPE" >/dev/null 2>&1; then
                log "removed Claude MCP server $SERVER from $SCOPE scope"
            fi
        done
    done
else
    log "claude CLI not found (skipping Claude MCP CLI cleanup)"
fi

maybe_reset_tcc

echo ""
echo "chauffeur uninstalled."
if [[ "$RESET_TCC" != "1" ]]; then
    cat << 'FINALUNMSG'

TCC grants (Accessibility + Screen Recording) remain in System
Settings > Privacy & Security because uninstall was run with --keep-tcc.
Reset them explicitly if you want a clean re-install flow:

  tccutil reset Accessibility com.axe.chauffeur
  tccutil reset ScreenCapture com.axe.chauffeur
FINALUNMSG
fi
