# JetsonホストのPodman・CDIセットアップ

Jetson Linux 36.5 / JetPack 6.2.2のUbuntu 22.04では、標準APTリポジトリからPodman 3.4.4がインストールされます。この版はNVIDIAが推奨するCDIデバイス指定（`--device nvidia.com/gpu=all`）に必要なPodman 4.1以降の要件を満たしません。

このリポジトリでは、Podman 6系へのデータ移行と依存関係の変更を避け、5系の保守版である **Podman 5.8.5** を使用します。UbuntuのPodmanパッケージは依存ツールと設定を提供するため削除せず、ソースからビルドしたPodmanを`/usr/local`へ追加して優先します。この方法なら`/usr/local`側を無効化することでAPT版へ戻せます。

以下はARM64のJetsonホスト上で実行します。Podmanの公式なUbuntu向け最新版パッケージは提供されていないため、[公式のソースビルド手順](https://podman.io/docs/installation#building-from-source)を基にしています。

### 1. 既存データの確認と停止

アップグレード時にrootless Podmanのデータベースが移行されます。実行中のコンテナを停止し、現在の状態を記録してください。

```bash
podman ps -a
podman images
podman pod stop --all
podman stop --all
podman info > "$HOME/podman-info-before-upgrade.txt"
```

永続化が必要なデータは、各コンテナのボリュームまたはバインドマウント先を別途バックアップします。Podmanのストレージ全体を直接コピーする場合は、すべてのPodmanプロセスを停止してから行ってください。

### 2. ビルド依存パッケージ

```bash
sudo apt-get update
sudo apt-get install -y \
  btrfs-progs \
  gcc \
  git \
  go-md2man \
  iptables \
  libapparmor-dev \
  libassuan-dev \
  libbtrfs-dev \
  libc6-dev \
  libdevmapper-dev \
  libglib2.0-dev \
  libgpg-error-dev \
  libgpgme-dev \
  libprotobuf-c-dev \
  libprotobuf-dev \
  libseccomp-dev \
  libselinux1-dev \
  libsqlite3-dev \
  libsystemd-dev \
  make \
  pkg-config \
  protobuf-compiler \
  slirp4netns \
  uidmap
```

### 3. Goの準備

Podman 5.8.5はGo 1.25以上を必要とします。Ubuntu 22.04のGoは古いため、公式ARM64バイナリをビルド専用に`/opt`へ展開します。

```bash
cd /tmp
curl -fLO https://go.dev/dl/go1.25.12.linux-arm64.tar.gz
echo '8b5884aef89600aef5b0b051fb971f11f49bb996521e911f30f02a66884f7bd2  go1.25.12.linux-arm64.tar.gz' | sha256sum -c -
sudo test ! -e /opt/go1.25.12
sudo mkdir -p /opt/go1.25.12
sudo tar -C /opt/go1.25.12 --strip-components=1 -xzf go1.25.12.linux-arm64.tar.gz
export PATH="/opt/go1.25.12/bin:$PATH"
go version
```

### 4. OCI runtimeとmonitorの更新

Podman本体だけを更新すると、Ubuntu 22.04の古い`crun`と`conmon`が残ります。`crun`は公式ARM64静的バイナリを使用します。`conmon`の公式静的バイナリはjournald対応を含まないため、Jetson上でソースからビルドします。

```bash
cd /tmp
curl -fL https://github.com/containers/crun/releases/download/1.28/crun-1.28-linux-arm64 -o crun
chmod 0755 crun
./crun --version
sudo install -D -m 0755 crun /usr/local/bin/crun

mkdir -p "$HOME/src"
cd "$HOME/src"
git clone --depth 1 --branch v2.2.1 https://github.com/containers/conmon.git conmon-2.2.1
make -C conmon-2.2.1
sudo make -C conmon-2.2.1 podman PREFIX=/usr/local
/usr/local/libexec/podman/conmon --version
```

ビルドログに`-D USE_JOURNALD=1`と`-lsystemd`が含まれることを確認してください。これらがない場合は`libsystemd-dev`をインストールしてから`make clean`、`make`をやり直します。

新しいruntimeを明示する設定を追加します。

```bash
sudo install -d -m 0755 /etc/containers/containers.conf.d
sudo tee /etc/containers/containers.conf.d/20-local-runtime.conf >/dev/null <<'EOF'
[engine]
runtime = "crun"
conmon_path = ["/usr/local/libexec/podman/conmon"]

[engine.runtimes]
crun = ["/usr/local/bin/crun"]
EOF
```

### 5. NetavarkとAardvark DNSの導入

Podman 5では旧CNI backendが廃止されているため、Netavarkが必要です。NetavarkとAardvark DNSはmajor/minorを一致させ、ここでは1.17系を使用します。配布済みバイナリはx86-64用なので、Jetson上でソースからビルドします。

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.86.0
. "$HOME/.cargo/env"

mkdir -p "$HOME/src"
cd "$HOME/src"
git clone --depth 1 --branch v1.17.2 https://github.com/containers/netavark.git
git clone --depth 1 --branch v1.17.1 https://github.com/containers/aardvark-dns.git

make -C netavark
sudo make -C netavark install PREFIX=/usr/local
make -C aardvark-dns
sudo make -C aardvark-dns install PREFIX=/usr/local
```

Ubuntu 22.04には`pasta`がないため、rootless networkには既存の`slirp4netns`を使います。

```bash
mkdir -p "$HOME/.config/containers/containers.conf.d"
cat > "$HOME/.config/containers/containers.conf.d/20-rootless-network.conf" <<'EOF'
[network]
default_rootless_network_cmd = "slirp4netns"
EOF
```

本リポジトリは`network_mode: host`を使用していますが、Netavarkも導入しておくことで通常のbridge networkを使用するコンテナにも対応できます。

### 6. Podman 5.8.5のビルドと切り替え

```bash
export PATH="/opt/go1.25.12/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$HOME/src"
cd "$HOME/src"
git clone --depth 1 --branch v5.8.5 https://github.com/containers/podman.git podman-5.8.5
cd podman-5.8.5
make
sudo env PATH="/opt/go1.25.12/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  make install PREFIX=/usr/local
hash -r
```

`sudo`は通常、呼び出し元ユーザーの`PATH`を引き継がず、`secure_path`へ置き換えます。そのため、インストール処理でもMakefileが使用するGoのパスを明示しています。

`/usr/local/bin`が`/usr/bin`より先にあることと、5.8.5が選択されたことを確認します。

```bash
command -v podman
podman --version
podman info --format 'runtime={{.Host.OCIRuntime.Name}} network={{.Host.NetworkBackend}} rootless={{.Host.Security.Rootless}}'
```

期待値は次のとおりです。

```text
/usr/local/bin/podman
podman version 5.8.5
runtime=crun network=netavark rootless=true
```

### 7. rootlessデータベースの移行と動作確認

Podmanを使用するユーザー自身で実行します。`sudo podman`ではありません。

```bash
podman system migrate --migrate-db --new-runtime crun
podman run --rm docker.io/library/ubuntu:22.04 true
podman-compose --version
```

### 8. Jetson GPU用CDI deviceの登録

NVIDIA Container Toolkitが検出したJetsonのGPUデバイスとドライバーライブラリをCDI specとして保存します。

```bash
sudo install -d -m 0755 /etc/cdi
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list
```

一覧に`nvidia.com/gpu=all`が表示されることを確認し、PodmanがCDI deviceを解決できることをテストします。

```bash
podman create --name cdi-check --device nvidia.com/gpu=all docker.io/library/ubuntu:22.04 true
podman rm cdi-check
```

JetPackまたはNVIDIAドライバーを更新した場合は、同じ`nvidia-ctk cdi generate`コマンドを再実行してspecを更新してください。

### ロールバック

新しいPodmanを無効化し、UbuntuのAPT版へ戻す場合は次を実行します。

```bash
sudo mv /usr/local/bin/podman /usr/local/bin/podman.disabled
sudo mv /etc/containers/containers.conf.d/20-local-runtime.conf /etc/containers/containers.conf.d/20-local-runtime.conf.disabled
hash -r
command -v podman
podman --version
```

Podman 5で作成・変更したコンテナmetadataはPodman 3.4から参照できない場合があります。ロールバック後は、アップグレード前のバックアップから復元するか、コンテナを再作成してください。ワークスペースなどのバインドマウントされたデータはPodmanのmetadata移行対象ではありません。

## 参考資料

- [Podman installation](https://podman.io/docs/installation)
- [Podman releases](https://github.com/containers/podman/releases)
- [NVIDIA Container Toolkit: CDI support](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html)
- [NVIDIA PyTorch for Jetson release notes](https://docs.nvidia.com/deeplearning/frameworks/install-pytorch-jetson-platform-release-notes/pytorch-jetson-rel.html)
- [Netavark](https://github.com/containers/netavark)
- [Aardvark DNS](https://github.com/containers/aardvark-dns)
