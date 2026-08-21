#!/bin/bash

setup_chrony() (
  if ! command -v chronyd >/dev/null 2>&1; then
    if ! apt-get update -qq; then
      return 1
    fi

    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y chrony; then
      return 1
    fi
  fi

  if [ ! -e /dev/ptp_hyperv ]; then
    echo "LoopV: /dev/ptp_hyperv is missing" >&2
    return 1
  fi

  mkdir -p /etc/chrony
  cat > /etc/chrony/chrony.conf <<'LOOPVEOF'
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
rtcsync
leapseclist /usr/share/zoneinfo/leap-seconds.list
refclock PHC /dev/ptp_hyperv poll 2 dpoll -2 offset 0 stratum 2 filter 4 minsamples 4 maxsamples 8 trust
maxupdateskew 100.0
makestep 0.1 -1
LOOPVEOF

  cat > /etc/udev/rules.d/99-loopv-hyperv-ptp.rules <<'LOOPVEOF'
ACTION=="add", SUBSYSTEM=="ptp", ATTR{clock_name}=="hyperv", SYMLINK+="ptp_hyperv", TAG+="systemd"
LOOPVEOF
  udevadm control --reload || true
  udevadm trigger --subsystem-match=ptp --action=add || true

  systemctl daemon-reload
  systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
  systemctl enable chrony >/dev/null 2>&1
  if ! systemctl restart chrony; then
    systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
    return 1
  fi
)

setup_hyperv_clocksource() (
  if grep -qw hyperv_clocksource_tsc_page /sys/devices/system/clocksource/clocksource0/available_clocksource 2>/dev/null; then
    echo hyperv_clocksource_tsc_page > /sys/devices/system/clocksource/clocksource0/current_clocksource
  fi

  if [ -w /sys/module/hv_utils/parameters/timesync_implicit ]; then
    echo Y > /sys/module/hv_utils/parameters/timesync_implicit
  fi

  mkdir -p /etc/default/grub.d
  cat > /etc/default/grub.d/99-loopv-clocksource.cfg <<'LOOPVEOF'
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX clocksource=hyperv_clocksource_tsc_page hv_utils.timesync_implicit=1"
LOOPVEOF
  update-grub
)

disable_hw_offload() (
  set -e
  cat > /etc/udev/rules.d/99-hyperv-offload.rules <<'LOOPVEOF'
ACTION=="add", SUBSYSTEM=="net", DRIVERS=="hv_netvsc", RUN+="/usr/sbin/ethtool -K %k tx off sg off tso off"
LOOPVEOF
)

restrict_ssh() (
  set -e
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-loopv-internal-only.conf <<LOOPVEOF
ListenAddress $SSH_LISTEN
LOOPVEOF
  systemctl restart ssh || systemctl restart sshd
)

enable_serial_console() (
  set -e
  mkdir -p /etc/default/grub.d
  cat > /etc/default/grub.d/99-serial.cfg <<'LOOPVEOF'
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX console=tty0 console=ttyS0,115200n8"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
LOOPVEOF
  update-grub
)

if [ "${ENABLE_HYPERV_TIMESYNC:-false}" = "true" ]; then
  if ! setup_hyperv_clocksource; then
    echo "LoopV: failed setup-hyperv-clocksource" >&2
  fi

  if ! setup_chrony; then
    echo "LoopV: failed setup-chrony" >&2
  fi
fi

if [ -n "${SSH_LISTEN:-}" ]; then
  if ! restrict_ssh; then
    echo "LoopV: failed ssh-restrict" >&2
  fi
fi

if [ "${DISABLE_HW_OFFLOAD:-false}" = "true" ]; then
  if ! disable_hw_offload; then
    echo "LoopV: failed disable-hw-offload" >&2
  fi
fi

if [ "${ENABLE_SERIAL_CONSOLE:-false}" = "true" ]; then
  if ! enable_serial_console; then
    echo "LoopV: failed serial-console" >&2
  fi
fi
