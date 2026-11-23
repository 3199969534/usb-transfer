# USB 传输（iPhone ⇄ Windows，仅有线）

没有 Mac 也能用：iOS App 和 Windows exe 都由 GitHub 云端自动编译。

## 一、上传到 GitHub 并自动编译
1. 在 github.com 新建仓库（建议选 Public：标准运行器免费无限制；Private 也行，但 macOS 分钟数有限）。
2. 仓库页面 → Add file → Upload files，把本文件夹里的**所有内容**（包括 `.github` 文件夹）拖进去，Commit。
   - 若 `.github` 没传上去：Add file → Create new file，文件名输入 `.github/workflows/build.yml`，粘贴内容后提交。
3. 点 Actions 标签，等 `build` 跑完（约 5 分钟，两个任务都变绿勾）。
4. 进入这次运行的页面，底部 Artifacts 下载：
   - `USBTransfer-exe` → 解压得到 `USBTransfer.exe`（电脑端，免安装）
   - `USBTransfer-ipa` → 解压得到 `USBTransfer.ipa`（手机端，未签名）

## 二、把 ipa 装到 iPhone（Windows 上）
1. 电脑装 Apple 官网版 iTunes（Sideloadly 要求，以其官网说明为准）和 Sideloadly。
2. 数据线连接 iPhone，解锁并点"信任"。
3. 打开 Sideloadly，拖入 `USBTransfer.ipa`，填你的 Apple ID，点 Start。
4. iPhone：设置 → 隐私与安全性 → 开发者模式（打开并重启）；设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID。
5. 免费 Apple ID 签名 7 天有效，到期用 Sideloadly 重新装一次即可（数据会保留）。

## 三、使用
手机打开 App 并保持前台（传输时会自动禁止锁屏）→ 电脑运行 `USBTransfer.exe`。

**手机 → 电脑**：在手机 App 里点"从相册选择照片/视频"或"从“文件”App 选择"，电脑端点"刷新"，选中后"下载选中"。
**电脑 → 手机**：电脑端点"上传到手机…"选照片、视频或任意文件。手机端打开"电脑传来的照片/视频自动存入相册并删除副本"后，传来的照片视频会直接进相册（首次会询问相册权限）。

## 大小不限 + 防止存满
- 文件大小**没有人为上限**：全程按 1MB 分块流式读写，内存占用恒定，几十 GB 的视频也一样。
- 唯一的保护是物理空间：手机始终保留 500MB、电脑保留 200MB，剩余不足时传输前就会提示并拒绝，不会把设备写满。
- 写到一半失败/拔线：半成品自动删除（手机端 `.part`、电脑端 `.part`）。
- 缓存清理：
  - 手机 App：显示"本 App 内文件 / 手机剩余空间"；"清理临时文件"、"清空所有文件"；启动时自动清掉遗留临时文件；列表左滑可删除单个文件。
  - 电脑端：勾选"下载成功后删除手机上的副本"可在确认完整收到后释放手机空间；"清理未完成下载"清掉残留的 `.part`。
- 相册选择的照片/视频会先复制一份到 App 里（原件仍在相册），传完后建议用上面的方式清理，避免占双份空间。

## 为什么只走有线
- iOS 端只监听回环地址，局域网无法访问。
- Windows 端只接受 `ConnectionType == "USB"` 的设备。
