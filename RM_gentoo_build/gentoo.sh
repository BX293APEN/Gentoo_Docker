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

set -eo pipefail

ROOT_PASSWORD="password"
BUILD_DIR="/build/gentoo-rootfs"
OUTPUT_TAR="/build/gentoo-rootfs.tar.gz"
DONE_FLAG="/build/.build_done"
STAGE3_URL_BASE="https://ftp.iij.ad.jp/pub/linux/gentoo/releases/amd64/autobuilds/current-stage3-amd64-openrc"
STAGE3_LATEST_TXT="latest-stage3-amd64-openrc.txt"
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
# 2. stage3 最新ファイル名を自動取得
#    latest-stage3-*.txt を読んでファイル名を解決する
#    （PGP Clearsigned 形式に対応: stage3-*.tar.xz 行を直接抽出）
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') stage3 最新ファイル名を取得中..."

STAGE3_FILE=$(wget -qO- "${STAGE3_URL_BASE}/${STAGE3_LATEST_TXT}" \
    | grep '^stage3-.*\.tar\.xz' \
    | head -1 \
    | awk '{print $1}')

if [[ -z "$STAGE3_FILE" ]]; then
    echo "[ERROR] stage3ファイル名の取得に失敗しました。"
    echo "  URL: ${STAGE3_URL_BASE}/${STAGE3_LATEST_TXT}"
    exit 1
fi

echo "[INFO] 最新 stage3: ${STAGE3_FILE}"

# ─────────────────────────────────────────────
# 3. stage3 ダウンロード（再開対応 -c オプション）
# ─────────────────────────────────────────────
STAGE3_PATH="/build/${STAGE3_FILE}"

if [[ -f "$STAGE3_PATH" ]]; then
    echo "[INFO] キャッシュ済み: ${STAGE3_PATH}、ダウンロードをスキップ"
else
    echo "[INFO] ダウンロード中: ${STAGE3_FILE}"
    wget -c "${STAGE3_URL_BASE}/${STAGE3_FILE}" -O "${STAGE3_PATH}.tmp"
    mv "${STAGE3_PATH}.tmp" "$STAGE3_PATH"
fi

# ─────────────────────────────────────────────
# 4. 展開
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
# 5. chroot 内スクリプト生成
# ─────────────────────────────────────────────
cat > "$BUILD_DIR/tmp/inside-chroot.sh" << 'INNEREOF'
#!/bin/bash
# -u を外す: source /etc/profile.d/*.sh 内の未定義変数で即死するのを防ぐ
set -eo pipefail

# debuginfod.sh 等が DEBUGINFOD_URLS を参照する前にデフォルト値を与えておく
export DEBUGINFOD_URLS=""

echo "[CHROOT] make.conf 設定（env-update より先に行う）"
cat > /etc/portage/make.conf << 'MAKEEOF'
COMMON_FLAGS="-O2 -pipe -march=x86-64"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j$(nproc) -l$(nproc)"
USE="X wayland alsa pulseaudio"
GENTOO_MIRRORS="https://ftp.iij.ad.jp/pub/linux/gentoo"
ACCEPT_LICENSE="*"
MAKEEOF

echo "[CHROOT] 環境初期化"
env-update && source /etc/profile

echo "[CHROOT] emerge-webrsync"
emerge-webrsync

echo "[CHROOT] emerge --sync (完全更新)"
emerge --sync

echo "[CHROOT] プロファイル設定"
eselect profile set default/linux/amd64/23.0

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
echo "root:__ROOT_PASSWORD__" | chpasswd

echo "[CHROOT] 完了"
INNEREOF

# ROOT_PASSWORD を実際の値で置換
sed -i "s/__ROOT_PASSWORD__/${ROOT_PASSWORD}/g" "$BUILD_DIR/tmp/inside-chroot.sh"

chmod +x "$BUILD_DIR/tmp/inside-chroot.sh"
cp /etc/resolv.conf "$BUILD_DIR/etc/resolv.conf"

# ─────────────────────────────────────────────
# 6. systemd-nspawn でビルド
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') systemd-nspawn ビルド開始（数時間かかります）"

systemd-nspawn \
    --directory="$BUILD_DIR" \
    --capability=CAP_NET_ADMIN \
    /bin/bash /tmp/inside-chroot.sh

# ─────────────────────────────────────────────
# 7. tar.gz 作成
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
