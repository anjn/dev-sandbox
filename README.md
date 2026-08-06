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

### ディスプレイ出力

通常の`rocm`/`jetson` sandboxでも、ホスト側に`DISPLAY`が設定されていて`/tmp/.X11-unix`が存在する場合は、X11 socketとXauthorityを自動でコンテナへ渡します。SSH接続ではなく、まず`exec`から表示確認するのが簡単です。

```bash
cd /path/to/workspace
SANDBOX_PLATFORM=rocm /path/to/dev-sandbox/up
/path/to/dev-sandbox/exec xeyes
```

GLの確認には`glxinfo`を使えます。

```bash
/path/to/dev-sandbox/exec glxinfo -B
```

### ROS 2 tools role

`SANDBOX_ROLE=ros2-tools`を指定すると、Strix HaloなどのAMD/ROCmホスト上でROS 2 CLI、RViz、DDS確認ツール用のコンテナを起動します。ホストにはROS 2をapt installしません。

このroleは`SANDBOX_PLATFORM=rocm`専用です。通常のAI開発用sandboxは従来どおり`SANDBOX_ROLE`未指定、つまり`base`で起動します。

まずUbuntu on Xorgでログインしていることを確認します。

```bash
echo "$XDG_SESSION_TYPE"
```

workspaceへ移動してtoolsコンテナを起動します。

```bash
cd /path/to/workspace
SANDBOX_ROLE=ros2-tools \
SANDBOX_PLATFORM=rocm \
/path/to/dev-sandbox/up
```

コンテナ内でpreflight、topic確認、RViz起動を行います。必要なROS 2/DDS環境変数や追加ディレクトリのmountは、用途に合わせて明示的に設定してください。

```bash
/path/to/dev-sandbox/exec preflight-ros2-tools
/path/to/dev-sandbox/exec bash -lc 'source /opt/ros/humble/setup.bash && ros2 topic list'
/path/to/dev-sandbox/exec run-rviz
```

直接確認する場合は、コンテナ内で`ros2 topic list`や`rviz2`も実行できます。

```bash
/path/to/dev-sandbox/exec bash -lc 'source /opt/ros/humble/setup.bash && ros2 topic list'
/path/to/dev-sandbox/exec bash -lc 'source /opt/ros/humble/setup.bash && rviz2'
```

### ROS 2 + ROCm role

`SANDBOX_ROLE=ros2-rocm`を指定すると、ROS 2 Humble toolsとROCm SDKを同じコンテナで使えます。`ros2-tools`は観測・RViz専用でROCm compute用の`/dev/kfd`やROCm userspaceを含まないため、ROCmも必要な作業ではこのroleを使います。

```bash
cd /path/to/workspace
SANDBOX_ROLE=ros2-rocm \
SANDBOX_PLATFORM=rocm \
/path/to/dev-sandbox/up
```

起動後にROS 2、RViz、ROCm deviceをまとめて確認します。

```bash
/path/to/dev-sandbox/exec preflight-ros2-rocm
/path/to/dev-sandbox/exec bash -lc 'source /opt/ros/humble/setup.bash && ros2 topic list'
/path/to/dev-sandbox/exec rocminfo
```

既定のbase imageはROS 2 Humbleのdeb packageと合わせるため、Ubuntu 22.04系の`docker.io/rocm/dev-ubuntu-22.04:7.2.2-complete`です。PyTorch入りのROCm imageを試す場合は、同じくUbuntu 22.04系のimageを指定してbuildできます。

```bash
ROS2_ROCM_BASE_IMAGE=docker.io/rocm/pytorch:rocm7.2_ubuntu22.04_py3.10_pytorch_release_2.10.0 \
SANDBOX_ROLE=ros2-rocm \
SANDBOX_PLATFORM=rocm \
/path/to/dev-sandbox/up
```

Strix Haloでcontainer内の`vulkaninfo`がGPUを認識しない場合に備え、`ros2-rocm` imageは既定でJammy向けのKisak Mesa stable PPAからMesa/RADVを取得します。別のMesa package sourceを使う場合は`ROS2_ROCM_MESA_APT_PPA`を指定します。空文字にすると追加PPAを使いません。

```bash
ROS2_ROCM_MESA_APT_PPA= \
SANDBOX_ROLE=ros2-rocm \
SANDBOX_PLATFORM=rocm \
/path/to/dev-sandbox/up
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

### GPU device ACL

SSHログイン後のコンテナユーザーからGPUを使用するため、rootless Podmanを実行するホストユーザーにdevice ACLを設定します。

ROCmホスト:

```bash
cd /path/to/dev-sandbox
sudo ./setup-rocm-gpu-access
```

Jetsonホスト:

```bash
cd /path/to/dev-sandbox
sudo ./setup-jetson-gpu-access
```

詳しい原因、対象device、ロールバック方法は[ROCm rootless PodmanのGPU device権限](docs/rocm-rootless-gpu-access.md)または[Jetson rootless PodmanのGPU device権限](docs/jetson-rootless-gpu-access.md)を参照してください。

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

## ホスト再起動後の自動起動

`up`で作成したコンテナにはPodmanの`restart: always` policyが設定されます。rootlessコンテナをホスト起動時にも復帰させるには、Podmanユーザーのsystemd user serviceを有効化します。

```bash
sudo loginctl enable-linger "$USER"
systemctl --user enable podman-restart.service
```

既存コンテナへrestart policyを反映するには、更新後にもう一度`up`を実行してください。

## ドキュメント

- [JetsonホストのPodman・CDIセットアップ](docs/jetson-podman-setup.md)
- [ROCm rootless PodmanのGPU device権限](docs/rocm-rootless-gpu-access.md)
- [Jetson rootless PodmanのGPU device権限](docs/jetson-rootless-gpu-access.md)
