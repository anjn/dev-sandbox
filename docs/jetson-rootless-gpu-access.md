# Jetson rootless PodmanのGPU device権限

## 症状

Jetson上のrootless PodmanコンテナへSSHログインし、CUDA 12.8の最小kernelを実行すると、CUDA初期化が次のエラーで失敗しました。

```text
NvRmMemInitNvmap failed with Permission denied
cudaGetDeviceCount failed
```

調査環境はUbuntu 24.04.1、Linux 5.15.185-tegra、L4T R36.5、aarch64、CUDA 12.8.61、Podman 5.8.5、crun、cgroup v2です。

主な確認コマンドは次のとおりです。

```bash
id
podman info --format 'rootless={{.Host.Security.Rootless}} cgroupVersion={{.Host.CgroupsVersion}} runtime={{.Host.OCIRuntime.Name}}'
podman inspect dev-sandbox-cuda-hip-migration
podman top dev-sandbox-cuda-hip-migration hpid,pid,huser,user,hgroup,group,args
nvidia-ctk cdi list
stat -c '%A %U:%G %u:%g %n' /dev/nvmap /dev/nvhost-* /dev/dri/renderD*
getfacl /dev/nvmap /dev/dri/renderD128 /dev/dri/renderD129
```

## 調査結果

コンテナは`userns_mode: keep-id`、`group_add: keep-groups`、`seccomp=unconfined`で起動し、CDIの`nvidia.com/gpu=all`によって必要なdevice nodeがすべて割り当てられていました。SELinuxとAppArmorは有効ではありませんでした。

ホストユーザーは`video`と`render`グループに所属し、対象nodeは主に次のownerとmodeでした。

```text
root:video  0660  /dev/nvmap
root:video  0660  /dev/nvhost-*-gpu
root:render 0660  /dev/dri/renderD128
root:render 0660  /dev/dri/renderD129
```

`podman exec --user ubuntu`ではcrunの`run.oci.keep_original_groups=1`によってホストの補助グループが保持され、CUDA smoke testは成功しました。一方、実際のSSHログインではOpenSSHが`initgroups()`を実行します。コンテナ内のGID 44（`video`）とGID 104（`render`）はrootless user namespace内のIDへ変換され、ホストの実GID 44/104とは一致しないため、device nodeのgroup権限を利用できません。

コンテナ内rootもホストrootではないため、コンテナ側からdevice nodeのownerやmodeは変更できません。`podman exec`で成功すること、CDI deviceがすべて展開されていること、および一時ACL適用後に同じコンテナで成功することから、CDI、cgroup device filter、SELinux、AppArmorは原因から除外しました。

`strace`では、最初に`/dev/nvmap`が`EACCES`となり、そのACL適用後は次のnodeが拒否されていました。

```text
openat(..., "/dev/nvmap", O_RDWR|...)            = 3
openat(..., "/dev/dri/renderD129", O_RDWR|...)   = -1 EACCES
openat(..., "/dev/dri/renderD128", O_RDWR|...)   = -1 EACCES
```

## 修正

全ユーザーへ`0666`を付与せず、rootless Podmanを実行するホストユーザーだけにACLを追加します。udevルールによって、再起動やdevice node再生成後にもACLを復元します。

```bash
cd /path/to/dev-sandbox
sudo ./setup-jetson-gpu-access
```

`sudo`以外の方法でroot shellから実行する場合は、対象ユーザーを明示します。

```bash
sudo ./setup-jetson-gpu-access amd
```

スクリプトは対象ユーザーが`video`と`render`グループに所属することを確認し、`/etc/udev/rules.d/99-dev-sandbox-jetson-gpu-acl.rules`を生成します。既存deviceにも即座にACLを適用するため、コンテナの再作成は不要です。

設定を確認します。

```bash
getfacl /dev/nvmap /dev/dri/renderD128 /dev/dri/renderD129
sudo cat /etc/udev/rules.d/99-dev-sandbox-jetson-gpu-acl.rules
```

## 検証結果

一時ACLを適用後、実際のsshdへ接続した通常ユーザーで次を実行しました。

```bash
cd /workspace/cuda-hip-migration/step-001
./step-001-run-cuda-smoke.sh
```

2026-07-16の検証結果は次のとおりです。

```text
device_count=1
device_name=Orin cc=8.7
result=42
```

終了コードは0です。

恒久化スクリプトの実行後、udevルールが`root:root 0644`でインストールされ、`udevadm test`が`nvmap`と`renderD128`の両方で該当の`setfacl`処理を生成することも確認しました。

```bash
udevadm test "$(udevadm info --query=path --name=/dev/nvmap)"
udevadm test "$(udevadm info --query=path --name=/dev/dri/renderD128)"
```

## ロールバック

udevルールと現在のdevice ACLを削除します。

```bash
cd /path/to/dev-sandbox
sudo ./setup-jetson-gpu-access --remove
```

削除後はSSHログインしたrootlessコンテナユーザーからGPUへアクセスできなくなります。ホストのdevice mode、owner、`video`/`render`グループ設定は変更しません。
