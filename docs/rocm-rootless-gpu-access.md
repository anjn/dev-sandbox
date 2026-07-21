# ROCm rootless PodmanのGPU device権限

## 症状

ROCmホスト上のrootless PodmanコンテナへSSHログインすると、`rocminfo`が次のようなエラーで失敗することがあります。

```text
Unable to open /dev/kfd read-write: Permission denied
```

同じコンテナでも`podman exec`や`dev-sandbox/exec`では成功する場合があります。

## 原因

コンテナは`userns_mode: keep-id`と`group_add: keep-groups`で起動します。`podman exec`ではcrunの`run.oci.keep_original_groups=1`によってホストの補助グループが保持されるため、ホスト側の`render`グループに属する`/dev/kfd`や`/dev/dri/renderD*`を開けます。

一方、SSHログインではOpenSSHがコンテナ内の`/etc/group`を使って`initgroups()`を実行します。rootless user namespaceでは、コンテナ内の`video`や`render`のGIDはホストdevice nodeの実GIDと一致しません。結果として、SSHログインしたユーザーはdevice nodeのgroup権限を利用できません。

コンテナ内rootもホストrootではないため、コンテナ側からdevice nodeのowner、group、modeを恒久的に変更することはできません。

## 修正

全ユーザーへ`0666`を付与せず、rootless Podmanを実行するホストユーザーだけにACLを追加します。udevルールによって、再起動やdevice node再生成後にもACLを復元します。

```bash
cd /path/to/dev-sandbox
sudo ./setup-rocm-gpu-access
```

`sudo`以外の方法でroot shellから実行する場合は、対象ユーザーを明示します。

```bash
sudo ./setup-rocm-gpu-access jun
```

スクリプトは`/etc/udev/rules.d/99-dev-sandbox-rocm-gpu-acl.rules`を生成し、既存の`/dev/kfd`と`/dev/dri/renderD*`にも即座にACLを適用します。コンテナの再作成は不要です。

設定を確認します。

```bash
getfacl /dev/kfd /dev/dri/renderD*
sudo cat /etc/udev/rules.d/99-dev-sandbox-rocm-gpu-acl.rules
```

## ロールバック

udevルールと現在のdevice ACLを削除します。

```bash
cd /path/to/dev-sandbox
sudo ./setup-rocm-gpu-access --remove
```

削除後はSSHログインしたrootlessコンテナユーザーからROCm deviceへアクセスできなくなります。ホストのdevice mode、owner、`render`グループ設定は変更しません。
