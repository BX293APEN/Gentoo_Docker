#!/usr/bin/env bash
# =============================================================================
# gentoo_docker.sh  ―  Docker コンテナ内エントリーポイント
# 役割: stage3取得 → chroot でビルド → /build/gentoo-rootfs.tar.gz 出力
#
# 進捗確認（別ターミナルで）:
#   docker logs -f Docker_Linux
#
# ホストUbuntuは一切変更されません。
# =============================================================================

set -euo pipefail

ROOT_PASSWORD="password"
BUILD_DIR="/build/gentoo-rootfs"
OUTPUT_TAR="/build/gentoo-rootfs.tar.gz"
DONE_FLAG="/build/.build_done"
STAGE3_URL_BASE="https://ftp.iij.ad.jp/pub/linux/gentoo/releases/amd64/autobuilds/current-stage3-amd64-openrc"

echo "============================================"
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Gentoo ビルド開始"
echo "  出力先: ${OUTPUT_TAR}"
echo "============================================"

# 既にビルド済みならスキップ
if [[ -f "$DONE_FLAG" ]]; then
    echo "[INFO] ビルド済みフラグを検出。スキップします。"
    echo "  削除して再ビルドする場合: rm ${DONE_FLAG}"
    exit 0
fi

# ─────────────────────────────────────────────
# 1. 作業ディレクトリ準備
# ─────────────────────────────────────────────
mkdir -p "$BUILD_DIR"

# ─────────────────────────────────────────────
# 2. stage3 最新ファイルを自動取得
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') stage3 ファイル名を取得中..."

STAGE3_FILE=$(wget -qO- "${STAGE3_URL_BASE}/" \
    | grep -oP 'stage3-amd64-openrc-[0-9]{8}T[0-9]{6}Z\.tar\.xz' \
    | head -1)

if [[ -z "$STAGE3_FILE" ]]; then
    echo "[ERROR] stage3ファイル名の取得に失敗しました。"
    exit 1
fi

STAGE3_PATH="/build/${STAGE3_FILE}"
echo "[INFO] ダウンロード: ${STAGE3_FILE}"
wget -c "${STAGE3_URL_BASE}/${STAGE3_FILE}" -O "$STAGE3_PATH"

# ─────────────────────────────────────────────
# 3. stage3 展開（既に展開済みならスキップ）
# ─────────────────────────────────────────────
if [[ ! -f "${BUILD_DIR}/bin/bash" ]]; then
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 展開中..."
    tar xpf "$STAGE3_PATH" \
        --xattrs-include='*.*' \
        --numeric-owner \
        -C "$BUILD_DIR"
else
    echo "[INFO] stage3 展開済みをスキップ"
fi

# ─────────────────────────────────────────────
# 4. chroot 用仮想FS マウント
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 仮想FS マウント中..."

mount_chroot() {
    mountpoint -q "${BUILD_DIR}/proc" || mount --types proc  /proc "${BUILD_DIR}/proc"
    mountpoint -q "${BUILD_DIR}/sys"  || { mount --rbind /sys "${BUILD_DIR}/sys"; mount --make-rslave "${BUILD_DIR}/sys"; }
    mountpoint -q "${BUILD_DIR}/dev"  || { mount --rbind /dev "${BUILD_DIR}/dev"; mount --make-rslave "${BUILD_DIR}/dev"; }
}

cleanup() {
    echo "[INFO] クリーンアップ中..."
    umount -R "${BUILD_DIR}/dev"  2>/dev/null || true
    umount -R "${BUILD_DIR}/sys"  2>/dev/null || true
    umount    "${BUILD_DIR}/proc" 2>/dev/null || true
}
trap cleanup EXIT

mount_chroot
cp /etc/resolv.conf "${BUILD_DIR}/etc/resolv.conf"

# ─────────────────────────────────────────────
# 5. chroot 内スクリプト生成
# ─────────────────────────────────────────────
cat > "${BUILD_DIR}/tmp/inside-chroot.sh" << INNEREOF
#!/bin/bash
set -euo pipefail

echo "[CHROOT] 環境初期化"
env-update && source /etc/profile

echo "[CHROOT] make.conf 設定"
cat > /etc/portage/make.conf << 'MAKEEOF'
COMMON_FLAGS="-O2 -pipe -march=x86-64"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j$(nproc) -l$(nproc)"
USE="X wayland alsa pulseaudio"
GENTOO_MIRRORS="https://distfiles.gentoo.org"
ACCEPT_LICENSE="*"
MAKEEOF

echo "[CHROOT] emerge-webrsync"
emerge-webrsync

echo "[CHROOT] プロファイル設定"
eselect profile set default/linux/amd64/17.1

echo "[CHROOT] @world アップデート（最長工程）"
emerge --verbose --update --deep --newuse --with-bdeps=y @world

echo "[CHROOT] カーネル・必須パッケージ インストール"
emerge \
    sys-kernel/gentoo-kernel \
    net-misc/dhcpcd \
    app-admin/sudo \
    sys-boot/grub \
    app-editors/vim \
    app-editors/nano

echo "[CHROOT] dhcpcd 自動起動登録"
rc-update add dhcpcd default

echo "[CHROOT] タイムゾーン設定"
echo "Asia/Tokyo" > /etc/timezone
emerge --config sys-libs/timezone-data

echo "[CHROOT] ロケール設定"
echo "ja_JP.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set ja_JP.UTF-8
env-update && source /etc/profile

echo "[CHROOT] hostname 設定"
echo "gentoo" > /etc/hostname

echo "[CHROOT] root パスワード設定"
echo "root:${ROOT_PASSWORD}" | chpasswd

echo "[CHROOT] 完了"
INNEREOF

chmod +x "${BUILD_DIR}/tmp/inside-chroot.sh"

# ─────────────────────────────────────────────
# 6. chroot 実行
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') chroot ビルド開始（数時間かかります）"
chroot "$BUILD_DIR" /bin/bash /tmp/inside-chroot.sh

# ─────────────────────────────────────────────
# 7. アンマウント
# ─────────────────────────────────────────────
cleanup
trap - EXIT

# ─────────────────────────────────────────────
# 8. tar.gz 作成
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') tar.gz 作成中..."
tar czpf "$OUTPUT_TAR" \
    --one-file-system \
    -C /build \
    gentoo-rootfs

# ─────────────────────────────────────────────
# 9. 完了フラグ
# ─────────────────────────────────────────────
date '+%Y-%m-%d %H:%M:%S' > "$DONE_FLAG"

echo ""
echo "============================================"
echo "[DONE] $(date '+%Y-%m-%d %H:%M:%S') ビルド完了！"
echo "  出力: ${OUTPUT_TAR}"
echo "  サイズ: $(du -sh ${OUTPUT_TAR} | cut -f1)"
echo ""
echo "朝起きたら:"
echo "  sudo bash morning.sh"
echo "============================================"
