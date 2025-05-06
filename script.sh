#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Arch TUI Installer – *boiler‑plate* proof‑of‑concept
# -----------------------------------------------------------------------------
# A minimal terminal user‑interface (TUI) installer intended to be piped from
# curl on a fresh Arch ISO.  It aims to mimic the high‑level flow of Ubuntu’s
# graphical installer while preserving the freedom Arch is loved for.
#
#  ⚠️  ***DISCLAIMER***
#      This script will eventually FORMAT disks and INSTALL packages.  Treat this
#      boilerplate as educational; test in a VM first and adapt it for your
#      needs.  Running it verbatim on bare metal may destroy data.
#
#  Usage idea (once published somewhere):
#      curl -L https://example.com/arch‑tui‑installer.sh | bash
#
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Globals & defaults                                                          #
###############################################################################
APP_NAME="Arch TUI Installer"
LOGFILE="/tmp/arch‑installer.log"
LANGUAGE="en_US.UTF‑8"      # will be overwritten by UI
KEYMAP="us"                 # ditto
TIMEZONE="UTC"              # ditto
USERNAME=""                 # ditto
PASSWORD=""                 # ditto
TARGET_DISK=""              # /dev/…
INSTALL_MODE="guided‑erase" # or "manual"
EFI_MOUNT="/mnt/boot"
ROOT_MOUNT="/mnt"

###############################################################################
# Debug helpers
###############################################################################
# Turn Bash x‑trace on only for commands we wrap with run().
# The trace is written to $LOGFILE but not to the screen (TUI stays clean).
BASH_XTRACEFD=9    # fd 9 will carry the x‑trace
exec 9>>"$LOGFILE" # open it for appending

run() {
  set -o xtrace # enable x‑trace for the *next* command
  "$@"          # execute the command exactly as we received it
  local rc=$?
  set +o xtrace        # back to quiet mode
  log "[RC] $1 -> $rc" # record the return code
  return $rc
}

###############################################################################
# Helper functions                                                            #
###############################################################################
log() { printf "[LOG] %s\n" "$*" | tee -a "$LOGFILE"; }
err() { printf "[ERR] %s\n" "$*" | tee -a "$LOGFILE" >&2; }
die() {
  err "$1"
  exit 1
}

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root (e.g. sudo su) before starting $APP_NAME."
}

require_dialog() {
  command -v dialog >/dev/null 2>&1 && return
  log "dialog not found – installing with pacman …"
  pacman -Sy --noconfirm dialog || die "Failed to install dialog."
}

cleanup() {
  dialog --clear || true
}
trap cleanup EXIT

###############################################################################
# User‑interface wrappers (dialog)                                            #
###############################################################################
# NB: Arch ISO ships with dialog by default; whiptail works too with the same
# API.  Abstracted to keep the rest of the script clean.

prompt_menu() {
  local title="$1"
  shift
  local prompt="$1"
  shift
  local -a options=("$@")
  local choice
  choice=$(dialog --clear --stdout --backtitle "$APP_NAME" \
    --title "$title" --menu "$prompt" 15 60 10 "${options[@]}")
  echo "$choice"
}

prompt_input() {
  local title="$1"
  shift
  local prompt="$1"
  shift
  local default="${1:-}"
  dialog --clear --stdout --backtitle "$APP_NAME" \
    --title "$title" --inputbox "$prompt" 10 60 "$default"
}

prompt_password() {
  local title="$1"
  shift
  local prompt="$1"
  shift
  dialog --clear --stdout --backtitle "$APP_NAME" \
    --title "$title" --insecure --passwordbox "$prompt" 10 60
}

prompt_yesno() {
  local title="$1"
  shift
  local prompt="$1"
  shift
  dialog --clear --stdout --backtitle "$APP_NAME" \
    --title "$title" --yesno "$prompt" 8 60
  return $? # 0 = Yes, 1 = No
}

###############################################################################
# Stage 1 – Collect configuration                                            #
###############################################################################

collect_locale() {
  log "TTY size: $(stty size || echo 'unknown')"

  # 1) gather locales from SUPPORTED or fall back to locale.gen
  local -a locale_tags
  if [[ -r /usr/share/i18n/SUPPORTED ]]; then
    mapfile -t locale_tags < <(
      awk '$0 ~ /UTF-8$/ {print $1}' /usr/share/i18n/SUPPORTED
    )
  else
    mapfile -t locale_tags < <(
      grep -E 'UTF-8$' /etc/locale.gen | sed 's/^#\s*//' | awk '{print $1}'
    )
  fi
  [[ ${#locale_tags[@]} -eq 0 ]] && locale_tags=(en_US.UTF-8)

  log "locale_tags count: ${#locale_tags[@]}"
  printf '[LOG] locale_tags[0..4] = %s\n' "${locale_tags[@]:0:5}" | tee -a "$LOGFILE"

  # 2) build (tag, description) menu list
  local -a options=()
  for tag in "${locale_tags[@]}"; do options+=("$tag" ""); done

  log "options count (must be even): ${#options[@]}"

  # 3) run dialog with auto‑sizing (0 0) so it always fits
  local language
  language=$(
    run dialog --clear --stdout --backtitle "$APP_NAME" \
      --title "Language / Locale" \
      --scrollbar \
      --menu "Choose your locale:" \
      20 70 12 \
      "${options[@]}"
  ) || die "dialog failed (rc=$?)"

  log "Selected locale: $language"
}

collect_keymap() {
  local -a keymaps
  if command -v localectl >/dev/null 2>&1; then
    mapfile -t keymaps < <(localectl list-keymaps)
  else
    mapfile -t keymaps < <(
      find /usr/share/kbd/keymaps -type f -name '*.map*' -printf '%f\n' |
        sed 's/\.map.*//' | sort -u
    )
  fi
  [[ ${#keymaps[@]} -eq 0 ]] && keymaps=(us)

  # (tag, description) pairs for the menu
  local -a options=()
  for km in "${keymaps[@]}"; do options+=("$km" ""); done

  # --scrollbar must come **before** --menu, sizes before the tag list
  KEYMAP=$(
    dialog --clear --stdout --backtitle "$APP_NAME" \
      --title "Keyboard layout" \
      --scrollbar \
      --menu "Choose console keymap:" \
      20 70 12 \
      "${options[@]}"
  ) || die "Keymap selection cancelled"

  log "Selected keymap: $KEYMAP"

  # Apply the layout immediately in the live session
  if loadkeys "$KEYMAP" 2>/dev/null; then
    log "Console keymap switched to $KEYMAP for live session"
  else
    err "loadkeys $KEYMAP failed – layout may need full path"
  fi
}

collect_timezone() {
  TIMEZONE=$(prompt_input "Timezone" \
    "Enter your IANA timezone (e.g. Europe/Zurich):" "$(curl -s --max-time 3 https://ipapi.co/timezone 2>/dev/null || echo UTC)")
  log "Selected timezone: $TIMEZONE"
}

collect_user() {
  USERNAME=$(prompt_input "User" "Choose a new username:")
  log "Username set to: $USERNAME"

  local attempt=0 pass1 pass2
  while [ "$attempt" -lt 3 ]; do
    pass1=$(prompt_password "Password" "Enter password for $USERNAME:") ||
      die "Password entry cancelled"
    pass2=$(prompt_password "Confirm password" "Re‑enter the same password:") ||
      die "Password confirmation cancelled"

    if [[ $pass1 == "$pass2" ]]; then
      PASSWORD=$pass1
      log "Password set successfully"
      return 0
    fi

    dialog --backtitle "$APP_NAME" --title "Mismatch" \
      --msgbox "\nPasswords did not match – please try again.\n" 8 60
    attempt=$((attempt + 1))
  done

  die "Failed to set matching password after 3 attempts"
}

collect_disk() {
  # List block devices ignoring ISO/loop devices.
  local disks=()
  while read -r dev size; do
    disks+=("$dev" "$size")
  done < <(lsblk -rnd -o NAME,SIZE | awk '$1 !~ /^loop/ {print "/dev/"$1, $2}')
  TARGET_DISK=$(prompt_menu "Disk" "Select installation disk:" "${disks[@]}")
  [ -n "$TARGET_DISK" ] || die "No disk selected."

  prompt_yesno "Partitioning" "Erase *all* data on $TARGET_DISK and use guided partitioning?" && INSTALL_MODE="guided‑erase" || INSTALL_MODE="manual"
}

###############################################################################
# Stage 2 – Partition & format                                               #
###############################################################################
partition_guided() {
  log "Guided partitioning on $TARGET_DISK …"
  # Sample layout: EFI 512 MiB, the rest /.  Adjust as desired.
  sgdisk --zap-all "$TARGET_DISK"
  sgdisk -n 1:0:+512MiB -t 1:ef00 "$TARGET_DISK"
  sgdisk -n 2:0:0 -t 2:8300 "$TARGET_DISK"

  mkfs.fat -F32 "${TARGET_DISK}1"
  mkfs.ext4 -F "${TARGET_DISK}2"

  mount "${TARGET_DISK}2" "$ROOT_MOUNT"
  mkdir -p "$EFI_MOUNT"
  mount "${TARGET_DISK}1" "$EFI_MOUNT"
}

partition_manual() {
  dialog --msgbox "\nYou chose manual partitioning.  Press <OK> to open fdisk; create partitions, then exit fdisk.\n" 10 60
  fdisk "$TARGET_DISK"
  dialog --msgbox "\nNow create filesystems & mount under /mnt manually in another TTY, then return here and press <OK>.\n" 10 60
}

###############################################################################
# Stage 3 – Install base system                                              #
###############################################################################
install_arch() {
  log "Installing base system …"
  pacstrap -K "$ROOT_MOUNT" base linux linux-firmware dialog sudo networkmanager grub efibootmgr || die "pacstrap failed"
  genfstab -U "$ROOT_MOUNT" >>"$ROOT_MOUNT/etc/fstab"
}

###############################################################################
# Stage 4 – Configure system (inside chroot)                                 #
###############################################################################
chroot_config() {
  cat >"$ROOT_MOUNT/root/arch‑tui‑postinstall.sh" <<POST
#!/usr/bin/env bash
set -euo pipefail
log() { echo "[chroot] \$*"; }

# Locale
sed -i "s/^#\($LANGUAGE\)/\1/" /etc/locale.gen
locale-gen
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Console keymap
cat > /etc/vconsole.conf << EOF
KEYMAP=$KEYMAP
EOF

# NetworkManager
systemctl enable NetworkManager

# Users
useradd -m -G wheel $USERNAME
printf "%s:%s" "$USERNAME" "$PASSWORD" | chpasswd
printf "root:%s" "$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# Bootloader
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch
grub-mkconfig -o /boot/grub/grub.cfg

log "Configuration in chroot complete!"
POST
  chmod +x "$ROOT_MOUNT/root/arch‑tui‑postinstall.sh"
  arch-chroot "$ROOT_MOUNT" /root/arch‑tui‑postinstall.sh
  rm "$ROOT_MOUNT/root/arch‑tui‑postinstall.sh"
}

###############################################################################
# Main flow                                                                  #
###############################################################################
main() {
  log "STARTING ARCH INSTALLER"
  require_root
  require_dialog
  dialog --backtitle "$APP_NAME" --title "Welcome" --msgbox "\nWelcome to the $APP_NAME!\nPress <OK> to begin the guided setup.\n" 10 60

  collect_locale
  collect_keymap
  collect_timezone
  collect_user
  collect_disk

  if [[ "$INSTALL_MODE" == "guided‑erase" ]]; then
    partition_guided
  else
    partition_manual
  fi

  install_arch
  chroot_config

  dialog --backtitle "$APP_NAME" --title "Finished" --msgbox "\nInstallation complete!  You may reboot now.\n" 10 60
}

main "$@"
