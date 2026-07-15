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

自動判定を上書きする場合は`SANDBOX_PLATFORM`へ`rocm`または`jetson`を指定します。

```bash
SANDBOX_PLATFORM=jetson /path/to/dev-sandbox/up
```

JetsonではJetPack 6.2対応のNVIDIA PyTorch 25.02 iGPUイメージを使用します。初回起動前に、下記ドキュメントに従ってPodmanとGPU用CDI deviceを準備してください。

## ドキュメント

- [JetsonホストのPodman・CDIセットアップ](docs/jetson-podman-setup.md)
