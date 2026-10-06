#!/usr/bin/env bash
# radxa-multiboot - safe multiboot manager for Rockchip/Radxa systems
# Combines boot selection, image inspection/installation and U-Boot/GPT maintenance.
#
# Requires bash >= 4.4 (insisted upon; the guard below re-execs or aborts under
# POSIX sh/ash). External tools are capability-probed: BusyBox/ToyBox applets,
# sysfs, /proc/mounts and sgdisk serve as fallbacks where GNU tools are absent.
#
# ANDROID SCOPE: Android disks, images and GPT partition layouts are recognized
# and protected, but this script refuses to run ON a booted Android (Android
# kernels commonly restrict loop-device partition scanning and direct block
# access). Manage Android disks from a rescue Linux system instead.

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
  echo "ERROR: radxa-multiboot requires bash; this is POSIX sh/ash/dash." >&2
  echo "Install bash and run: bash $0" >&2
  exit 1
fi

set -Eeuo pipefail
IFS=$'\n\t'
VERSION="3.3.0"
PROG=${0##*/}
DRY_RUN=0; YES=0; VERBOSE=0; REBOOT=0; ALL_DEVICES=0
WORKDIR=""; LOOPS=(); MOUNTS=()
TABLE_BACKEND=""; HEX_TOOL=""; SED_E="-E"
DD_STATUS=()
LEGACY_BIT=0x4000000000000000   # raw GPT attribute bit 62 ("legacy BIOS bootable")
declare -A TOOL_PATH=()

log(){ printf '==> %s\n' "$*"; }
warn(){ printf 'WARNING: %s\n' "$*" >&2; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
q(){ printf '%q ' "$@"; printf '\n'; }
run(){ printf '+ '; q "$@"; ((DRY_RUN)) || "$@"; }

# --- capability registry ----------------------------------------------------
probe_tools(){
  local t p
  for t in lsblk findmnt parted sgdisk blkid losetup partprobe partx blockdev wipefs \
           mkfs.ext2 mkfs.ext4 mke2fs mount umount mountpoint od hexdump readlink \
           awk sed grep sort dd udevadm busybox reboot date mktemp sleep cp sync mkdir rm head cat; do
    p=$(command -v "$t" 2>/dev/null || true)
    if [[ -n $p ]]; then TOOL_PATH[$t]=$p; fi
  done
}
have(){ [[ -n ${TOOL_PATH[$1]:-} ]]; }
need(){ have "$1" || die "Missing required tool: $1${2:+ ($2)}"; }
need_any(){
  local t
  for t in "$@"; do
    if have "$t"; then return 0; fi   # FIX(A3): if-form, no conditional tail
  done
  die "Missing required tool: one of: $*"
}
need_table_backend(){ have parted || have sgdisk || die "Missing required tool: parted or sgdisk (needed to read/write partition tables)."; }
need_sig_tools(){ have od || have hexdump || die "Missing required tool: od or hexdump (needed for the Rockchip signature check)."; }
am_root(){ ((EUID==0)); }
root_required(){ ((EUID==0)) || die "This command must be run as root."; }

# --- Android runtime refusal (content support only) -------------------------
# Returns 0 when we appear to be running ON a booted Android userspace.
# RADXA_MB_ALLOW_ANDROID=1 exists solely for testing the check itself.
android_runtime_check(){
  local u=""
  u=$(uname -o 2>/dev/null || true)
  if [[ $u == Android ]]; then return 0; fi
  if [[ -d /system && ( -f /system/build.prop || -d /system/app ) ]]; then return 0; fi
  return 1
}

init_dd_status(){
  if ! have dd; then return 0; fi
  if dd if=/dev/zero of=/dev/null bs=1 count=1 status=none 2>/dev/null; then DD_STATUS=(status=progress); fi
}
init_sed_flags(){ echo test | sed -E 's/t/T/' >/dev/null 2>&1 || SED_E="-r"; }
init_hex_tool(){                                  # FIX(SC2209): quoted assignments
  if printf 'ab' | od -An -tx1 2>/dev/null | grep -q '6162'; then
    HEX_TOOL="od"
  elif printf 'ab' | hexdump -v -e '/1 "%02x"' 2>/dev/null | grep -q '6162'; then
    HEX_TOOL="hexdump"
  fi
}
settle(){ if have udevadm; then udevadm settle 2>/dev/null || true; else sleep 1; fi; }
reread_partitions(){
  local dev=$1 did=0
  if have partprobe; then partprobe "$dev" 2>/dev/null || true; did=1; fi
  if (( ! did )) && have blockdev; then blockdev --rereadpt "$dev" 2>/dev/null || true; did=1; fi
  if (( ! did )) && have partx; then partx -u "$dev" 2>/dev/null || true; did=1; fi
  if (( ! did )); then warn "No partprobe/blockdev/partx found; new partitions may not appear until you run partprobe."; fi
  settle
}
tools_present(){
  local t out=""
  for t in lsblk findmnt parted sgdisk blkid losetup partprobe partx blockdev wipefs \
           mkfs.ext2 mkfs.ext4 mke2fs od hexdump mountpoint udevadm busybox; do
    if have "$t"; then out+="$t "; fi   # FIX(A3)
  done
  printf '%s' "$out"
}

cleanup(){
  local rc=$? i
  set +e
  trap - ERR   
  for ((i=${#MOUNTS[@]}-1;i>=0;i--)); do
    if mountpoint_q "${MOUNTS[$i]}"; then umount "${MOUNTS[$i]}" 2>/dev/null || true; fi
  done
  if have losetup; then
    for i in "${LOOPS[@]}"; do
      if losetup "$i" >/dev/null 2>&1; then losetup -d "$i" 2>/dev/null || true; fi
    done
  fi
  if [[ -n $WORKDIR && -d $WORKDIR ]]; then rm -rf -- "$WORKDIR"; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'die "Aborted at line ${BASH_LINENO[0]}"' ERR

usage(){ cat <<EOF
 $PROG $VERSION - Radxa/Rockchip multiboot manager

USAGE
  $PROG [global options] <command> [command options]

GLOBAL OPTIONS
  -n, --dry-run          Show actions only; do not write/mount/reboot
  -y, --yes              Answer confirmations automatically (not for high-risk actions)
  -v, --verbose          Log detected platform, tools and backends
      --all-devices      Also allow additional TYPE=disk devices
  -h, --help             Show this help
      --version          Show version

COMMANDS
  devices                List and classify storage devices

  status [options]       Multiboot status, root device, partlabels and flags
    -d, --device DEV       Examine only this disk
    -a, --all              Also show partitions without boot/root in PARTLABEL

  select [options]       Activate an existing boot_<OS> partition
    -d, --device DEV       Target disk; interactive choice if omitted
    -p, --partition N|DEV  Partition number/path; choice if omitted
    -f, --flag FLAG        auto|legacy_boot|boot (default: auto)
    -r, --reboot           Reboot after successful verification

  image-info -i IMAGE    Inspect an image: partitions, filesystems, fstab,
                         extlinux.conf and detected OS family

  init [options]         Create a new GPT including the Rockchip reservation areas
    -d, --device DEV       Target disk (required)
    -u, --uboot-file FILE  Take the first 16 MiB from an image/backup
                         WARNING: destroys the partition table and all data.

  install [options]      Import an OS image into boot/root partitions
    -i, --image-file IMG   Image file (required)
    -d, --device DEV       Boot and root on the same disk
    -b, --boot-dev DEV     Disk for the boot partition
    -r, --root-dev DEV     Disk for the root partition
    -B, --boot-part N      Use an existing boot partition
    -R, --root-part N      Use an existing root partition
        --boot-size MiB    New boot partition, default 256
        --root-size MiB    New root partition, default 4096
        --os-name NAME     Set the OS name explicitly
        --extlinux FILE    Use a custom extlinux.conf
        --lock-space       Create a 16-MiB boundary partition after root
        --activate         Activate the new boot partition afterwards
                         Existing partitions are reformatted.

  uboot-backup [options] Back up the first 16 MiB
    -d, --device DEV       Source device
    -o, --output FILE      Destination file

  uboot-write [options]  Write the Rockchip boot area (sector 64 to 16 MiB)
    -d, --device DEV       Target device
    -u, --uboot-file FILE  Image or 16-MiB backup

  uboot-zero [options]   Zero the Rockchip boot area
    -d, --device DEV       Target device

BACKENDS / FALLBACKS
  lsblk     -> sysfs (/sys/block); findmnt -> /proc/mounts; od -> hexdump
  parted    -> sgdisk (GPT only). legacy_boot = GPT attribute bit 62
               (sgdisk attribute number 2); boot/esp = partition type EF00.
               The sgdisk backend cannot clear boot/esp and reads attribute
               bits on a best-effort basis across sgdisk versions.
  wipefs    -> dd zeroing of first/last 1 MiB (init only)
  partprobe -> blockdev --rereadpt -> partx -u; udevadm settle -> sleep
  Core requirements: awk sed grep sort readlink cat date mktemp sleep cp
  sync mkdir rm head (+ dd, losetup, mkfs/mke2fs, blkid for the commands
  that need them). BusyBox/ToyBox applets satisfy these.

ANDROID
  Android disks, images and GPT layouts (super, userdata, *_a/*_b, vbmeta,
  ...) are recognized and protected with warnings, but they are managed
  FROM a normal Linux system (e.g. a rescue distro booted from SD/USB).
  Running this script ON a booted Android is refused at startup: Android
  kernels commonly restrict loop-device partition scanning and direct
  block-device access, and the required tools are absent.

EXAMPLES
  sudo $PROG --dry-run select
  sudo $PROG select -d /dev/mmcblk0 -p 8 --reboot
  sudo $PROG image-info -i Armbian.img
  sudo $PROG --dry-run install -i Armbian.img -d /dev/mmcblk0
  sudo $PROG uboot-backup -d /dev/mmcblk0 -o first16M.img

PARTITION NAMES
  Boot candidates must contain "boot"; "uboot" is excluded.
  install creates boot_<OS> and root_<OS>. On GPT, legacy_boot is used
  by default for selection. --flag boot sets the ESP alias on GPT.
  Android A/B slots (boot_a/boot_b) are shown but cannot be switched via
  GPT flags; slot selection belongs to the Android bootloader (BCB/misc).
EOF
}

confirm(){
  local phrase=${1:-YES} answer
  ((YES)) && return 0
  read -r -p "To continue, type exactly '$phrase': " answer
  [[ $answer == "$phrase" ]] || die "Not confirmed."
}
high_risk_confirm(){
  local dev=$1
  local phrase="DELETE-${dev##*/}" answer   
  ((DRY_RUN)) && return 0
  read -r -p "ALL DATA on $dev will be lost. Type exactly '$phrase': " answer
  [[ $answer == "$phrase" ]] || die "Not confirmed."
}

# --- device helpers (lsblk or sysfs) ----------------------------------------
is_disk_name(){ [[ $1 =~ ^/dev/(mmcblk[0-9]+|nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+|xvd[a-z]+)$ ]]; }
canon(){ local x=$1; [[ $x == /dev/* ]] || x=/dev/$x; readlink -f -- "$x" 2>/dev/null || printf '%s\n' "$x"; }
list_block_devs(){
  if have lsblk; then
    { lsblk -dnpr -o NAME 2>/dev/null || true; }
    return 0
  fi
  local d b
  for d in /sys/block/*; do
    b=${d##*/}
    case $b in loop*|ram*|zram*|dm-*|md*|nbd*|sr*|fd*|mtd*) continue;; esac
    if [[ -e /dev/$b ]]; then printf '/dev/%s\n' "$b"
    elif [[ -e /dev/block/$b ]]; then printf '/dev/block/%s\n' "$b"; fi
  done
}
dev_is_disk(){
  local d=$1 b
  b=${d##*/}                                  
  if have lsblk; then
    [[ $(lsblk -dn -o TYPE "$d" 2>/dev/null) == disk ]]
    return                                     
  fi
  [[ -e "/sys/block/$b" ]]
}
dev_ro(){
  local d=$1 b r=""
  b=${d##*/}                                   
  if have lsblk; then r=$(lsblk -dn -o RO "$d" 2>/dev/null | head -n1 || true); fi
  if [[ -z $r && -r "/sys/block/$b/ro" ]]; then read -r r < "/sys/block/$b/ro"; fi   
  printf '%s' "$r"
}
dev_rm(){
  local d=$1 b r=""
  b=${d##*/}                                   
  if have lsblk; then r=$(lsblk -dn -o RM "$d" 2>/dev/null | head -n1 || true); fi
  if [[ -z $r && -r "/sys/block/$b/removable" ]]; then read -r r < "/sys/block/$b/removable"; fi  
  printf '%s' "$r"
}
dev_model(){
  local d=$1 b r=""
  b=${d##*/}                                   
  if have lsblk; then r=$(lsblk -dn -o MODEL "$d" 2>/dev/null | sed 's/[[:space:]]*$//' | head -n1 || true); fi
  if [[ -z $r && -r "/sys/block/$b/device/model" ]]; then
    r=$(sed 's/[[:space:]]*$//' "/sys/block/$b/device/model" 2>/dev/null | head -n1 || true)   
  fi
  printf '%s' "$r"
}
hsize(){ awk -v s="$1" 'BEGIN{mib=s/2048; if(mib>=1024) printf "%.1fGiB", mib/1024; else printf "%dMiB", mib}'; }
dev_size(){
  local d=$1 b r="" s
  b=${d##*/}                                   
  if have lsblk; then r=$(lsblk -dn -o SIZE "$d" 2>/dev/null | head -n1 || true); fi
  if [[ -z $r && -r "/sys/block/$b/size" ]]; then read -r s < "/sys/block/$b/size"; r=$(hsize "$s"); fi   
  printf '%s' "$r"
}
dev_mounts(){
  local d=$1 s t
  if have lsblk; then
    { lsblk -nr -o MOUNTPOINT "$d" 2>/dev/null || true; } | awk 'NF'
    return 0
  fi
  d=$(readlink -f "$d" 2>/dev/null || printf '%s' "$d")
  while read -r s t _; do
    s=${s//\\040/ }
    if [[ $(readlink -f "$s" 2>/dev/null || printf '%s' "$s") == "$d" ]]; then printf '%s\n' "$t"; fi   
  done < /proc/mounts
}
part_path(){ [[ $1 =~ [0-9]$ ]] && printf '%sp%s' "$1" "$2" || printf '%s%s' "$1" "$2"; }
part_number(){
  local p=${1##*/} m=""
  if [[ $p =~ p([0-9]+)$ ]]; then m=${BASH_REMATCH[1]}
  elif [[ $p =~ ([0-9]+)$ ]]; then m=${BASH_REMATCH[1]}
  fi
  if [[ -z $m ]]; then return 1; fi           
  printf '%s' "$m"
}
part_parent(){
  local p=$1 b d
  b=${p##*/}                                  
  if have lsblk; then
    { lsblk -np -o PKNAME "$p" 2>/dev/null || true; } | head -n1
    return 0
  fi
  for d in /sys/block/*; do
    if [[ -e "$d/$b" ]]; then printf '/dev/%s\n' "${d##*/}"; return 0; fi
  done
  return 0
}
validate_disk(){
  local d
  d=$(canon "$1")
  [[ -b $d ]] || die "$d is not a block device."
  dev_is_disk "$d" || die "$d is not a TYPE=disk device."
  [[ $(dev_ro "$d") == 0 ]] || die "$d is read-only."
  ((ALL_DEVICES)) || is_disk_name "$d" || die "$d is not an allow-listed device type; consider --all-devices."
  printf '%s' "$d"
}
list_devices(){ if have lsblk; then lsblk -d -p -o NAME,SIZE,MODEL,TRAN,RM,RO,TYPE; else devices_detailed; fi; }
choose_device(){
  local supplied=${1:-} d answer i
  local -a a=()
  if [[ -n $supplied ]]; then validate_disk "$supplied"; return 0; fi
  while IFS= read -r d; do
    dev_is_disk "$d" || continue
    [[ $(dev_ro "$d") == 0 ]] || continue
    ((ALL_DEVICES)) || is_disk_name "$d" || continue
    a+=("$d")
  done < <(list_block_devs)
  ((${#a[@]})) || die "No suitable disk found."
  list_devices; printf '\n'
  for i in "${!a[@]}"; do printf '  %d) %s\n' "$((i+1))" "${a[$i]}"; done
  read -r -p "Disk [1-${#a[@]}]: " answer
  if [[ ! $answer =~ ^[0-9]+$ ]] || ((answer<1 || answer>${#a[@]})); then die "Invalid selection."; fi   
  printf '%s' "${a[$((answer-1))]}"
}

# --- mount info (findmnt or /proc/mounts) -----------------------------------
mountpoint_q(){
  local d=$1
  if have mountpoint; then mountpoint -q "$d" 2>/dev/null; return; fi
  if [[ -d $d ]]; then
    awk -v t="$d" '$2==t{found=1} END{exit !found}' /proc/mounts 2>/dev/null
    return
  fi
  return 1
}
mount_target_of(){
  local src=$1 s t
  src=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")
  if have findmnt; then
    { findmnt -n -o TARGET --source "$src" 2>/dev/null || true; } | head -n1
    return 0
  fi
  while read -r s t _; do
    s=${s//\\040/ }
    if [[ $(readlink -f "$s" 2>/dev/null || printf '%s' "$s") == "$src" ]]; then
      printf '%s\n' "$t"
      return 0
    fi
  done < /proc/mounts
  return 0
}
mount_source_for(){
  local path=$1 s t best="" bl=0
  if have findmnt; then
    { findmnt -n -o SOURCE --target "$path" 2>/dev/null || true; } | head -n1
    return 0
  fi
  while read -r s t _; do
    t=${t//\\040/ }
    case $t in "$path"|"$path"/*) ;; *) continue;; esac
    if (( ${#t} > bl )); then best=$s; bl=${#t}; fi   # FIX(A3)
  done < /proc/mounts
  printf '%s' "$best"
}
mounted_sources(){
  local s
  { if have findmnt; then findmnt -rn -o SOURCE 2>/dev/null || true; else awk '{print $1}' /proc/mounts 2>/dev/null || true; fi; } \
   | while IFS= read -r s; do
       s=${s//\\040/ }
       if [[ $s == /dev/* ]]; then readlink -f "$s" 2>/dev/null || printf '%s\n' "$s"; fi
     done | sort -u
}
assert_not_system_disk(){
  local d=$1 src parent
  while IFS= read -r src; do
    parent=$(part_parent "$src" 2>/dev/null || true)
    if [[ $parent == "$d" || $src == "$d" ]]; then
      die "$d contains a mounted filesystem ($src)."  
    fi
  done < <(mounted_sources)
}

# --- partition table backends (parted preferred, sgdisk fallback) -----------
init_table_backend(){
  if [[ -n $TABLE_BACKEND ]]; then return 0; fi
  if have parted; then TABLE_BACKEND=parted
  elif have sgdisk; then TABLE_BACKEND=sgdisk
  else die "Missing required tool: parted or sgdisk (needed to read/write partition tables)."
  fi
}
# NOTE: reads 4 bytes at BYTE offset 64.
# Everything else in this script treats 64 as a SECTOR number (byte 32768).
hex_at(){
  local f=$1 skip=$2 cnt=$3 raw=""
  if [[ -z $HEX_TOOL ]]; then die "Need a working od or hexdump for signature checks."; fi
  if [[ $HEX_TOOL == od ]]; then
    raw=$(dd if="$f" bs=1 skip="$skip" count="$cnt" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  else
    raw=$(dd if="$f" bs=1 skip="$skip" count="$cnt" 2>/dev/null | hexdump -v -e '/1 "%02x"')
  fi
  printf '%s' "${raw^^}"
}
rockchip_sig(){ hex_at "$1" 64 4; }
check_uboot_source(){
  [[ -f $1 || -b $1 ]] || die "U-Boot source not found: $1"
  need_sig_tools
  [[ $(rockchip_sig "$1") == 3B8CDCFC ]] || die "Rockchip signature 3B8CDCFC at offset 64 missing."
}
disk_label(){
  init_table_backend
  if [[ $TABLE_BACKEND == parted ]]; then
    { parted -m -s "$1" print 2>/dev/null || true; } | awk -F: 'NR==2{gsub(/;$/, "", $6); print $6}'
    return 0
  fi
  if sgdisk -p "$1" >/dev/null 2>&1; then printf 'gpt'; return 0; fi
  return 1
}
# unified output: number:start:end:size:fs:name:flags;   (parted -m compatible)
read_partitions(){
  local dev=$1 n s e sz code name fs flags a
  init_table_backend
  if [[ $TABLE_BACKEND == parted ]]; then
    parted -m -s "$dev" unit MiB print 2>/dev/null || true
    return 0
  fi
  while IFS='|' read -r n s e sz code name; do
    fs="-"
    flags=""
    if have blkid; then
      fs=$(blkid -s TYPE -o value "$(part_path "$dev" "$n")" 2>/dev/null || true)
      if [[ -z $fs ]]; then fs="-"; fi
    fi
    a=$(sgdisk_attr_raw "$n" "$dev")
    if (( a != -1 && (a & LEGACY_BIT) )); then flags="legacy_boot"; fi   
    if [[ ${code^^} == EF00 ]]; then flags="${flags:+$flags, }boot"; fi
    printf '%s:%d:%d:%s:%s:%s:%s;\n' "$n" $(( s/2048 )) $(( e/2048 )) "$sz" "$fs" "$name" "$flags"
  done < <(sgdisk -p "$dev" 2>/dev/null | awk '
    $1 ~ /^[0-9]+$/ {
      n=$1; s=$2; e=$3; sz=$4; un=$5; code=$6; name="";
      for(i=7;i<=NF;i++) name=name (i>7?" ":"") $i;
      printf "%s|%s|%s|%s%s|%s|%s\n", n,s,e,sz,un,code,name }')
}
# Best-effort readback of raw GPT attribute bits across sgdisk versions.
sgdisk_attr_raw(){
  local n=$1 dev=$2 out=""
  out=$(sgdisk -A "$n:show" "$dev" 2>/dev/null) || out=""
  if [[ $out =~ ([0-9A-Fa-f]{16}) ]]; then
    printf '%d' "$(( 16#${BASH_REMATCH[1]} ))"
    return 0
  fi
  out=$(sgdisk -A "$n:get:2" "$dev" 2>/dev/null) || out=""
  if [[ $out == *1* ]]; then printf '%d' "$(( LEGACY_BIT ))"; return 0; fi
  if [[ $out == *0* ]]; then printf '0'; return 0; fi
  printf '-1'
}
part_flags(){
  local dev=$1 n=$2 a=0 flags="" code=""
  init_table_backend
  if [[ $TABLE_BACKEND == parted ]]; then
    { parted -m -s "$dev" print 2>/dev/null || true; } | awk -F: -v n="$n" '$1==n{gsub(/;$/, "", $7); print $7}'
    return 0
  fi
  code=$({ sgdisk -p "$dev" 2>/dev/null || true; } | awk -v n="$n" '$1==n{print $6; exit}')
  a=$(sgdisk_attr_raw "$n" "$dev")
  if (( a != -1 && (a & LEGACY_BIT) )); then flags="legacy_boot"; fi   
  if [[ ${code^^} == EF00 ]]; then flags="${flags:+$flags, }boot"; fi
  printf '%s' "$flags"
}
has_flag(){ [[ ",${1// /}," == *",$2,"* ]]; }
set_partition_flag(){
  local dev=$1 n=$2 flag=$3 state=$4 op
  init_table_backend
  if [[ $TABLE_BACKEND == parted ]]; then
    run parted -s "$dev" set "$n" "$flag" "$state"
    return 0
  fi
  if [[ $flag == legacy_boot ]]; then
    if [[ $state == on ]]; then op="set"; else op="clear"; fi   
    # sgdisk attribute numbering: 2 = "legacy BIOS bootable" (raw GPT bit 62)
    run sgdisk -A "$n:$op:2" "$dev"
    return 0
  fi
  if [[ $flag == boot ]]; then
    if [[ $state == on ]]; then
      run sgdisk -t "$n:EF00" "$dev"
    else
      warn "sgdisk backend: clearing boot/esp is not supported; leaving partition type unchanged."
    fi
    return 0
  fi
  die "Unsupported flag '$flag' for the sgdisk backend."
}
partition_number_by_name(){
  local dev=$1 name=$2
  init_table_backend
  if [[ $TABLE_BACKEND == parted ]]; then
    { parted -m -s "$dev" print 2>/dev/null || true; } | awk -F: -v x="$name" '$6==x{print $1}' | tail -n1
  else
    { sgdisk -p "$dev" 2>/dev/null || true; } | awk -v x="$name" '
      $1 ~ /^[0-9]+$/ { nm=""; for(i=7;i<=NF;i++) nm=nm (i>7?" ":"") $i; if (nm==x) print $1 }' | tail -n1
  fi
}

device_class(){
  local dev=$1 base=${1##*/} dtype="" tran="" rm="" ro=""
  ro=$(dev_ro "$dev")
  case $base in
    mmcblk[0-9]boot[01]) printf 'eMMC hardware boot area%s' "${ro:+ (RO=$ro)}"; return ;;
    mmcblk[0-9]rpmb) printf 'eMMC RPMB security area'; return ;;
    nvme[0-9]*n[0-9]*) printf 'NVMe SSD'; return ;;
    sd[a-z]*)
      tran=$(dev_tran "$dev")
      case $tran in usb) printf 'USB mass storage';; sata|ata) printf 'SATA drive';; sas) printf 'SAS drive';; *) printf 'SCSI/USB/SATA block device';; esac
      return ;;
    vd[a-z]*|xvd[a-z]*) printf 'Virtual block device'; return ;;
    mmcblk[0-9]*)
      if [[ -r "/sys/block/$base/device/type" ]]; then   
        dtype=$(tr -d '[:space:]' < "/sys/block/$base/device/type" 2>/dev/null || true)
      fi
      rm=$(dev_rm "$dev")
      case ${dtype^^} in
        SD|SDIO) printf 'microSD/SD card';;
        MMC) printf 'eMMC';;
        *) if [[ $rm == 1 ]]; then printf 'probably microSD (removable)'; else printf 'MMC device, type unclear'; fi;;
      esac
      return ;;
  esac
  printf 'Other storage device'
}
dev_tran(){
  local d=$1 r=""
  if have lsblk; then r=$(lsblk -dn -o TRAN "$d" 2>/dev/null | head -n1 || true); fi
  printf '%s' "$r"
}

devices_detailed(){
  local dev size model tran rm ro cls
  printf '%-22s %-30s %-9s %-4s %-4s %-8s %s\n' 'DEVICE' 'CLASS' 'SIZE' 'RM' 'RO' 'TRAN' 'MODEL'
  while IFS= read -r dev; do
    dev_is_disk "$dev" || continue
    size=$(dev_size "$dev"); model=$(dev_model "$dev"); tran=$(dev_tran "$dev")
    rm=$(dev_rm "$dev"); ro=$(dev_ro "$dev"); cls=$(device_class "$dev")
    printf '%-22s %-30s %-9s %-4s %-4s %-8s %s\n' "$dev" "$cls" "$size" "$rm" "$ro" "${tran:--}" "${model:--}"
  done < <(list_block_devs)
}

cmd_status(){
  local only="" show_all=0 dev root_src root_parent label cls n start end size fs name flags path mounts active relevant
  while (($#)); do case $1 in
    -d|--device) (($#>=2)) || die "status: $1 requires an argument"; only=$2; shift 2;;
    -a|--all) show_all=1; shift;; -h|--help) usage; return;; *) die "status: unknown option $1";; esac; done
  if ! have parted && ! have sgdisk; then
    warn "Neither parted nor sgdisk found; partition tables will not be shown."
  fi
  root_src=$(mount_source_for / 2>/dev/null || true)
  if [[ $root_src == /dev/* ]]; then root_src=$(readlink -f "$root_src" 2>/dev/null || printf '%s' "$root_src"); fi
  root_parent=""
  if [[ -n $root_src ]]; then root_parent=$(part_parent "$root_src" 2>/dev/null || true); fi
  printf 'Radxa multiboot status %s\n' "$VERSION"
  printf 'Running root filesystem:    %s\n' "${root_src:-unknown}"
  printf 'Root disk:                  %s\n\n' "${root_parent:-unknown}"
  devices_detailed
  printf '\n'
  local -a disks=()
  if [[ -n $only ]]; then
    disks+=("$(validate_disk "$only")")
  else
    while IFS= read -r dev; do
      dev_is_disk "$dev" || continue
      is_disk_name "$dev" || ((ALL_DEVICES)) || continue
      [[ $(dev_ro "$dev") == 0 ]] || continue
      disks+=("$dev")
    done < <(list_block_devs)
  fi
  for dev in "${disks[@]}"; do
    label=$(disk_label "$dev" 2>/dev/null || true); cls=$(device_class "$dev")
    printf '%s [%s], partition table: %s%s\n' "$dev" "$cls" "${label:-unrecognized}" "$([[ $dev == "$root_parent" ]] && printf '  <-- current root device')"
    if [[ -z $label ]]; then printf '  No readable partition table.\n\n'; continue; fi
    printf '  %-4s %-20s %-12s %-12s %-22s %-18s %s\n' 'NO' 'PARTITION' 'SIZE' 'FSTYPE' 'PARTLABEL' 'FLAGS' 'MOUNTS/STATUS'
    while IFS=: read -r n start end size fs name flags; do
      [[ $n =~ ^[0-9]+$ ]] || continue
      name=${name%;}; flags=${flags%;}; relevant=0
      [[ ${name,,} == *boot* || ${name,,} == *root* ]] && relevant=1
      ((show_all || relevant)) || continue
      path=$(part_path "$dev" "$n")
      mounts=$(dev_mounts "$path" 2>/dev/null | awk 'NF{a[++c]=$0} END{for(i=1;i<=c;i++) printf "%s%s",a[i],(i<c?",":""); printf "\n"}' || true)
      active=""
      if [[ ${name,,} == boot_[ab] ]]; then
        active='Android A/B slot'                      
      elif [[ ${name,,} == *boot* && ${name,,} != *uboot* ]]; then
        if has_flag "$flags" legacy_boot; then active='ACTIVE(legacy_boot)'
        elif has_flag "$flags" boot || has_flag "$flags" esp; then active='ACTIVE(boot/esp)'
        else active='Boot candidate'; fi
      fi
      if [[ $path == "$root_src" ]]; then active="${active:+$active, }RUNNING ROOT"; fi
      printf '  %-4s %-20s %-12s %-12s %-22s %-18s %s%s\n' "$n" "$path" "$size" "${fs:--}" "${name:--}" "${flags:--}" "${mounts:--}" "${active:+ [$active]}"
    done < <(read_partitions "$dev")
    printf '\n'
  done
}

cmd_select(){
  local dev="" part="" flag=auto
  REBOOT=0
  while (($#)); do case $1 in
    -d|--device) dev=$2; shift 2;; -p|--partition) part=$2; shift 2;;
    -f|--flag) flag=$2; shift 2;; -r|--reboot) REBOOT=1; shift;;
    -h|--help) usage; return;; *) die "select: unknown option $1";; esac; done
  dev=$(choose_device "$dev")
  local label
  label=$(disk_label "$dev" 2>/dev/null || true)
  case $flag:$label in
    auto:gpt) flag=legacy_boot;;
    auto:msdos) flag=boot;;
    auto:*) die "Unknown or unreadable partition table on $dev (got: ${label:-none})." ;;
  esac
  [[ $flag == boot || $flag == legacy_boot ]] || die "Flag must be auto, boot or legacy_boot."
  [[ $label == gpt || $flag != legacy_boot ]] || die "legacy_boot is only valid on GPT."
  if [[ $label == gpt && $flag == boot ]]; then
    warn "On GPT, boot is an alias for esp."
    if ((YES)); then die "GPT boot/esp requires interactive confirmation."; fi   
  fi
  local -a nums=() names=() paths=()
  local n name flags size fs i answer selected=""
  while IFS=: read -r n _ _ size fs name flags; do
    [[ $n =~ ^[0-9]+$ ]] || continue
    name=${name//;/}
    [[ ${name,,} == *boot* && ${name,,} != *uboot* ]] || continue
    nums+=("$n"); names+=("$name"); paths+=("$(part_path "$dev" "$n")")
    printf '  %s) %-20s %-12s %-8s flags=%s\n' "$n" "$name" "$size" "$fs" "${flags%;}"
  done < <(read_partitions "$dev")
  ((${#nums[@]})) || die "No boot PARTLABELs found on $dev."
  if [[ -z $part ]]; then read -r -p "Boot partition number: " part; fi
  if [[ ! $part =~ ^[0-9]+$ ]]; then
    part=$(part_number "$(canon "$part")") || die "Cannot derive a partition number from '$part'."   
  fi
  for i in "${!nums[@]}"; do
    if [[ ${nums[$i]} == "$part" ]]; then selected=$i; fi 
  done
  [[ -n $selected ]] || die "Partition is not a boot candidate."
  [[ -b ${paths[$selected]} ]] || die "${paths[$selected]} is missing."
  if [[ ${names[$selected],,} == boot_[ab] ]]; then          # FIX(ANDROID): A/B slots are bootloader-managed
    warn "Android A/B boot slot detected; slot switching is done by the Android bootloader (BCB/misc), not by GPT flags. This change will likely have no effect."
  fi
  local critical src
  for critical in / /boot /boot/efi; do
    src=$(mount_source_for "$critical" 2>/dev/null || true)
    src=${src:+$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")}
    [[ -z $src || $(part_parent "$src" 2>/dev/null || true) != "$dev" || $src == "${paths[$selected]}" ]] || die "$src serves $critical and must not be deactivated."
  done
  printf 'Target: %s (%s), partition %s (%s), flag %s\n' "$dev" "${label:-?}" "$part" "${names[$selected]}" "$flag"
  ((DRY_RUN)) || confirm BOOT
  set_partition_flag "$dev" "$part" "$flag" on
  for i in "${!nums[@]}"; do
    if [[ ${nums[$i]} == "$part" ]]; then continue; fi    
    if has_flag "$(part_flags "$dev" "${nums[$i]}")" "$flag"; then
      set_partition_flag "$dev" "${nums[$i]}" "$flag" off
    fi
  done
  if (( ! DRY_RUN )); then
    if [[ $TABLE_BACKEND == sgdisk ]] && [[ $flag == legacy_boot ]] && [[ $(sgdisk_attr_raw "$part" "$dev") == -1 ]]; then
      warn "sgdisk attribute readout unsupported; skipping verification."
    else
      has_flag "$(part_flags "$dev" "$part")" "$flag" || die "Verification failed."
    fi
  fi
  if ((REBOOT && !DRY_RUN)); then
    if (( ! YES )); then confirm REBOOT; fi
    if ! have reboot; then die "'reboot' not found; please reboot manually."; fi
    run reboot
  fi
  return 0
}

attach_image(){
  local image=$1 loop="" i
  loop=$(losetup --find --show --partscan --read-only "$image" 2>/dev/null) || loop=""
  if [[ -z $loop ]]; then                       # busybox/toybox two-step attach
    loop=$(losetup -f 2>/dev/null) || loop=""
    [[ -n $loop ]] || die "No free loop device found."
    run losetup "$loop" "$image"
  fi
  LOOPS+=("$loop")
  settle
  for i in 1 2 3; do
    if [[ -e ${loop}p1 || -e ${loop}1 ]]; then break; fi
    reread_partitions "$loop"
  done
  [[ -e ${loop}p1 || -e ${loop}1 ]] || die \
    "Loop device $loop exposes no partition nodes. Kernel loop 'max_part' is probably 0 - run 'modprobe loop max_part=8' (or reboot) and retry."
  printf '%s' "$loop"
}
mount_ro(){ local dev=$1 dir=$2; mkdir -p "$dir"; mount -o ro "$dev" "$dir"; MOUNTS+=("$dir"); }

detect_image_parts(){
  local image=$1 n                              
  IMG_PARTS=()
  while IFS=: read -r n _; do
    if [[ $n =~ ^[0-9]+$ ]]; then IMG_PARTS+=("$n"); fi
  done < <(read_partitions "$image")
  ((${#IMG_PARTS[@]}==1 || ${#IMG_PARTS[@]}==2 || ${#IMG_PARTS[@]}==5)) \
    || die "Only images with 1, 2 or 5 partitions are supported (Android A/B or 'super'-layout images are not supported)."
  case ${#IMG_PARTS[@]} in 1) IMG_BOOT=0; IMG_ROOT=1;; 2) IMG_BOOT=1; IMG_ROOT=2;; 5) IMG_BOOT=4; IMG_ROOT=5;; esac
}

os_release_field(){
  local root=$1 key=$2 f v=""
  for f in "$root/etc/os-release" "$root/usr/lib/os-release"; do
    [[ -f $f ]] || continue
    v=$(awk -F= -v k="$key" '$1==k{gsub(/"/,"",$2); print $2; exit}' "$f" 2>/dev/null)
    if [[ -n $v ]]; then printf '%s' "$v"; return 0; fi
  done
  return 0
}
detect_os_from_root(){
  local root=$1 id="" like="" pretty="" d
  id=$(os_release_field "$root" ID); like=$(os_release_field "$root" ID_LIKE); pretty=$(os_release_field "$root" PRETTY_NAME)
  case ${id,,} in
    armbian) printf 'Armbian'; return 0;; dietpi) printf 'DietPi'; return 0;;
    libreelec) printf 'LibreELEC'; return 0;; manjaro) printf 'Manjaro'; return 0;;
    slarm64) printf 'slarm64'; return 0;; ubuntu) printf 'ubuntu'; return 0;;
    kali) printf 'Kali'; return 0;; lakka) printf 'Lakka'; return 0;;
    batocera) printf 'Batocera'; return 0;; recalbox) printf 'Recalbox'; return 0;;
    lineage) printf 'LineageOS'; return 0;;
    android) printf 'Android'; return 0;; openwrt) printf 'OpenWrt'; return 0;;
    radxa) printf 'RadxaOS'; return 0;;
    debian)
      if [[ -f $root/etc/dietpi.txt || -d $root/boot/dietpi ]]; then printf 'DietPi'; return 0; fi
      if [[ $pretty == *Radxa* ]]; then printf 'RadxaOS'; return 0; fi
      printf 'debian'; return 0;;
  esac
  if [[ -f $root/etc/openwrt_release ]]; then
    d=$(awk -F= '$1=="DISTRIB_ID"{gsub(/"/,"",$2); print $2; exit}' "$root/etc/openwrt_release" 2>/dev/null)
    case ${d,,} in *friendly*) printf 'FriendlyWrt';; *) printf 'OpenWrt';; esac
    return 0
  fi
  if [[ -f $root/etc/dietpi.txt ]]; then printf 'DietPi'; return 0; fi
  if [[ -f $root/etc/recalbox.conf ]]; then printf 'Recalbox'; return 0; fi
  if [[ -f $root/system/build.prop || -d $root/system/app ]]; then printf 'Android'; return 0; fi
  case ${like,,} in
    *ubuntu*) printf 'ubuntu'; return 0;;
    *debian*) if [[ $pretty == *Radxa* ]]; then printf 'RadxaOS'; else printf 'debian'; fi; return 0;;
    *armbian*) printf 'Armbian'; return 0;;
  esac
  if [[ $pretty == *Armbian* ]]; then printf 'Armbian'; return 0; fi
  if [[ $pretty == *Radxa* ]]; then printf 'RadxaOS'; return 0; fi
  printf 'unknown'
}
detect_os(){
  local image=${1##*/} root=${2:-} os=unknown
  case $image in
    *[Aa]rmbian*) os=Armbian;; *Diet[Pp]i*) os=DietPi;; *LibreELEC*) os=LibreELEC;;
    *Manjaro*) os=Manjaro;; *slarm64*) os=slarm64;; *[Uu]buntu*) os=ubuntu;;
    *[Dd]ebian*) os=debian;; *[Kk]ali*) os=Kali;; *[Ll]akka*) os=Lakka;;
    *[Bb]atocera*) os=Batocera;; *[Rr]ecalbox*) os=Recalbox;;
    *[Ff]riendly[Ww]rt*) os=FriendlyWrt;; *[Oo]pen[Ww]rt*) os=OpenWrt;;
    *[Aa]ndroid*|*lineage*) os=Android;; *Radxa*|*radxa*) os=RadxaOS;;
  esac
  if [[ $os == unknown && -n $root ]]; then os=$(detect_os_from_root "$root"); fi
  printf '%s' "$os"
}

# Content-level Android support: recognise Android GPT layouts and warn before
# destructive operations. Non-fatal, best-effort; silently skips without a backend.
android_disk_warning(){
  local dev=$1 found
  if ! have parted && ! have sgdisk; then return 0; fi
  found=$({ read_partitions "$dev" 2>/dev/null || true; } | awk -F: '
    tolower($6) ~ /^(super|userdata|misc|metadata|cache|efs|persist|modem|vbmeta|vbmeta_[ab]|dtbo|odm|odm_[ab]|system|system_[ab]|vendor|vendor_[ab]|product|product_[ab])$/ {print $6; exit}')
  if [[ -n $found ]]; then
    warn "$dev contains an Android-style partition '$found'; destructive commands will destroy that installation."
  fi
}

print_table(){
  init_table_backend
  if [[ $TABLE_BACKEND == parted ]]; then
    parted -s "$1" unit MiB print
  else
    sgdisk -p "$1"
  fi
}
cmd_image_info(){
  local image=""
  while (($#)); do case $1 in -i|--image-file) image=$2; shift 2;; -h|--help) usage; return;; *) die "image-info: unknown option $1";; esac; done
  [[ -f $image ]] || die "Image not found: $image"
  print_table "$image" || die "Cannot read the partition table from $image."
  detect_image_parts "$image"
  ((DRY_RUN)) && { log "Dry run: mount inspection skipped."; return 0; }
  if ! am_root || ! have losetup || ! have mount; then  
    warn "Need root plus losetup and mount for filesystem inspection; showing partition table only."
    printf 'Detected OS (filename guess): %s\n' "$(detect_os "$image")"
    return 0
  fi
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/radxa-mb.XXXXXX")
  local loop root boot os
  loop=$(attach_image "$image")
  root="$WORKDIR/root"
  mount_ro "$(part_path "$loop" "$IMG_ROOT")" "$root"
  if ((IMG_BOOT)); then
    boot="$WORKDIR/boot"
    mount_ro "$(part_path "$loop" "$IMG_BOOT")" "$boot"
  else
    boot="$root/boot"
  fi
  os=$(detect_os "$image" "$root")
  printf '\nDetected OS: %s\n' "$os"
  if [[ -f $boot/extlinux/extlinux.conf ]]; then
    printf '\n--- extlinux.conf ---\n'
    sed -n '1,200p' "$boot/extlinux/extlinux.conf"
  fi
  if [[ -f $root/etc/fstab ]]; then
    printf '\n--- fstab ---\n'
    sed -n '1,200p' "$root/etc/fstab"
  fi
  return 0   
}

disk_sectors(){
  local b=${1##*/} s=""
  if [[ -r "/sys/block/$b/size" ]]; then read -r s < "/sys/block/$b/size"; printf '%s' "$s"; return 0; fi   
  if have blockdev; then s=$(blockdev --getsz "$1" 2>/dev/null || blockdev --getsize "$1" 2>/dev/null || true); fi
  printf '%s' "$s"
}
zero_tail(){
  local dev=$1 secs
  secs=$(disk_sectors "$dev")
  if ! [[ $secs =~ ^[0-9]+$ ]]; then warn "Cannot determine size of $dev; skipping tail wipe."; return 0; fi
  if (( secs > 2048 )); then run dd if=/dev/zero of="$dev" bs=512 seek=$((secs-2048)) count=2048 conv=fsync,notrunc; fi
  return 0
}
cmd_uboot_backup(){
  local dev="" out=""
  while (($#)); do case $1 in -d|--device) dev=$2; shift 2;; -o|--output) out=$2; shift 2;; *) die "uboot-backup: unknown option $1";; esac; done
  root_required
  dev=$(validate_disk "$dev")
  if [[ -z $out ]]; then out="first16M_${dev##*/}_$(date +%Y%m%d-%H%M%S).img"; fi
  check_uboot_source "$dev"
  run dd if="$dev" of="$out" bs=1M count=16 "${DD_STATUS[@]}" conv=fsync
}
cmd_uboot_write(){
  local dev="" src=""
  while (($#)); do case $1 in -d|--device) dev=$2; shift 2;; -u|--uboot-file) src=$2; shift 2;; *) die "uboot-write: unknown option $1";; esac; done
  root_required; dev=$(validate_disk "$dev"); check_uboot_source "$src"; assert_not_system_disk "$dev"
  android_disk_warning "$dev"                   # FIX(ANDROID): warn on Android targets
  warn "Writes sectors 64 to 32767 on $dev."
  ((DRY_RUN)) || high_risk_confirm "$dev"
  run dd if="$src" of="$dev" bs=512 skip=64 seek=64 count=32704 "${DD_STATUS[@]}" conv=fsync,notrunc
}
cmd_uboot_zero(){
  local dev=""
  while (($#)); do case $1 in -d|--device) dev=$2; shift 2;; *) die "uboot-zero: unknown option $1";; esac; done
  root_required; dev=$(validate_disk "$dev"); assert_not_system_disk "$dev"
  android_disk_warning "$dev"                   
  ((DRY_RUN)) || high_risk_confirm "$dev"
  run dd if=/dev/zero of="$dev" bs=512 seek=64 count=32704 "${DD_STATUS[@]}" conv=fsync,notrunc
}
cmd_init(){
  local dev="" src=""
  while (($#)); do case $1 in -d|--device) dev=$2; shift 2;; -u|--uboot-file) src=$2; shift 2;; *) die "init: unknown option $1";; esac; done
  root_required; dev=$(validate_disk "$dev"); assert_not_system_disk "$dev"
  android_disk_warning "$dev"                   
  if [[ -n $src ]]; then need_sig_tools; check_uboot_source "$src"; fi
  ((DRY_RUN)) || high_risk_confirm "$dev"
  init_table_backend
  if [[ $TABLE_BACKEND == parted ]]; then
    if have wipefs; then
      run wipefs -a "$dev"
    else
      warn "wipefs not available; zeroing first/last 1 MiB to clear old signatures."
      run dd if=/dev/zero of="$dev" bs=1M count=1 conv=fsync,notrunc
      if (( ! DRY_RUN )); then zero_tail "$dev"; fi
    fi
    run parted -s "$dev" mklabel gpt
    run parted -s -a none "$dev" unit s mkpart idbloader 64 8063
    run parted -s -a none "$dev" unit s mkpart uboot 16384 24575
    run parted -s -a none "$dev" unit s mkpart trust 24576 32767
  else
    run sgdisk -o "$dev"
    # FIX(SGDISK): explicit partition numbers, one invocation per partition
    run sgdisk -a 1 -n 1:64:8063     -c 1:idbloader -t 1:8300 "$dev"
    run sgdisk -a 1 -n 2:16384:24575 -c 2:uboot     -t 2:8300 "$dev"
    run sgdisk -a 1 -n 3:24576:32767 -c 3:trust     -t 3:8300 "$dev"
  fi
  if [[ -n $src ]]; then run dd if="$src" of="$dev" bs=512 skip=64 seek=64 count=32704 "${DD_STATUS[@]}" conv=fsync,notrunc; fi
  if (( ! DRY_RUN )); then reread_partitions "$dev"; fi
  return 0
}

create_partition(){
  local dev=$1 size=$2 name=$3 fs=$4 n p end start next maxend
  init_table_backend
  if [[ $TABLE_BACKEND == parted ]]; then
    if [[ $(disk_label "$dev") != gpt ]]; then
      die "$dev has no GPT label; named partitions require GPT (run init first)."   # FIX: mkpart with a name fails on msdos
    fi
    end=$({ parted -m -s "$dev" unit MiB print free 2>/dev/null || true; } | awk -F: '$1=="" && $5=="free"{gsub(/MiB/,"",$3); e=$3} END{print int(e)}')
    if ! [[ $end =~ ^[0-9]+$ ]]; then die "No free space region detected on $dev."; fi
    start=$((end-size))
    if (( start <= 16 )); then die "Not enough space for $name."; fi
    run parted -s -a optimal "$dev" unit MiB mkpart "$name" "$fs" "$start" "$end"
  else
    # FIX(SGDISK): deterministic append after the highest existing partition;
    # sgdisk -E is a resize operation, not a free-space query, and bare '0'
    # numbering is ambiguous across sgdisk versions.
    maxend=$({ sgdisk -p "$dev" 2>/dev/null || true; } | awk '$1 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {if ($3+0>max) max=$3+0} END{print max+0}')
    if ! [[ $maxend =~ ^[0-9]+$ ]]; then maxend=32; fi
    start=$((maxend+1))
    next=$({ sgdisk -p "$dev" 2>/dev/null || true; } | awk '$1 ~ /^[0-9]+$/ {if ($1+0>m) m=$1+0} END{print m+1}')
    if ! [[ $next =~ ^[0-9]+$ ]]; then next=1; fi
    run sgdisk -n "$next:$start:+$((size*2048))" -c "$next:$name" -t "$next:8300" "$dev"
  fi
  ((DRY_RUN)) && { printf '%s' DRYRUN; return 0; }
  reread_partitions "$dev"
  n=$(partition_number_by_name "$dev" "$name")
  if [[ -z $n ]]; then die "New partition '$name' not found on $dev."; fi
  p=$(part_path "$dev" "$n")
  if [[ ! -b $p ]]; then die "New partition $p is missing."; fi
  printf '%s' "$p"
}
make_fs(){
  local type=$1 dev=$2 label=$3
  if [[ $type == ext2 ]] && have mkfs.ext2; then run mkfs.ext2 -F -L "$label" "$dev"; return 0; fi
  if [[ $type == ext4 ]] && have mkfs.ext4; then run mkfs.ext4 -F -L "$label" "$dev"; return 0; fi
  if have mke2fs; then run mke2fs -F -t "$type" -L "$label" "$dev"; return 0; fi
  die "No tool available to create $type filesystems (install e2fsprogs)."
}
blkid_tag(){
  local d=$1 t=$2 v=""
  if have blkid; then
    v=$(blkid -s "$t" -o value "$d" 2>/dev/null || true)
    if [[ -z $v ]]; then v=$({ blkid "$d" 2>/dev/null || true; } | sed -n "s/.*[[:space:]]$t=\"\([^\"]*\)\".*/\1/p"); fi
  fi
  printf '%s' "$v"
}
rewrite_configs(){
  local os=$1 bootmnt=$2 rootmnt=$3 buuid=$4 ruuid=$5 custom=${6:-}   # FIX: unused PARTUUID params dropped
  local ext="$bootmnt/extlinux/extlinux.conf" fstab="$rootmnt/etc/fstab"
  mkdir -p "$bootmnt/extlinux"
  if [[ -n $custom ]]; then cp -f -- "$custom" "$ext"; fi
  if [[ -f $ext ]]; then
    sed "$SED_E" -i "s#root=(UUID=|PARTUUID=)?[^ ]+#root=UUID=$ruuid#g; s#boot=(UUID=)?[^ ]+#boot=UUID=$buuid#g; s#disk=(UUID=)?[^ ]+#disk=UUID=$ruuid#g" "$ext"
  else
    case $os in
      Armbian|DietPi) cat >"$ext" <<EOF
LABEL $os
  LINUX /Image
  INITRD /uInitrd
  APPEND root=UUID=$ruuid rw rootwait fsck.repair=yes
EOF
      ;;
      LibreELEC) cat >"$ext" <<EOF
LABEL LibreELEC
  LINUX /KERNEL
  APPEND boot=UUID=$buuid disk=UUID=$ruuid quiet
EOF
      ;;
      *) die "No extlinux.conf available. For $os, please use --extlinux FILE.";;
    esac
  fi
  if [[ ! -f $fstab ]]; then : >"$fstab"; fi
  sed "$SED_E" -i '/^[^#].*[[:space:]]\/[[:space:]]/d; /^[^#].*[[:space:]]\/boot[[:space:]]/d' "$fstab"
  printf 'UUID=%s / ext4 defaults 0 1\n' "$ruuid" >>"$fstab"
  printf 'UUID=%s /boot ext2 defaults 0 2\n' "$buuid" >>"$fstab"
  return 0
}
cmd_install(){
  local image="" dev="" bdev="" rdev="" bp="" rp="" bsize=256 rsize=4096 os="" ext="" lock=0 activate=0
  while (($#)); do case $1 in
    -i|--image-file) image=$2; shift 2;; -d|--device) dev=$2; shift 2;; -b|--boot-dev) bdev=$2; shift 2;; -r|--root-dev) rdev=$2; shift 2;;
    -B|--boot-part) bp=$2; shift 2;; -R|--root-part) rp=$2; shift 2;; --boot-size) bsize=$2; shift 2;; --root-size) rsize=$2; shift 2;;
    --os-name) os=$2; shift 2;; --extlinux) ext=$2; shift 2;; --lock-space) lock=1; shift;; --activate) activate=1; shift;;
    *) die "install: unknown option $1";; esac; done
  root_required
  [[ -f $image ]] || die "Image not found: $image"
  [[ -z $ext || -f $ext ]] || die "extlinux file not found: $ext"
  [[ $bsize =~ ^[0-9]+$ && $rsize =~ ^[0-9]+$ ]] || die "Sizes must be whole MiB values."
  if [[ -n $dev ]]; then bdev=$dev; rdev=$dev; fi
  bdev=$(validate_disk "$bdev"); rdev=$(validate_disk "$rdev")
  detect_image_parts "$image"
  if [[ -z $os ]]; then os=$(detect_os "$image"); fi
  [[ $os != unknown || -n $ext ]] || die "OS unknown; use --os-name and, if needed, --extlinux."
  local bootname="boot_${os//[^A-Za-z0-9._-]/_}" rootname="root_${os//[^A-Za-z0-9._-]/_}" bootpart rootpart
  if [[ -n $bp ]]; then
    bootpart=$(part_path "$bdev" "$bp")
    [[ -b $bootpart ]] || die "$bootpart is missing"
  else
    bootpart=$(create_partition "$bdev" "$bsize" "$bootname" ext2)
  fi
  if [[ -n $rp ]]; then
    rootpart=$(part_path "$rdev" "$rp")
    [[ -b $rootpart ]] || die "$rootpart is missing"
  else
    rootpart=$(create_partition "$rdev" "$rsize" "$rootname" ext4)
  fi
  printf 'Image=%s OS=%s Boot=%s Root=%s\n' "$image" "$os" "$bootpart" "$rootpart"
  android_disk_warning "$bdev"                  # FIX(ANDROID): shown in dry-run too
  if [[ $rdev != "$bdev" ]]; then android_disk_warning "$rdev"; fi
  ((DRY_RUN)) && { log "Dry run finished; no filesystems or files were modified."; return 0; }
  confirm INSTALL
  [[ -z $(mount_target_of "$bootpart") ]] || die "$bootpart is mounted."
  [[ -z $(mount_target_of "$rootpart") ]] || die "$rootpart is mounted."
  make_fs ext2 "$bootpart" "$bootname"
  make_fs ext4 "$rootpart" "$rootname"
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/radxa-mb.XXXXXX")
  local loop ib="$WORKDIR/imgboot" ir="$WORKDIR/imgroot" ob="$WORKDIR/boot" or="$WORKDIR/root"
  loop=$(attach_image "$image")
  mount_ro "$(part_path "$loop" "$IMG_ROOT")" "$ir"
  if ((IMG_BOOT)); then
    mount_ro "$(part_path "$loop" "$IMG_BOOT")" "$ib"
  else
    ib="$ir/boot"
  fi
  mkdir -p "$ob" "$or"
  mount "$bootpart" "$ob"; MOUNTS+=("$ob")
  mount "$rootpart" "$or"; MOUNTS+=("$or")
  if [[ $os == unknown ]]; then
    os=$(detect_os_from_root "$ir")
    if [[ $os != unknown ]]; then log "Detected OS from image contents: $os"; fi
  fi
  cp -a "$ir"/. "$or"/
  rm -rf "${or:?}/boot"/*                       
  cp -a "$ib"/. "$ob"/
  local buuid ruuid
  buuid=$(blkid_tag "$bootpart" UUID)
  ruuid=$(blkid_tag "$rootpart" UUID)
  if [[ -z $buuid || -z $ruuid ]]; then die "Could not read filesystem UUIDs (need a working blkid)."; fi
  rewrite_configs "$os" "$ob" "$or" "$buuid" "$ruuid" "$ext"
  sync
  if ((lock)); then create_partition "$rdev" 16 border ext4 >/dev/null; fi
  if ((activate)); then
    local actnum
    actnum=$(part_number "$bootpart") || die "Cannot derive partition number from $bootpart."  
    set_partition_flag "$bdev" "$actnum" legacy_boot on
  fi
  log "Installation complete. Boot=$bootpart Root=$rootpart"
  return 0
}

# --- per-command capability gates -------------------------------------------
check_caps(){
  case $1 in
    devices) ;;
    status|select|image-info) need_table_backend ;;
    init) need dd; need_table_backend ;;
    install) need dd; need_table_backend; need losetup; need mount; need umount; need blkid; need_any mkfs.ext2 mke2fs; need_any mkfs.ext4 mke2fs ;;
    uboot-backup) need dd; need_sig_tools ;;
    uboot-write) need dd; need_sig_tools ;;
    uboot-zero) need dd ;;
  esac
}

# Parse global options only before command.
while (($#)); do case $1 in
  -n|--dry-run) DRY_RUN=1; shift;;
  -y|--yes) YES=1; shift;;
  -v|--verbose) VERBOSE=1; shift;;
  --all-devices) ALL_DEVICES=1; shift;;
  -h|--help) usage; exit 0;;
  --version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0;;
  -*) die "Unknown global option: $1";;
  *) break;;
esac; done
(($#)) || { usage; exit 0; }
CMD=$1; shift

probe_tools
init_dd_status
init_sed_flags
init_hex_tool

# FIX(ANDROID): refuse to run ON a booted Android for every real command.
if [[ $CMD != help ]]; then
  if [[ ${RADXA_MB_ALLOW_ANDROID:-0} == 1 ]]; then
    warn "RADXA_MB_ALLOW_ANDROID=1 set; skipping the Android refusal (unsupported, for testing only)."
  elif android_runtime_check; then
    die "Running on a booted Android is not supported. Android kernels commonly restrict loop-device partition scanning and direct block access, and the required tools are absent. To manage Android disks/partitions, boot a rescue Linux (SD/USB), attach the disk, and run $PROG from there."
  fi
fi

# Core floor (all available as BusyBox applets).
need readlink; need awk; need sed; need grep; need sort; need cat; need date; need mktemp; need sleep
need cp; need sync; need mkdir; need rm; need head

check_caps "$CMD"
if ((VERBOSE)); then
  local_bb="no"
  if have busybox; then local_bb="yes"; fi
  log "busybox applets detected: $local_bb"
  log "optional tools found: $(tools_present)"
  log "dd progress support: ${DD_STATUS[*]:-none}"
  if have parted || have sgdisk; then init_table_backend; log "partition-table backend: $TABLE_BACKEND"; fi
  log "hex tool: ${HEX_TOOL:-none}"
  log "sed extended-regex flag: $SED_E"
fi

case $CMD in
  devices) devices_detailed;;
  status) cmd_status "$@";;
  select) root_required; cmd_select "$@";;
  image-info) cmd_image_info "$@";;
  init) cmd_init "$@";;
  install) cmd_install "$@";;
  uboot-backup) cmd_uboot_backup "$@";;
  uboot-write) cmd_uboot_write "$@";;
  uboot-zero) cmd_uboot_zero "$@";;
  help) usage;;
  *) die "Unknown command: $CMD";;
esac
