#!/usr/bin/env bash
# =============================================================================
# tar2img.sh  ―  gentoo-rootfs.tar.gz をディスクイメージ (.img) に変換する
#
# 使い方:
#   sudo bash tar2img.sh [オプション]
#
# オプション:
#   -o <output>   出力imgファイル名 (デフォルト: ./build/gentoo.img)
#   -s <size>     imgサイズ GB単位 (デフォルト: 8)
#   -h            このヘルプを表示
#
# 依存コマンド: dd, parted, mkfs.vfat, mkfs.ext4, mount, grub-install (任意)
#
# 生成されたimgはそのままUSBに書き込める:
#   sudo dd if=gentoo.img of=/dev/sdX bs=4M status=progress && sync
#   または: sudo bmaptool copy gentoo.img /dev/sdX
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
# デフォルト設定
# ─────────────────────────────────────────────
ROOTFS_TAR="./build/gentoo-rootfs.tar.gz"
DONE_FLAG="./build/.build_done"
OUTPUT_IMG="./build/gentoo.img"
IMG_SIZE_GB=8
MOUNT_ROOT="/mnt/gentoo_img"
LOGFILE="./build/tar2img.log"

# ─────────────────────────────────────────────
# オプション解析
# ─────────────────────────────────────────────
usage() {
    sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while getopts "o:s:h" opt; do
    case $opt in
        o) OUTPUT_IMG="$OPTARG" ;;
        s) IMG_SIZE_GB="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ─────────────────────────────────────────────
# ログ設定
# ─────────────────────────────────────────────
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1
echo "============================================"
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') tar2img.sh 開始"
echo "============================================"

# ─────────────────────────────────────────────
# 0. 事前確認
# ─────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] root権限が必要です: sudo bash tar2img.sh"
    exit 1
fi

for cmd in dd parted mkfs.vfat mkfs.ext4 losetup mount tar blkid; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[ERROR] 必要なコマンドが見つかりません: $cmd"
        exit 1
    fi
done

if [[ ! -f "$ROOTFS_TAR" ]]; then
    echo "[ERROR] ${ROOTFS_TAR} が存在しません。"
    if [[ ! -f "$DONE_FLAG" ]]; then
        echo "  ビルドがまだ完了していない可能性があります。"
        echo "  docker logs -f Docker_Linux で進捗を確認してください。"
    fi
    exit 1
fi

if [[ ! -f "$DONE_FLAG" ]]; then
    echo "[WARN] ビルド完了フラグ (${DONE_FLAG}) がありません。"
    read -rp "  ビルドが中途半端かもしれません。続行しますか？ (yes/no): " WARN_CONFIRM
    [[ "$WARN_CONFIRM" == "yes" ]] || { echo "中止しました。"; exit 0; }
fi

echo ""
echo "========================================================"
echo "  出力ファイル : ${OUTPUT_IMG}"
echo "  イメージサイズ: ${IMG_SIZE_GB} GB"
echo "  rootfs      : ${ROOTFS_TAR}"
echo "========================================================"
read -rp "続行しますか？ (yes と入力して Enter): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "中止しました。"; exit 0; }

# ─────────────────────────────────────────────
# ループデバイス管理
# ─────────────────────────────────────────────
LOOP_DEV=""

cleanup() {
    echo "[INFO] クリーンアップ中..."
    umount -R "${MOUNT_ROOT}/dev"      2>/dev/null || true
    umount -R "${MOUNT_ROOT}/sys"      2>/dev/null || true
    umount    "${MOUNT_ROOT}/proc"     2>/dev/null || true
    umount    "${MOUNT_ROOT}/boot/efi" 2>/dev/null || true
    umount    "${MOUNT_ROOT}"          2>/dev/null || true
    if [[ -n "$LOOP_DEV" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
        echo "[INFO] ループデバイス解放: $LOOP_DEV"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────
# 1. 空のimgファイル作成
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') imgファイル作成中 (${IMG_SIZE_GB}GB)..."
mkdir -p "$(dirname "$OUTPUT_IMG")"

# 既存ファイルがあれば確認
if [[ -f "$OUTPUT_IMG" ]]; then
    read -rp "[WARN] ${OUTPUT_IMG} が既に存在します。上書きしますか？ (yes/no): " OW_CONFIRM
    [[ "$OW_CONFIRM" == "yes" ]] || { echo "中止しました。"; exit 0; }
fi

dd if=/dev/zero of="$OUTPUT_IMG" bs=1G count="${IMG_SIZE_GB}" status=progress
echo "[INFO] imgファイル作成完了: $(du -h "$OUTPUT_IMG" | cut -f1)"

# ─────────────────────────────────────────────
# 2. ループデバイスにアタッチ
# ─────────────────────────────────────────────
echo "[INFO] ループデバイスにアタッチ中..."
LOOP_DEV=$(losetup --find --show "$OUTPUT_IMG")
echo "[INFO] ループデバイス: $LOOP_DEV"

# ─────────────────────────────────────────────
# 3. パーティション作成（GPT: EFI 512MiB + root 残り全部）
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') パーティション作成中..."

parted -s "$LOOP_DEV" \
    mklabel gpt \
    mkpart EFI  fat32 1MiB 513MiB \
    set 1 esp on \
    mkpart root ext4  513MiB 100%

# パーティションをループデバイスとして認識させる
losetup -d "$LOOP_DEV"
LOOP_DEV=$(losetup --find --show --partscan "$OUTPUT_IMG")
echo "[INFO] パーティションスキャン済みループデバイス: $LOOP_DEV"

sleep 1

# デバイス名判定（loopXp1 形式）
EFI_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

if [[ ! -b "$EFI_PART" ]] || [[ ! -b "$ROOT_PART" ]]; then
    echo "[ERROR] パーティションデバイスが見つかりません: $EFI_PART / $ROOT_PART"
    losetup -l
    exit 1
fi

# ─────────────────────────────────────────────
# 4. フォーマット
# ─────────────────────────────────────────────
echo "[INFO] フォーマット中..."
mkfs.vfat -F32 -n "EFI"    "$EFI_PART"
mkfs.ext4 -F   -L "gentoo" "$ROOT_PART"

# ─────────────────────────────────────────────
# 5. マウント
# ─────────────────────────────────────────────
echo "[INFO] マウント中..."
mkdir -p "$MOUNT_ROOT"
mount "$ROOT_PART" "$MOUNT_ROOT"
mkdir -p "$MOUNT_ROOT/boot/efi"
mount "$EFI_PART"  "$MOUNT_ROOT/boot/efi"

# ─────────────────────────────────────────────
# 6. rootfs 展開
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') rootfs 展開中（数分かかります）..."
tar xpf "$ROOTFS_TAR" \
    --xattrs-include='*.*' \
    --numeric-owner \
    -C "$MOUNT_ROOT" \
    --strip-components=1

# ─────────────────────────────────────────────
# 7. fstab 生成（UUID使用）
# ─────────────────────────────────────────────
echo "[INFO] fstab 生成中..."

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
EFI_UUID=$(blkid  -s UUID -o value "$EFI_PART")

cat > "$MOUNT_ROOT/etc/fstab" << FSTAB_EOF
# <fs>                                  <mountpoint>  <type>  <opts>            <dump> <pass>
UUID=${ROOT_UUID}  /          ext4    defaults,noatime  0      1
UUID=${EFI_UUID}   /boot/efi  vfat    defaults          0      2
FSTAB_EOF

echo "  ROOT UUID: $ROOT_UUID"
echo "  EFI  UUID: $EFI_UUID"

# ─────────────────────────────────────────────
# 8. bind マウント（chroot内GRUB用）
# ─────────────────────────────────────────────
echo "[INFO] bind マウント中..."
mount --types proc /proc "$MOUNT_ROOT/proc"
mount --rbind      /sys  "$MOUNT_ROOT/sys"
mount --make-rslave      "$MOUNT_ROOT/sys"
mount --rbind      /dev  "$MOUNT_ROOT/dev"
mount --make-rslave      "$MOUNT_ROOT/dev"
cp /etc/resolv.conf "$MOUNT_ROOT/etc/resolv.conf"

# ─────────────────────────────────────────────
# 9. chroot 内で GRUB インストール
# ─────────────────────────────────────────────
if command -v grub-install &>/dev/null || [[ -x "${MOUNT_ROOT}/usr/sbin/grub-install" ]]; then
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') GRUB インストール中..."

    chroot "$MOUNT_ROOT" /bin/bash << 'GRUB_EOF'
set -e
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=gentoo \
    --removable
grub-mkconfig -o /boot/grub/grub.cfg
echo "[CHROOT] GRUB 完了"
GRUB_EOF
else
    echo "[WARN] grub-install が見つかりません。GRUBのインストールをスキップします。"
    echo "  後からUSBに書き込んだ後にchrootして手動インストールしてください。"
fi

# ─────────────────────────────────────────────
# 10. アンマウント & ループデバイス解放
# ─────────────────────────────────────────────
trap - EXIT
echo "[INFO] アンマウント中..."
umount -R "${MOUNT_ROOT}/dev"      || true
umount -R "${MOUNT_ROOT}/sys"      || true
umount    "${MOUNT_ROOT}/proc"     || true
umount    "${MOUNT_ROOT}/boot/efi"
umount    "${MOUNT_ROOT}"
sync

echo "[INFO] ループデバイス解放中..."
losetup -d "$LOOP_DEV"
LOOP_DEV=""

# ─────────────────────────────────────────────
# 完了メッセージ
# ─────────────────────────────────────────────
IMG_ACTUAL_SIZE=$(du -h "$OUTPUT_IMG" | cut -f1)

echo ""
echo "============================================"
echo "[DONE] $(date '+%Y-%m-%d %H:%M:%S')"
echo "ディスクイメージが完成しました！"
echo ""
echo "  ファイル: ${OUTPUT_IMG}"
echo "  サイズ  : ${IMG_ACTUAL_SIZE}"
echo ""
echo "USBへの書き込み方法:"
echo "  # ddを使う場合"
echo "  sudo dd if=${OUTPUT_IMG} of=/dev/sdX bs=4M status=progress && sync"
echo ""
echo "  # bmaptool を使う場合（高速・推奨）"
echo "  sudo bmaptool copy ${OUTPUT_IMG} /dev/sdX"
echo ""
echo "  # QEMUで直接テストする場合"
echo "  qemu-system-x86_64 -m 2G -drive file=${OUTPUT_IMG},format=raw -bios /usr/share/ovmf/OVMF.fd"
echo "============================================"
