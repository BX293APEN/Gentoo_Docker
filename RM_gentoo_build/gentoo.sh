#!/bin/bash
# =============================================================================
# gentoo.sh  ―  実機Ubuntu上で夜間バックグラウンド実行用
# 役割: stage3取得 → rootfs構築 → gentoo-rootfs.tar.gz 生成
#
# 実行方法（寝る前に）:
#   chmod +x gentoo.sh
#   sudo nohup bash gentoo.sh > /build/gentoo-build.log 2>&1 &
#   echo "PID: $!"
#
# 進捗確認:
#   tail -f /build/gentoo-build.log
# =============================================================================

set -euo pipefail

ROOT_PASSWORD="password"
BUILD_DIR="/build/gentoo-rootfs"
OUTPUT_TAR="/build/gentoo-rootfs.tar.gz"
DONE_FLAG="/build/.build_done"
STAGE3_URL_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc"
LOGFILE="/build/gentoo-build.log"

mkdir -p /build
exec > >(tee -a "$LOGFILE") 2>&1

echo "============================================"
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') ビルド開始"
echo "============================================"

if [[ -f "$DONE_FLAG" ]]; then
    echo "[INFO] ビルド済みフラグを検出。スキップします。"
    exit 0
fi

# ─────────────────────────────────────────────
# 0. 必要ツール確認・インストール
# ─────────────────────────────────────────────
apt-get update -q
apt-get install -y --no-install-recommends \
    wget curl tar xz-utils \
    systemd-container \
    dosfstools e2fsprogs parted \
    ca-certificates

# ─────────────────────────────────────────────
# 1. 作業ディレクトリ準備
# ─────────────────────────────────────────────
mkdir -p "$BUILD_DIR"

# ─────────────────────────────────────────────
# 2. stage3 ダウンロード（最新を自動取得）
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') stage3 取得中..."

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
# 3. 展開
# ─────────────────────────────────────────────
if [[ ! -f "${BUILD_DIR}/bin/bash" ]]; then
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 展開中..."
    tar xpf "$STAGE3_PATH" \
        --xattrs-include='*.*' \
        --numeric-owner \
        -C "$BUILD_DIR"
fi

# ─────────────────────────────────────────────
# 4. chroot内スクリプト生成
# ─────────────────────────────────────────────
cat > "$BUILD_DIR/tmp/inside-chroot.sh" << INNEREOF
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

emerge-webrsync
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

rc-update add dhcpcd default

echo "[CHROOT] タイムゾーン設定"
echo "Asia/Tokyo" > /etc/timezone
emerge --config sys-libs/timezone-data

echo "[CHROOT] ロケール設定"
echo "ja_JP.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set ja_JP.UTF-8
env-update && source /etc/profile

echo "[CHROOT] hostname"
echo "gentoo" > /etc/hostname

echo "[CHROOT] root パスワード"
echo "root:${ROOT_PASSWORD}" | chpasswd

echo "[CHROOT] 完了"
INNEREOF

chmod +x "$BUILD_DIR/tmp/inside-chroot.sh"
cp /etc/resolv.conf "$BUILD_DIR/etc/resolv.conf"

# ─────────────────────────────────────────────
# 5. systemd-nspawn でビルド
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') systemd-nspawn ビルド開始（数時間かかります）"

systemd-nspawn \
    --directory="$BUILD_DIR" \
    --capability=CAP_NET_ADMIN \
    /bin/bash /tmp/inside-chroot.sh

# ─────────────────────────────────────────────
# 6. tar.gz 作成
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') tar.gz 作成中..."
tar czpf "$OUTPUT_TAR" \
    --one-file-system \
    -C /build \
    gentoo-rootfs

date '+%Y-%m-%d %H:%M:%S' > "$DONE_FLAG"

echo ""
echo "============================================"
echo "[DONE] $(date '+%Y-%m-%d %H:%M:%S')"
echo "出力: ${OUTPUT_TAR}"
echo "サイズ: $(du -sh ${OUTPUT_TAR} | cut -f1)"
echo "朝起きたら: sudo bash morning.sh"
echo "============================================"
