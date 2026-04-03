#!/usr/bin/env bash
# =============================================================================
# gentoo_docker.sh  ―  Docker コンテナ内エントリーポイント
# 役割: stage3取得 → chroot でビルド → /build/gentoo-rootfs.tar.gz 出力
#
# 設定は .env を編集してください。スクリプト本体は変更不要です。
#
# 進捗確認 (別ターミナルで):
#   docker logs -f Docker_Linux
# =============================================================================

set -eo pipefail

# ─────────────────────────────────────────────
# .env → compose.yml environment → ここで受け取る
# 未設定時のデフォルト値を定義
# ─────────────────────────────────────────────
ROOT_PASSWORD="${ROOT_PASSWORD:-password}"
MIRROR="${MIRROR:-https://ftp.iij.ad.jp/pub/linux/gentoo}"
# クォートを除去して純粋な値にする（.env で "amd64" のように書かれた場合の対策）
STAGE3_ARCH="${STAGE3_ARCH:-amd64}"
STAGE3_ARCH="${STAGE3_ARCH//\"/}"
STAGE3_ARCH="${STAGE3_ARCH//\'/}"
VERSION="23.0"

LOCALE="${LOCALE:-ja_JP.UTF-8 UTF-8}"
LOCALE_NAME="${LANG:-ja_JP.UTF-8}"

TZ="${TZ:-Asia/Tokyo}"

WS="${WS:-build}"
BUILD_DIR="/${WS}/gentoo-rootfs"
OUTPUT_TAR="/${WS}/gentoo-rootfs.tar.gz"
FLAG_DIR="/${WS}/FLAGS"
DONE_FLAG="${FLAG_DIR}/.build_done"

STAGE3_URL_BASE="${MIRROR}/releases/${STAGE3_ARCH}/autobuilds/current-stage3-${STAGE3_ARCH}-openrc"
STAGE3_LATEST_TXT="latest-stage3-${STAGE3_ARCH}-openrc.txt"

echo "============================================"
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Gentoo ビルド開始"
echo "  ミラー  : ${MIRROR}"
echo "  アーキ  : ${STAGE3_ARCH}"
echo "  ロケール: ${LOCALE_NAME}"
echo "  タイムゾーン: ${TZ}"
echo "  出力先  : ${OUTPUT_TAR}"
echo "============================================"

if [[ -f "$DONE_FLAG" ]]; then
    echo "[INFO] ビルド済みフラグを検出。スキップします。"
    echo "  削除して再ビルドする場合: rm ${DONE_FLAG}"
    exit 0
fi

mkdir -p "$BUILD_DIR"
mkdir -p "${FLAG_DIR}"
chmod 777 -R "${FLAG_DIR}"

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

STAGE3_PATH="/${WS}/${STAGE3_FILE}"

if [[ -f "$STAGE3_PATH" ]]; then
    echo "[INFO] キャッシュ済み: ${STAGE3_PATH}、ダウンロードをスキップ"
else
    echo "[INFO] ダウンロード中: ${STAGE3_FILE}"
    wget -c "${STAGE3_URL_BASE}/${STAGE3_FILE}" -O "${STAGE3_PATH}.tmp"
    mv "${STAGE3_PATH}.tmp" "$STAGE3_PATH"
fi

if [[ ! -f "${BUILD_DIR}/bin/bash" ]]; then
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 展開中..."
    tar xpf "$STAGE3_PATH" \
        --xattrs-include='*.*' \
        --numeric-owner \
        -C "$BUILD_DIR"
else
    echo "[INFO] stage3 展開済みをスキップ"
fi

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

cat > "${BUILD_DIR}/tmp/inside-chroot.sh" << 'INNEREOF'
#!/bin/bash
set -eo pipefail

export DEBUGINFOD_URLS=""

echo "[CHROOT] make.conf 設定"
NPROC=__CPU_CORE__
cat > /etc/portage/make.conf << MAKEEOF
COMMON_FLAGS="-O2 -pipe -march=__ARCH__"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j${NPROC} -l${NPROC}"
USE="X wayland alsa pulseaudio"
GENTOO_MIRRORS="__MIRROR__"
ACCEPT_LICENSE="*"
MAKEEOF

echo "[CHROOT] 環境初期化"
env-update && source /etc/profile

rm -f /var/db/repos/gentoo/metadata/timestamp.*
mkdir -p /var/db/repos/gentoo/

if [[ ! -f "/etc/portage/repos.conf" ]]; then
    echo "[CHROOT] emerge-webrsync"
    emerge-webrsync
fi

# ─────────────────────────────────────────────
# emerge --sync リトライループ
# profiles.desc が生成されるまで最大 SYNC_MAX_RETRY 回試行
# ─────────────────────────────────────────────
PROFILES_DESC="/var/db/repos/gentoo/profiles/profiles.desc"
SYNC_MAX_RETRY=5
SYNC_RETRY_WAIT=30
SYNC_TRY=0

until [[ -f "${PROFILES_DESC}" ]]; do
    SYNC_TRY=$(( SYNC_TRY + 1 ))
    if (( SYNC_TRY > SYNC_MAX_RETRY )); then
        echo "[ERROR] emerge --sync が ${SYNC_MAX_RETRY} 回失敗しました。中断します。"
        exit 1
    fi

    echo "[CHROOT] emerge --sync (試行 ${SYNC_TRY}/${SYNC_MAX_RETRY})"
    emerge --sync || true   # 失敗しても until 条件で判定するので exit させない

    if [[ ! -f "${PROFILES_DESC}" ]]; then
        echo "[WARN] profiles.desc が未生成。${SYNC_RETRY_WAIT}秒後にリトライします..."
        sleep "${SYNC_RETRY_WAIT}"
    fi
done

echo "[CHROOT] emerge --sync 完了 (試行 ${SYNC_TRY} 回)"

echo "[CHROOT] プロファイル設定"

# ─────────────────────────────────────────────
# eselect を使わず profiles.desc を直接パースして ln -snf する
# eselect は /etc/portage/make.profile が profiles.desc の既知エントリと
# 一致しないと "Failed to get a list of valid profiles" で死ぬため、
# make.profile に直接リンクを張る（eselect profile set の内部実装と等価）
# ─────────────────────────────────────────────
PROFILES_DESC="/var/db/repos/gentoo/profiles/profiles.desc"

echo "[CHROOT][DEBUG] make.profile の現在のリンク先:"
ls -la /etc/portage/make.profile 2>/dev/null || echo "(存在しません)"

# profiles.desc のフォーマット: <relpath> <arch> <status>
# 優先: __STAGE3_ARCH__/__VERSION__ の標準プロファイル
# 次点: __STAGE3_ARCH__ の標準プロファイル（versionが見つからない場合）
# profiles.desc フォーマット: <arch>  <relpath>  <status>  → パスは $2
PROFILE_RELPATH=$(grep "default/linux/__STAGE3_ARCH__/__VERSION__" "${PROFILES_DESC}" \
    | grep -v 'split-usr\|selinux\|hardened\|musl\|x32' \
    | head -1 \
    | awk '{print $2}')

if [[ -z "${PROFILE_RELPATH}" ]]; then
    echo "[CHROOT][WARN] __VERSION__ プロファイルが見つからず。安定版標準プロファイルにフォールバック"
    PROFILE_RELPATH=$(grep "default/linux/__STAGE3_ARCH__/" "${PROFILES_DESC}" \
        | grep -v 'split-usr\|selinux\|hardened\|musl\|x32\|developer\|desktop\|gnome\|plasma\|systemd' \
        | head -1 \
        | awk '{print $2}')
fi

if [[ -z "${PROFILE_RELPATH}" ]]; then
    echo "[ERROR] プロファイルが見つかりませんでした。profiles.desc の内容:"
    cat "${PROFILES_DESC}"
    exit 1
fi

PROFILE_ABS="/var/db/repos/gentoo/profiles/${PROFILE_RELPATH}"
echo "[CHROOT] プロファイルを設定: ${PROFILE_ABS}"
ln -snf "${PROFILE_ABS}" /etc/portage/make.profile

echo "[CHROOT][DEBUG] 設定後のプロファイル:"
ls -la /etc/portage/make.profile

# ─────────────────────────────────────────────
# @world アップデート
# --with-bdeps=y を除去（初回フルビルドでは依存が膨大になり失敗しやすい）
# --keep-going 追加（一部パッケージ失敗でビルド全体が止まるのを防ぐ）
# ─────────────────────────────────────────────
echo "[CHROOT] @world アップデート (最長工程)"
emerge \
    --verbose \
    --update \
    --deep \
    --newuse \
    --keep-going \
    @world

echo "[CHROOT] カーネル・必須パッケージ インストール"
emerge \
    sys-kernel/gentoo-kernel \
    net-misc/dhcpcd \
    app-admin/sudo \
    sys-boot/grub \
    app-editors/vim \
    app-editors/nano \
    dev-vcs/git

if [[ ! -f "/etc/portage/repos.conf" ]]; then
    mkdir -p /etc/portage/repos.conf
    mkdir -p /var/db/repos/gentoo
    rm -rf /var/db/repos/gentoo/*
    chown -R portage:portage /var/db/repos/gentoo

    cat > /etc/portage/repos.conf/gentoo.conf << GITSYNCEOF
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-uri = https://github.com/gentoo-mirror/gentoo.git
sync-depth = 1
sync-git-verify-commit-signature = yes
sync-openpgp-key-path = /usr/share/openpgp-keys/gentoo-release.asc
auto-sync = yes

GITSYNCEOF

    echo "[CHROOT] emerge --sync (git更新)"
    emerge --sync
fi

echo "[CHROOT] dhcpcd 自動起動登録"
rc-update add dhcpcd default

echo "[CHROOT] タイムゾーン設定"
echo "__TZ__" > /etc/timezone
emerge --config sys-libs/timezone-data

echo "[CHROOT] ロケール設定"
echo "__LOCALE__" >> /etc/locale.gen
locale-gen
eselect locale set __LOCALE_NAME__
env-update && source /etc/profile

echo "[CHROOT] hostname 設定"
echo "gentoo" > /etc/hostname

echo "[CHROOT] root パスワード設定"
echo "root:__ROOT_PASSWORD__" | chpasswd

echo "[CHROOT] 完了"
INNEREOF

sed -i \
    -e "s|__ROOT_PASSWORD__|${ROOT_PASSWORD}|g" \
    -e "s|__MIRROR__|${MIRROR}|g" \
    -e "s|__ARCH__|${ARCH}|g" \
    -e "s|__TZ__|${TZ}|g" \
    -e "s|__LOCALE__|${LOCALE}|g" \
    -e "s|__LOCALE_NAME__|${LOCALE_NAME}|g" \
    -e "s|__STAGE3_ARCH__|${STAGE3_ARCH}|g" \
    -e "s|__VERSION__|${VERSION}|g" \
    -e "s|__CPU_CORE__|${CPU_CORE}|g" \
    "${BUILD_DIR}/tmp/inside-chroot.sh"

chmod +x "${BUILD_DIR}/tmp/inside-chroot.sh"

echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') chroot ビルド開始 (数時間かかります)"
chroot "$BUILD_DIR" /bin/bash /tmp/inside-chroot.sh

cleanup
trap - EXIT

echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') tar.gz 作成中..."
tar czpf "$OUTPUT_TAR" \
    --one-file-system \
    -C "/${WS}" \
    gentoo-rootfs

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
