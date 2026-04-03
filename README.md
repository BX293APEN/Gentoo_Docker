# Gentoo Linux ビルド on Docker

寝ている間に Docker 上で Gentoo Linux をビルドし、
朝起きたら USB に焼いてすぐ起動できるプロジェクトです。

---

## 📁 ファイル構成

```
.
├── compose.yml                 # Docker Compose 設定
├── Dockerfile                  # Ubuntu 24.04 ベースのビルド環境
├── .env                        # 環境変数（CPUコア数・パス等）
├── gentoo_docker.sh            # コンテナ内ビルドスクリプト（エントリーポイント）
├── morning.sh                  # 朝起きたら実行：USB に展開して起動可能にする
└── build/                      # ビルド成果物（gitignore推奨）
    ├── gentoo-rootfs/          # chroot 作業ディレクトリ
    ├── gentoo-rootfs.tar.gz    # 完成した rootfs（morning.sh が使用）
    └── .build_done             # ビルド完了フラグ

```

---

## 🌙 寝る前：ビルド開始

```bash
docker compose up --build -d
```

進捗確認（別ターミナル）:
```bash
docker logs -f Docker_Linux
```

ビルドには **4〜8時間** かかります（CPU・回線速度による）。

---

## ☀️ 朝起きたら：USB に書き込む

### 1. ビルド完了確認
```bash
docker logs Docker_Linux | tail -5
# [DONE] ... ビルド完了！ と出ていればOK
```

### 2. 実行

```bash
sudo bash morning.sh
```

⚠️ 指定した USB デバイスは **完全に消去**されます。

---

## 🖥️ 起動

1. USB を抜いてターゲット PC に差す
2. BIOS/UEFI の Boot Order を USB 優先に設定
3. 起動！
   - ログイン: `root`
   - パスワード: `password`（`.env` の `ROOT_PASSWORD` で変更可）

---

## 🔁 再ビルドしたい場合

```bash
rm ./build/.build_done
docker compose up --build -d
```

---

## ⚙️ カスタマイズ

| 変更したい項目 | 変更箇所 |
|---|---|
| CPU コア数 | `compose.yml` の `cpus:` |
| root パスワード | `gentoo_docker.sh` の `ROOT_PASSWORD` |
| USE フラグ | `gentoo_docker.sh` 内 `make.conf` の `USE=` |
| タイムゾーン | `.env` の `TIME_ZONE` |
| ミラー | `gentoo_docker.sh` 内 `GENTOO_MIRRORS=` |

---

## 🐛 トラブルシューティング

**ビルドが途中で止まった**
```bash
docker compose down
rm ./build/.build_done   # フラグ削除
docker compose up -d     # 再開（stage3 展開済みならスキップされる）
```

**morning.sh が "ビルド完了フラグなし" と言う**
→ `docker logs Docker_Linux` でエラーを確認してください。
