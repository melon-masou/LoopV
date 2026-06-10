#!/bin/bash

enable_hyperv_timesync() (
  set -e
  apt-get update -qq
  apt-get install -y chrony
  mkdir -p /etc/chrony/conf.d
  cat > /etc/chrony/conf.d/hyperv.conf <<'LOOPVEOF'
refclock PHC /dev/ptp_hyperv poll 3 dpoll -2 offset 0 stratum 2
LOOPVEOF
  systemctl disable --now systemd-timesyncd
  systemctl enable chrony
  systemctl restart chrony
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

if [ -n "${SSH_LISTEN:-}" ]; then
  restrict_ssh || echo "LoopV: failed ssh-restrict" >&2
fi

if [ "${ENABLE_HYPERV_TIMESYNC:-false}" = "true" ]; then
  enable_hyperv_timesync || echo "LoopV: failed hyperv-timesync" >&2
fi

if [ "${DISABLE_HW_OFFLOAD:-false}" = "true" ]; then
  disable_hw_offload || echo "LoopV: failed disable-hw-offload" >&2
fi

if [ "${ENABLE_SERIAL_CONSOLE:-false}" = "true" ]; then
  enable_serial_console || echo "LoopV: failed serial-console" >&2
fi
