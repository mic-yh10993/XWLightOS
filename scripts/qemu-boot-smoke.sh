#!/bin/bash
# Bounded BIOS/UEFI boot smoke for the finished DclawOS ISO.  A menu that
# merely renders is insufficient: send Return to select the default Live item,
# then poll screendumps until the graphical desktop is visibly rendered (or
# the bounded budget runs out), and fail on QEMU-level diagnostics.
#
# Why poll instead of a single fixed snapshot: under TCG emulation on shared
# GitHub runners, the time from boot-menu selection to a rendered GNOME
# desktop varies widely (observed from ~2 to well over 2.5 minutes for the
# 3.6 GB GNOME image). A single fixed snapshot is flaky: fast runners pass,
# slow runners fail on a blank frame even though the ISO is fine.
set -euo pipefail

usage() {
    echo "usage: $0 ISO_PATH bios|uefi [seconds]" >&2
    exit 2
}

[ "$#" -ge 2 ] || usage
ISO="$1"
MODE="$2"
BUDGET="${3:-260}"
# Minimum dwell after selecting the Live entry before the first frame check.
# Screenshots taken earlier could catch the ISOLINUX boot menu or the early
# kernel text console instead of the finished desktop.
MIN_DWELL="${DCLAWOS_QEMU_MIN_DWELL:-90}"
POLL_INTERVAL="${DCLAWOS_QEMU_POLL_INTERVAL:-15}"
MONITOR_WAIT=20
BOOT_MENU_WAIT=8
# Margin kept at the end of the budget so the guest still has to be alive when
# the outer timeout fires, and so slow screendump/validate cycles cannot push
# the final frame check past the budget.
POLL_MARGIN=30
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VISUAL_VALIDATOR="$SCRIPT_DIR/validate-qemu-visual-frame.py"
START_EPOCH="$(date +%s)"
[ -s "$ISO" ] || { echo "ISO is missing or empty: $ISO" >&2; exit 1; }
case "$MODE" in bios|uefi) ;; *) usage ;; esac
if [ "$BUDGET" -lt $((MONITOR_WAIT + BOOT_MENU_WAIT + MIN_DWELL + POLL_INTERVAL + POLL_MARGIN)) ]; then
    echo "QEMU timeout ${BUDGET}s is too short for the required boot/poll budget" >&2
    exit 2
fi
for command in qemu-system-x86_64 timeout socat python3; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "required command is unavailable: $command" >&2
        exit 1
    }
done

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
MONITOR="$WORK/monitor.sock"
FRAME="${DCLAWOS_QEMU_SMOKE_FRAME:-${ISO}.${MODE}.ppm}"
LOG="$WORK/qemu.log"
# Guest serial console capture: the kernel cmdline (see build.yml
# --bootappend-live) maps /dev/console to ttyS0 and journald forwards the
# whole journal there, so GDM/accountsservice/PAM decisions land in this
# file. 2026-10-17 教训：Build #52 的烟测用 -serial none，guest 端零日志，
# 自动登录失败时完全无法区分"GDM 没尝试"还是"尝试后会话失败"。串口只做诊断，
# 不参与门禁判定。
SERIAL_LOG="$WORK/serial-guest.log"
rm -f "$FRAME"

# virtio-vga is the supported automated graphics test adapter. Standard VGA
# is retained as a documented compatibility follow-up rather than being used
# to infer whether the GNOME desktop has visibly rendered.
QEMU=(qemu-system-x86_64 -m 2048 -smp 2 -accel tcg -no-reboot -no-shutdown \
      -vga virtio -display none -monitor "unix:${MONITOR},server=on,wait=off" -serial "file:${SERIAL_LOG}" \
      -cdrom "$ISO" -boot d)
if [ "$MODE" = uefi ]; then
    if [ -n "${OVMF_CODE:-}" ]; then
        OVMF_IMAGE="$OVMF_CODE"
    elif [ -s /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_IMAGE=/usr/share/OVMF/OVMF_CODE.fd
    else
        OVMF_IMAGE=/usr/share/ovmf/OVMF.fd
    fi
    [ -s "$OVMF_IMAGE" ] || { echo "OVMF firmware not found: $OVMF_IMAGE" >&2; exit 1; }
    QEMU+=(-machine q35 -bios "$OVMF_IMAGE")
fi

set +e
timeout --foreground "${BUDGET}s" "${QEMU[@]}" 2>"$LOG" &
TIMEOUT_PID=$!
set -e

# Give firmware/ISOLINUX a bounded opportunity to render, then confirm the
# default Live entry.  This avoids treating a static boot menu as a success.
for _ in $(seq 1 "$MONITOR_WAIT"); do
    [ -S "$MONITOR" ] && break
    sleep 1
done
[ -S "$MONITOR" ] || {
    cat "$LOG" >&2 || true
    echo "QEMU $MODE did not expose a monitor socket" >&2
    exit 1
}
sleep "$BOOT_MENU_WAIT"
printf 'sendkey ret\n' | socat - UNIX-CONNECT:"$MONITOR" >/dev/null 2>&1 || {
    cat "$LOG" >&2 || true
    echo "QEMU $MODE could not select the default Live entry" >&2
    exit 1
}
# Wait out the kernel/udev/Xorg/GNOME startup window before polling frames,
# then keep sampling until the desktop is visibly rendered or the budget ends.
# Fast runners pass on an early poll; slow runners keep getting chances.
DEADLINE_EPOCH=$((START_EPOCH + BUDGET - POLL_MARGIN))
FRAME_OK=0
LAST_CHECK_LOG="$WORK/frame-check.log"
sleep "$MIN_DWELL"
while :; do
    printf 'screendump %s\n' "$FRAME" | socat - UNIX-CONNECT:"$MONITOR" >/dev/null 2>&1 || true
    if [ -s "$FRAME" ] && python3 "$VISUAL_VALIDATOR" "$FRAME" >"$LAST_CHECK_LOG" 2>&1; then
        cat "$LAST_CHECK_LOG"
        FRAME_OK=1
        break
    fi
    [ "$(date +%s)" -ge "$DEADLINE_EPOCH" ] && break
    sleep "$POLL_INTERVAL"
done

set +e
wait "$TIMEOUT_PID"
rc=$?
set -e
cat "$LOG"
# Bounded guest-console summary for the CI log. The serial log can be large
# over a 260s budget, so print marker hits first and only a short tail.
# Markers cover the autologin decision chain: GDM seat/config verdict,
# AccountsService user classification, PAM/session failures.
dump_guest_console() {
    local why="$1"
    echo "--- guest serial console (${why}) ---"
    if [ ! -s "$SERIAL_LOG" ]; then
        echo "(empty: guest wrote nothing to ttyS0; check the kernel cmdline console= settings)"
        return 0
    fi
    wc -c "$SERIAL_LOG"
    grep -a -iE "gdm|autologin|accountsservice|pam|seat0|FAILED|failed|error" "$SERIAL_LOG" | tail -60 || true
    echo "--- guest serial console tail (last 30 lines) ---"
    tail -30 "$SERIAL_LOG" || true
}
if [ "$FRAME_OK" -ne 1 ]; then
    echo "QEMU $MODE never rendered the Live graphical desktop within ${BUDGET}s budget" >&2
    [ -f "$LAST_CHECK_LOG" ] && cat "$LAST_CHECK_LOG" >&2 || true
    dump_guest_console "desktop not reached" >&2
    exit 1
fi
# Timeout means the guest remained alive past the bounded post-selection boot
# interval; immediate exits or host-visible firmware errors fail the job.
if [ "$rc" -ne 124 ]; then
    echo "QEMU $MODE boot smoke failed with exit status $rc" >&2
    dump_guest_console "qemu exited early" >&2
    exit 1
fi
if grep -qiE 'could not open|failed to load|no bootable device|fatal' "$LOG"; then
    echo "QEMU $MODE emitted a boot failure diagnostic" >&2
    dump_guest_console "qemu boot diagnostic" >&2
    exit 1
fi
echo "QEMU $MODE boot smoke passed (frame: $FRAME)"
# Positive autologin proof for the CI log: with GDM [debug] enabled, these
# lines only appear when GDM actually attempted the automatic login.
if grep -a -qi "automatic login conversation" "$SERIAL_LOG" 2>/dev/null; then
    echo "QEMU $MODE guest log confirms GDM attempted the automatic login"
else
    echo "QEMU $MODE note: no GDM automatic-login attempt marker in guest log" >&2
fi
