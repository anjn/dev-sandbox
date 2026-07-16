# dev-sandbox

ROCmまたはNVIDIA Jetson上で動作するAI開発用サンドボックスコンテナです。Podmanを使用し、ホストに合わせてPyTorchベースイメージとGPUデバイスを切り替えます。

## 使い方

コンテナ内で編集するworkspaceへ移動して起動します。ROCmとJetsonはホストから自動判定されます。

```bash
cd /path/to/workspace
/path/to/dev-sandbox/up
/path/to/dev-sandbox/exec bash
/path/to/dev-sandbox/down
```

### 追加ディレクトリのmount

`up`の`-v`または`--volume`を繰り返し指定すると、workspace以外のホストディレクトリもbind mountできます。コンテナ側パスを省略した場合は、ホストの絶対パスと同じ場所へread-writeでmountします。

```bash
# ホストと同じ絶対パスへmount
/path/to/dev-sandbox/up -v /data/models

# コンテナ側の別パスへread-onlyでmount
/path/to/dev-sandbox/up -v /data/models:/models:ro

# 複数指定
/path/to/dev-sandbox/up \
  -v /data/models:/models:ro \
  --volume="$HOME/cache:/cache:rw"
```

同一パスへread-onlyでmountする場合は、中央のパスを空にします。

```bash
/path/to/dev-sandbox/up -v /data/models::ro
```

追加mountはその`up`呼び出しだけに適用され、次回へ保存されません。次回も必要な場合は同じ`-v`を指定してください。指定なしで`up`し直すと追加mountは外れます。sourceは既存ディレクトリに限定し、コンテナ側の相対パス、パス中の`:`、同じtargetの重複、およびworkspaceやSSH設定を隠すmountは拒否されます。

自動判定を上書きする場合は`SANDBOX_PLATFORM`へ`rocm`または`jetson`を指定します。

```bash
SANDBOX_PLATFORM=jetson /path/to/dev-sandbox/up
```

JetsonではJetPack 6.2対応のNVIDIA PyTorch 25.02 iGPUイメージを使用します。初回起動前に、下記ドキュメントに従ってPodmanとGPU用CDI deviceを準備してください。

JetsonイメージのUbuntu ports mirrorは、デフォルトで山形大学のmirrorを使用します。別のmirrorでbuildする場合は`UBUNTU_PORTS_MIRROR` build argumentを指定します。ROCmイメージの`archive.ubuntu.com`は置換されません。

```bash
podman build \
  --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.02-py3-igpu \
  --build-arg UBUNTU_PORTS_MIRROR=https://ports.ubuntu.com/ubuntu-ports \
  --tag dev-sandbox-jetson \
  /path/to/dev-sandbox
```

## SSH接続

コンテナは公開鍵認証のSSH serverを起動します。秘密鍵は接続元だけに保持し、接続を許可する公開鍵をホストの`~/.config/dev-sandbox/authorized_keys`へ登録します。このファイルはすべてのworkspaceで共通です。

接続元に専用鍵がなければ、パスフレーズなしのEd25519鍵を作成します。

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/dev-sandbox
```

接続元とPodmanホストが同じ場合は、直接登録できます。

```bash
/path/to/dev-sandbox/add-ssh-key ~/.ssh/dev-sandbox.pub
```

別マシンの接続元からは、既存のホストSSH接続を使って公開鍵だけを送信できます。

```bash
cat ~/.ssh/dev-sandbox.pub | \
  ssh user@jetson-host /path/to/dev-sandbox/add-ssh-key
```

`up`は`22000`-`22999`からworkspace用の空きポートを自動割り当て、SSHコマンドを表示します。同じworkspaceの再起動では同じポートを再利用します。

```bash
cd /path/to/workspace
/path/to/dev-sandbox/up
/path/to/dev-sandbox/ssh-info jetson-host
ssh -p 22000 -i ~/.ssh/dev-sandbox ubuntu@jetson-host
```

`ssh-info`は実際に割り当てられたポートとVS Code Remote SSH用の`~/.ssh/config`設定例を表示します。ポートの予約は`~/.local/state/dev-sandbox/`に保存されます。ポートを固定する場合は起動時に指定します。

```bash
SANDBOX_SSH_PORT=2222 /path/to/dev-sandbox/up
```

SSH serverはホストのネットワーク上で待ち受けます。インターネットに直接公開せず、LAN/VPNとホスト側firewallで接続元を制限してください。パスワード認証とrootログインは無効です。

## ドキュメント

- [JetsonホストのPodman・CDIセットアップ](docs/jetson-podman-setup.md)
