#!/bin/bash
# Automated QEMU smoke test for CanvOS Edge Appliance images.
# Boots the installer ISO in QEMU, selects "manual" mode via GRUB,
# waits for boot, runs validation checks inside the VM, and reports results.
#
# Usage: ./smoke-test-auto.sh <path-to-iso>
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
#   2 - Boot timeout or QEMU error
#
# Environment variables:
#   MEMORY        - VM memory in MB (default: 10096)
#   CORES         - CPU cores (default: 5)
#   CPU           - CPU model (default: host)
#   BOOT_TIMEOUT  - Seconds to wait for boot (default: 300)
#   TEST_TIMEOUT  - Seconds to wait for test results (default: 120)

set -euo pipefail

ISO_FILE="${1:?Usage: $0 <iso-file>}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
TEST_TIMEOUT="${TEST_TIMEOUT:-120}"
MEMORY="${MEMORY:-10096}"
CORES="${CORES:-5}"
CPU="${CPU:-host}"

WORK_DIR="$(mktemp -d /tmp/smoke-test-XXXXXX)"
LOG_FILE="${WORK_DIR}/console.log"
INPUT_FIFO="${WORK_DIR}/serial-in"
MONITOR_SOCK="${WORK_DIR}/qemu-monitor.sock"
DISK_IMG="${WORK_DIR}/disk.img"
QEMU_PID=""

# --- Cleanup ---
cleanup() {
    local rc=$?
    set +e
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "Shutting down QEMU (PID $QEMU_PID)..."
        kill "$QEMU_PID" 2>/dev/null
        wait "$QEMU_PID" 2>/dev/null
    fi
    exec 3>&- 2>/dev/null
    rm -rf "$WORK_DIR"
    exit $rc
}
trap cleanup EXIT INT TERM

# --- Helpers ---
wait_for_pattern() {
    local pattern="$1" timeout="$2"
    local start
    start=$(date +%s)
    while true; do
        if grep -q "$pattern" "$LOG_FILE" 2>/dev/null; then
            return 0
        fi
        if [ $(($(date +%s) - start)) -ge "$timeout" ]; then
            return 1
        fi
        sleep 1
    done
}

monitor_send() {
    # Send a command to the QEMU monitor via Unix socket
    # Use nc -U (OpenBSD netcat) or fall back to python3
    if command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q '\-U'; then
        printf '%s\n' "$1" | nc -U -w1 "$MONITOR_SOCK" >/dev/null 2>&1 || true
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import socket, time, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
time.sleep(0.2)
s.recv(4096)
s.sendall((sys.argv[2] + '\n').encode())
time.sleep(0.2)
s.close()
" "$MONITOR_SOCK" "$1"
    else
        echo "[FAIL] Need nc (with -U) or python3 for QEMU monitor" >&2
        return 1
    fi
}

serial_send() {
    # Write to the VM's serial console via the FIFO
    printf '%s\n' "$1" >&3
}

# --- Pre-flight checks ---
if [ ! -f "$ISO_FILE" ]; then
    echo "[FAIL] ISO not found: $ISO_FILE"
    exit 2
fi

KVM_FLAG="-enable-kvm"
if [ ! -e /dev/kvm ]; then
    echo "[WARN] /dev/kvm not available — falling back to TCG (slow)"
    KVM_FLAG=""
fi

# --- Setup ---
mkfifo "$INPUT_FIFO"
qemu-img create -f qcow2 "$DISK_IMG" 60g >/dev/null 2>&1
touch "$LOG_FILE"

echo "=== Automated QEMU Smoke Test ==="
echo "  ISO:     $ISO_FILE"
echo "  Memory:  ${MEMORY}MB  Cores: ${CORES}"
echo "  Timeouts: boot=${BOOT_TIMEOUT}s  test=${TEST_TIMEOUT}s"
echo ""

# --- Launch QEMU ---
# Open FIFO read-write on fd 3 to prevent EOF
exec 3<>"$INPUT_FIFO"

# shellcheck disable=SC2086
qemu-system-x86_64 \
    $KVM_FLAG \
    -cpu "$CPU" \
    -nographic \
    -m "$MEMORY" \
    -smp "$CORES" \
    -monitor unix:"$MONITOR_SOCK",server=on,wait=off \
    -serial mon:stdio \
    -rtc base=utc,clock=rt \
    -drive if=virtio,media=disk,file="$DISK_IMG" \
    -drive if=ide,media=cdrom,file="$ISO_FILE" \
    <&3 >"$LOG_FILE" 2>&1 &
QEMU_PID=$!

echo "QEMU started (PID $QEMU_PID)"

# --- Select GRUB entry 1 (manual mode) ---
echo "Waiting for GRUB menu..."
if ! wait_for_pattern "Installer" 60; then
    echo "[FAIL] GRUB menu did not appear within 60s"
    echo "Last 20 lines of console:"
    tail -20 "$LOG_FILE" 2>/dev/null || true
    exit 2
fi

sleep 2
echo "Selecting GRUB entry 1 (manual mode)..."
monitor_send "sendkey down"
sleep 0.5
monitor_send "sendkey ret"

# --- Wait for boot ---
echo "Waiting for system boot (timeout: ${BOOT_TIMEOUT}s)..."
if ! wait_for_pattern "login:" "$BOOT_TIMEOUT"; then
    echo "[FAIL] System did not reach login prompt within ${BOOT_TIMEOUT}s"
    echo "Last 30 lines of console:"
    tail -30 "$LOG_FILE" 2>/dev/null || true
    exit 2
fi
echo "System booted — logging in..."

# --- Login ---
sleep 2
serial_send "root"
sleep 3

# --- Send test script ---
echo "Running smoke checks inside VM..."

# Write the test script as a single heredoc, then execute it
serial_send 'cat > /tmp/smoke.sh << "ENDSMOKE"'
serial_send '#!/bin/bash'
serial_send 'echo "===SMOKE_TEST_START==="'
serial_send ''
serial_send '# 1. Kernel version'
serial_send 'KVER=$(uname -r)'
serial_send 'if echo "$KVER" | grep -qE "^6\.14\."; then'
serial_send '  echo "RESULT:kernel:PASS:Kernel $KVER (DOCA 3.3.0 supported)"'
serial_send 'elif echo "$KVER" | grep -qE "^6\.(8|5)\."; then'
serial_send '  echo "RESULT:kernel:PASS:GA kernel $KVER"'
serial_send 'elif echo "$KVER" | grep -qE "^6\.1[0-9]\."; then'
serial_send '  echo "RESULT:kernel:WARN:HWE kernel $KVER"'
serial_send 'else'
serial_send '  echo "RESULT:kernel:INFO:Kernel $KVER"'
serial_send 'fi'
serial_send ''
serial_send '# 1b. NVIDIA GPU driver'
serial_send 'if dpkg -l nvidia-driver-580-open 2>/dev/null | grep -q "^ii"; then'
serial_send '  NVER=$(dpkg -l nvidia-driver-580-open 2>/dev/null | awk "/^ii/{print \$3}")'
serial_send '  echo "RESULT:nvidia:PASS:nvidia-driver-580-open $NVER"'
serial_send 'else'
serial_send '  echo "RESULT:nvidia:WARN:nvidia-driver-580-open not found"'
serial_send 'fi'
serial_send ''
serial_send '# 1c. DKMS modules'
serial_send 'if command -v dkms >/dev/null 2>&1; then'
serial_send '  DKMS_OUT=$(dkms status 2>/dev/null)'
serial_send '  if [ -n "$DKMS_OUT" ]; then'
serial_send '    echo "RESULT:dkms:PASS:DKMS modules: $DKMS_OUT"'
serial_send '  else'
serial_send '    echo "RESULT:dkms:WARN:dkms installed but no modules found"'
serial_send '  fi'
serial_send 'else'
serial_send '  echo "RESULT:dkms:INFO:dkms not installed"'
serial_send 'fi'
serial_send ''
serial_send '# 2. Kairos immutable OS'
serial_send 'if [ -d /etc/kairos ]; then'
serial_send '  echo "RESULT:kairos:PASS:/etc/kairos exists (immutable OS)"'
serial_send 'else'
serial_send '  echo "RESULT:kairos:FAIL:/etc/kairos not found"'
serial_send 'fi'
serial_send ''
serial_send '# 3. DOCA packages'
serial_send 'DOCA_COUNT=$(dpkg -l 2>/dev/null | grep -c doca || echo 0)'
serial_send 'if [ "$DOCA_COUNT" -gt 0 ]; then'
serial_send '  echo "RESULT:doca:PASS:${DOCA_COUNT} DOCA packages installed"'
serial_send 'else'
serial_send '  echo "RESULT:doca:FAIL:No DOCA packages found"'
serial_send 'fi'
serial_send ''
serial_send '# 4. BFB firmware'
serial_send 'BFB=$(ls /opt/spectrocloud/spcx/bfb/*.bfb 2>/dev/null | head -1)'
serial_send 'if [ -n "$BFB" ]; then'
serial_send '  BFB_SIZE=$(du -h "$BFB" | cut -f1)'
serial_send '  echo "RESULT:bfb:PASS:$(basename "$BFB") ($BFB_SIZE)"'
serial_send 'else'
serial_send '  echo "RESULT:bfb:FAIL:No BFB firmware in /opt/spectrocloud/spcx/bfb/"'
serial_send 'fi'
serial_send ''
serial_send '# 5. nodeprep.sh'
serial_send 'if [ -x /opt/spectrocloud/nodeprep.sh ]; then'
serial_send '  echo "RESULT:nodeprep:PASS:nodeprep.sh executable"'
serial_send 'else'
serial_send '  echo "RESULT:nodeprep:FAIL:nodeprep.sh missing or not executable"'
serial_send 'fi'
serial_send ''
serial_send '# 6. Overlay configs'
serial_send 'for f in /etc/modprobe.d/blacklist-nouveau.conf \'
serial_send '         /etc/modprobe.d/ib_core.conf \'
serial_send '         /etc/lldpd.d/rcp-lldpd.conf \'
serial_send '         /etc/modules-load.d/nfsrdma.conf; do'
serial_send '  fname=$(basename "$f")'
serial_send '  if [ -f "$f" ]; then'
serial_send '    echo "RESULT:overlay_${fname}:PASS:${f}"'
serial_send '  else'
serial_send '    echo "RESULT:overlay_${fname}:FAIL:${f} missing"'
serial_send '  fi'
serial_send 'done'
serial_send ''
serial_send '# 7. GCC'
serial_send 'GCC=$(which gcc-14 2>/dev/null || which gcc-12 2>/dev/null || echo "")'
serial_send 'if [ -n "$GCC" ]; then'
serial_send '  echo "RESULT:gcc:PASS:$(basename "$GCC") found"'
serial_send 'else'
serial_send '  echo "RESULT:gcc:FAIL:gcc-14/gcc-12 not found"'
serial_send 'fi'
serial_send ''
serial_send '# 8. Systemd health'
serial_send 'SYS_STATE=$(systemctl is-system-running 2>/dev/null || echo "unknown")'
serial_send 'case "$SYS_STATE" in'
serial_send '  running)  echo "RESULT:systemd:PASS:$SYS_STATE" ;;'
serial_send '  degraded) echo "RESULT:systemd:WARN:$SYS_STATE" ;;'
serial_send '  *)        echo "RESULT:systemd:WARN:$SYS_STATE" ;;'
serial_send 'esac'
serial_send ''
serial_send 'echo "===SMOKE_TEST_END==="'
serial_send 'ENDSMOKE'

sleep 1
serial_send 'chmod +x /tmp/smoke.sh && /tmp/smoke.sh'

# --- Wait for results ---
echo "Waiting for test results (timeout: ${TEST_TIMEOUT}s)..."
if ! wait_for_pattern "===SMOKE_TEST_END===" "$TEST_TIMEOUT"; then
    echo "[FAIL] Smoke checks did not complete within ${TEST_TIMEOUT}s"
    echo "Last 30 lines of console:"
    tail -30 "$LOG_FILE" 2>/dev/null || true
    exit 2
fi

# --- Parse and report ---
echo ""
echo "=== Smoke Test Results ==="
echo ""

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

while IFS=: read -r _ name status detail; do
    case "$status" in
        PASS)
            echo "  [PASS] ${name}: ${detail}"
            ((PASS_COUNT++)) || true
            ;;
        FAIL)
            echo "  [FAIL] ${name}: ${detail}"
            ((FAIL_COUNT++)) || true
            ;;
        WARN)
            echo "  [WARN] ${name}: ${detail}"
            ((WARN_COUNT++)) || true
            ;;
        INFO)
            echo "  [INFO] ${name}: ${detail}"
            ;;
    esac
done < <(grep "^RESULT:" "$LOG_FILE")

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${WARN_COUNT} warnings"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "SMOKE TEST FAILED"
    exit 1
else
    echo "SMOKE TEST PASSED"
    exit 0
fi
