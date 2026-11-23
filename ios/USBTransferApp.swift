import SwiftUI
import Network
import PhotosUI
import Photos
import AVKit
import QuickLook
import ImageIO
import UniformTypeIdentifiers

// =====================================================================
// 模型与存储工具
// =====================================================================
enum FileKind {
    case image, video, other
    var icon: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .other: return "doc"
        }
    }
}

struct FileItem: Identifiable, Hashable {
    let name: String
    let size: Int64
    let modified: Date
    var id: String { name }
    var url: URL { Store.docs.appendingPathComponent(name) }
    var kind: FileKind {
        let e = (name as NSString).pathExtension.lowercased()
        if Store.photoExts.contains(e) { return .image }
        if Store.videoExts.contains(e) { return .video }
        return .other
    }
}

enum Store {
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    /// 不限制单个文件大小；只是始终给手机保留 500MB，避免把系统存满
    static let reserve: Int64 = 500 * 1024 * 1024
    static let videoExts: Set<String> = ["mp4", "mov", "m4v"]
    static let photoExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "dng"]

    static func freeSpace() -> Int64 {
        let v = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func usedByApp() -> Int64 {
        guard let en = FileManager.default.enumerator(at: docs, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    static func visibleFiles() -> [FileItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? []
        let items: [FileItem] = names.filter { !$0.hasPrefix(".") }.compactMap { n in
            let u = docs.appendingPathComponent(n)
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey]),
                  v.isDirectory != true else { return nil }
            return FileItem(name: n, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast)
        }
        return items.sorted { $0.modified > $1.modified } // 最新的在前
    }

    static func uniqueURL(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = docs.appendingPathComponent(name)
        var i = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = docs.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            i += 1
        }
        return url
    }

    /// 清理未传完的临时文件和系统临时目录
    static func cleanTemp() {
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: docs.path)) ?? [] where n.hasSuffix(".part") {
            try? fm.removeItem(at: docs.appendingPathComponent(n))
        }
        for u in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: u)
        }
    }

    static func clearAll() {
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: docs.path)) ?? [] {
            try? fm.removeItem(at: docs.appendingPathComponent(n))
        }
        cleanTemp()
    }

    static func saveToAlbum(_ url: URL, done: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { done(false); return }
            let isVideo = videoExts.contains(url.pathExtension.lowercased())
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.originalFilename = url.lastPathComponent
                req.addResource(with: isVideo ? .video : .photo, fileURL: url, options: opts)
            }) { ok, _ in done(ok) }
        }
    }
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

// ---- 缩略图与预览图：降采样读取，大图大视频也不占内存 ----
enum Thumbs {
    static let cache = NSCache<NSString, UIImage>()

    static func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.lastPathComponent)|\(mod)|\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let ext = url.pathExtension.lowercased()
        var img: UIImage?
        if Store.videoExts.contains(ext) {
            img = await videoFrame(url, maxPixel)
        } else if Store.photoExts.contains(ext) {
            img = await Task.detached(priority: .utility) { Thumbs.downsample(url, maxPixel) }.value
        }
        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    static func downsample(_ url: URL, _ maxPixel: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func videoFrame(_ url: URL, _ maxPixel: CGFloat) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        guard let r = try? await gen.image(at: .zero) else { return nil }
        return UIImage(cgImage: r.image)
    }
}

// =====================================================================
// 传输任务与记录
// =====================================================================
enum Direction { case toPC, fromPC, deleted }

final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let total: Int64
    let direction: Direction
    @Published var done: Int64 = 0
    init(name: String, total: Int64, direction: Direction) {
        self.name = name
        self.total = total
        self.direction = direction
    }
}

struct Record: Identifiable {
    let id = UUID()
    let date = Date()
    let name: String
    let size: Int64
    let direction: Direction
    let ok: Bool
    let note: String
}

// =====================================================================
// TCP 服务：只监听本机回环，只有 USB 隧道能连进来
// 协议（一个连接一个请求，请求为一行文本）：
//   LIST / INFO / GET <name> / PUT <name> <n> / DEL <name>
// =====================================================================
final class TransferServer: ObservableObject {
    static let port: NWEndpoint.Port = 5005
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "usb.transfer.server")
    @Published var running = false
    @Published var revision = 0          // 文件列表变化时 +1
    @Published var jobs: [Job] = []      // 正在进行的传输
    @Published var history: [Record] = []// 传输记录（最近 200 条）
    var busy: Bool { !jobs.isEmpty }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            let l = try NWListener(using: params, on: Self.port)
            l.newConnectionHandler = { [weak self] c in
                guard let self else { c.cancel(); return }
                c.start(queue: self.queue)
                self.readLine(c, Data())
            }
            l.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async {
                    switch st {
                    case .ready: self?.running = true
                    case .failed, .cancelled: self?.running = false; self?.listener = nil
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            print("listen failed:", error)
        }
    }

    // ---- 任务与记录 ----
    private func begin(_ job: Job) { DispatchQueue.main.async { self.jobs.append(job) } }
    private func advance(_ job: Job, _ n: Int) { DispatchQueue.main.async { job.done += Int64(n) } }
    private func finish(_ job: Job, ok: Bool, note: String) {
        DispatchQueue.main.async {
            self.jobs.removeAll { $0.id == job.id }
            self.history.insert(Record(name: job.name, size: job.total, direction: job.direction, ok: ok, note: note), at: 0)
            if self.history.count > 200 { self.history.removeLast(self.history.count - 200) }
            self.revision += 1
        }
    }

    // ---- 读请求行 ----
    private func readLine(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let i = buf.firstIndex(of: 0x0A) {
                let leftover = Data(buf[buf.index(after: i)...]) // 请求行之后多读到的数据（上传时属于文件内容）
                self.respond(String(decoding: buf[..<i], as: UTF8.self), leftover, on: c)
            } else if done || err != nil || buf.count > 8192 {
                c.cancel()
            } else {
                self.readLine(c, buf)
            }
        }
    }

    private func sendLine(_ data: Data?, _ c: NWConnection) {
        var d = data ?? Data()
        d.append(0x0A)
        c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
    }

    private func respond(_ line: String, _ leftover: Data, on c: NWConnection) {
        if line == "LIST" {
            let items = Store.visibleFiles().map { ["name": $0.name, "size": $0.size] as [String: Any] }
            sendLine(try? JSONSerialization.data(withJSONObject: items), c)

        } else if line == "INFO" {
            let info: [String: Any] = ["free": Store.freeSpace(), "used": Store.usedByApp(), "reserve": Store.reserve]
            sendLine(try? JSONSerialization.data(withJSONObject: info), c)

        } else if line.hasPrefix("GET ") {
            let name = (String(line.dropFirst(4)) as NSString).lastPathComponent // 防路径穿越
            let url = Store.docs.appendingPathComponent(name)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  let fh = try? FileHandle(forReadingFrom: url) else {
                sendHeader(UInt64.max, on: c) { c.cancel() } // 找不到文件
                return
            }
            let job = Job(name: name, total: Int64(size), direction: .toPC)
            begin(job)
            sendHeader(UInt64(size), on: c) { self.pump(fh, c, job) }

        } else if line.hasPrefix("PUT ") {
            let rest = line.dropFirst(4)
            guard let sp = rest.lastIndex(of: " "),
                  let size = UInt64(rest[rest.index(after: sp)...]) else { c.cancel(); return }
            let name = (String(rest[..<sp]) as NSString).lastPathComponent
            // 空间保护：写入后手机至少还剩 500MB，否则直接拒绝
            if Int64(clamping: size) + Store.reserve > Store.freeSpace() {
                sendLine(Data("NOSPACE".utf8), c)
                return
            }
            let dest = Store.docs.appendingPathComponent(name)
            let tmp = Store.docs.appendingPathComponent(".\(name).part")
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            guard let fh = try? FileHandle(forWritingTo: tmp) else { c.cancel(); return }
            let job = Job(name: name, total: Int64(clamping: size), direction: .fromPC)
            begin(job)
            receiveFile(fh, remaining: size, incoming: leftover, tmp: tmp, dest: dest, c, job)

        } else if line.hasPrefix("DEL ") {
            let name = (String(line.dropFirst(4)) as NSString).lastPathComponent
            let url = Store.docs.appendingPathComponent(name)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            try? FileManager.default.removeItem(at: url)
            finish(Job(name: name, total: size, direction: .deleted), ok: true, note: "电脑确认收到后删除")
            sendLine(Data("OK".utf8), c)

        } else {
            c.cancel()
        }
    }

    private func sendHeader(_ size: UInt64, on c: NWConnection, then next: @escaping () -> Void) {
        var be = size.bigEndian
        c.send(content: Data(bytes: &be, count: 8), completion: .contentProcessed { _ in next() })
    }

    // 以 1MB 为单位流式读取发送，内存占用恒定，与文件大小无关
    private func pump(_ fh: FileHandle, _ c: NWConnection, _ job: Job) {
        let chunk: Data
        do {
            chunk = try fh.read(upToCount: 1 << 20) ?? Data()
        } catch {
            try? fh.close(); c.cancel()
            finish(job, ok: false, note: "读取失败")
            return
        }
        if chunk.isEmpty {
            try? fh.close()
            c.send(content: nil, contentContext: .finalMessage, isComplete: true,
                   completion: .contentProcessed { [weak self] _ in
                       c.cancel()
                       self?.finish(job, ok: true, note: "完成")
                   })
            return
        }
        c.send(content: chunk, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if err != nil {
                try? fh.close(); c.cancel()
                self.finish(job, ok: false, note: "连接中断")
                return
            }
            self.advance(job, chunk.count)
            self.pump(fh, c, job)
        })
    }

    private func abortUpload(_ fh: FileHandle, _ tmp: URL, _ c: NWConnection, _ job: Job) {
        try? fh.close()
        try? FileManager.default.removeItem(at: tmp) // 丢弃不完整的文件，不占空间
        c.cancel()
        finish(job, ok: false, note: "中断或空间不足，已丢弃")
    }

    private func receiveFile(_ fh: FileHandle, remaining: UInt64, incoming: Data,
                             tmp: URL, dest: URL, _ c: NWConnection, _ job: Job) {
        var left = remaining
        if !incoming.isEmpty {
            let part = incoming.prefix(Int(min(UInt64(incoming.count), left)))
            do { try fh.write(contentsOf: part) } catch { abortUpload(fh, tmp, c, job); return } // 写满时优雅失败
            left -= UInt64(part.count)
            advance(job, part.count)
        }
        if left == 0 {
            try? fh.close()
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: tmp, to: dest)
            finishUpload(dest, c, job)
            return
        }
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveFile(fh, remaining: left, incoming: data, tmp: tmp, dest: dest, c, job)
            } else {
                self.abortUpload(fh, tmp, c, job)
            }
        }
    }

    private func finishUpload(_ dest: URL, _ c: NWConnection, _ job: Job) {
        let reply: (String) -> Void = { [weak self] note in
            c.send(content: Data("OK\n".utf8), completion: .contentProcessed { _ in c.cancel() })
            self?.finish(job, ok: true, note: note)
        }
        let ext = dest.pathExtension.lowercased()
        let isMedia = Store.photoExts.contains(ext) || Store.videoExts.contains(ext)
        guard UserDefaults.standard.bool(forKey: "saveToAlbum"), isMedia else { reply("完成"); return }
        Store.saveToAlbum(dest) { ok in
            if ok { try? FileManager.default.removeItem(at: dest) } // 已进相册，删除副本省空间
            reply(ok ? "已存入相册" : "完成（未能存入相册）")
        }
    }
}

// =====================================================================
// 从相册导入：直接复制文件，不把整个视频读进内存
// =====================================================================
struct PickedFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try PickedFile.copy(received.file)
        }
        FileRepresentation(importedContentType: .image) { received in
            try PickedFile.copy(received.file)
        }
    }

    static func copy(_ src: URL) throws -> PickedFile {
        let dest = Store.uniqueURL(src.lastPathComponent)
        try FileManager.default.copyItem(at: src, to: dest)
        return PickedFile()
    }
}

// =====================================================================
// UIKit 桥接：保存到所选位置、分享、文件预览
// =====================================================================
struct ExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onDone: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: true —— 直接在磁盘上复制，大文件不进内存
        let p = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDone) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDone: (Bool) -> Void
        init(_ onDone: @escaping (Bool) -> Void) { self.onDone = onDone }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onDone(true) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onDone(false) }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }
    func updateUIViewController(_ vc: QLPreviewController, context: Context) {
        context.coordinator.url = url
        vc.reloadData()
    }
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

// =====================================================================
// 预览组件
// =====================================================================
struct ThumbView: View {
    let item: FileItem
    var maxPixel: CGFloat = 320
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    Color.secondary.opacity(0.12)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: item.kind.icon).font(.title2).foregroundColor(.secondary)
                    }
                    if item.kind == .video {
                        Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white).shadow(radius: 3)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .task(id: "\(item.id)|\(item.size)|\(item.modified.timeIntervalSince1970)") {
                image = await Thumbs.image(for: item.url, maxPixel: maxPixel)
            }
    }
}

struct ImagePreview: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(8)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) { image = await Thumbs.image(for: url, maxPixel: 2400) }
    }
}

struct VideoPreview: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        Group {
            if let player { VideoPlayer(player: player) } else { ProgressView() }
        }
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear { player?.pause() }
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: job.direction == .toPC ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                Text(job.name).lineLimit(1)
                Spacer()
                Text(job.total > 0 ? "\(Int(Double(job.done) * 100 / Double(job.total)))%" : "")
                    .monospacedDigit().foregroundColor(.secondary)
            }
            ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
            Text(job.direction == .toPC ? "发送到电脑" : "从电脑接收")
                .font(.caption).foregroundColor(.secondary)
        }
    }
}

// =====================================================================
// 文件详情：预览 + 存入相册 / 保存到… / 分享 / 删除
// =====================================================================
struct FileDetailView: View {
    let item: FileItem
    let onDeleted: () -> Void
    @State private var exporting = false
    @State private var sharing = false
    @State private var confirmDelete = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch item.kind {
                case .image: ImagePreview(url: item.url)
                case .video: VideoPreview(url: item.url)
                case .other: QuickLookView(url: item.url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(formatBytes(item.size))
                Spacer()
                Text(item.modified.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.footnote).foregroundColor(.secondary)
            .padding(.horizontal).padding(.vertical, 10)
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 每个按钮都有标题和图标，系统才能在 iPhone Duo 上把它们排成竖条
            ToolbarItemGroup(placement: .primaryAction) {
                if item.kind != .other {
                    Button { saveAlbum() } label: { Label("存入相册", systemImage: "photo.badge.plus") }
                }
                Button { exporting = true } label: { Label("保存到…", systemImage: "folder.badge.plus") }
                Button { sharing = true } label: { Label("分享", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
            }
        }
        .sheet(isPresented: $exporting) {
            ExportPicker(url: item.url) { ok in
                exporting = false
                if ok { message = "已保存到你选择的位置" }
            }
        }
        .sheet(isPresented: $sharing) { ShareSheet(urls: [item.url]) }
        .confirmationDialog("删除“\(item.name)”？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                try? FileManager.default.removeItem(at: item.url)
                onDeleted()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从本 App 中移除，此操作无法撤销。")
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func saveAlbum() {
        Store.saveToAlbum(item.url) { ok in
            DispatchQueue.main.async {
                message = ok ? "已存入相册" : "存入相册失败，请在“设置”中允许本 App 添加照片"
            }
        }
    }
}

// =====================================================================
// 主界面：NavigationSplitView（按可用空间自适应，不判断设备型号）
//   展开内屏（宽）：左侧文件列表 + 右侧详情/传输中心
//   外屏（窄）：自动变成"列表 → 点进详情"
// =====================================================================
enum Route: Hashable {
    case center
    case file(String)
}

struct ContentView: View {
    @StateObject private var server = TransferServer()
    @AppStorage("saveToAlbum") private var saveToAlbum = false
    @State private var files: [FileItem] = []
    @State private var used: Int64 = 0
    @State private var free: Int64 = 0
    @State private var route: Route?
    @State private var picked: [PhotosPickerItem] = []
    @State private var showImporter = false
    @State private var confirmClear = false
    @State private var importing = false
    @State private var notice: String?

    private var selectedFile: FileItem? {
        if case .file(let n)? = route { return files.first { $0.name == n } }
        return nil
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let f = selectedFile {
                FileDetailView(item: f) { route = nil; reload() }
                    .id(f.id)
            } else {
                dashboard
            }
        }
        .alert("提示", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
        .confirmationDialog("清空本 App 内的所有文件？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { Store.clearAll(); route = nil; reload() }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            importFiles((try? result.get()) ?? [])
        }
        .onChange(of: picked) { items in
            if !items.isEmpty { importPhotos(items) }
        }
        .onReceive(server.$revision) { _ in reload() }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true // 防止自动锁屏
            Store.cleanTemp()                               // 启动时清掉上次遗留的临时文件
            server.start()
            reload()
        }
    }

    // ---------------- 侧栏（窄屏时就是首页） ----------------
    private var sidebar: some View {
        List(selection: $route) {
            Section {
                Label(server.running ? "服务运行中" : "服务未启动",
                      systemImage: server.running ? "cable.connector" : "pause.circle")
                if server.busy {
                    Label("正在传输 \(server.jobs.count) 个文件", systemImage: "arrow.left.arrow.right")
                }
                Label("传输中心", systemImage: "square.grid.2x2").tag(Route.center)
            } header: {
                Text("状态")
            } footer: {
                Text("请保持此界面在前台，并用数据线连接电脑")
            }

            Section("添加文件") {
                PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos])) {
                    Label("从相册选择照片/视频", systemImage: "photo.on.rectangle")
                }
                Button { showImporter = true } label: {
                    Label("从“文件”App 选择", systemImage: "folder")
                }
                if importing { ProgressView("正在导入…") }
            }

            Section("文件（\(files.count)）") {
                ForEach(files) { f in
                    HStack(spacing: 12) {
                        ThumbView(item: f, maxPixel: 120).frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).lineLimit(1)
                            Text(formatBytes(f.size)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .tag(Route.file(f.name))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { remove(f) } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle("USB 传输")
    }

    // ---------------- 传输中心（右侧默认内容） ----------------
    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !server.jobs.isEmpty {
                    card("正在传输") {
                        ForEach(server.jobs) { JobRow(job: $0) }
                    }
                }

                card("存储与缓存") {
                    HStack {
                        stat("本 App 内文件", formatBytes(used))
                        Spacer()
                        stat("手机剩余空间", formatBytes(free))
                    }
                    Toggle("电脑传来的照片/视频自动存入相册并删除副本", isOn: $saveToAlbum)
                    HStack {
                        Button { Store.cleanTemp(); notice = "临时文件已清理"; reload() } label: {
                            Label("清理临时文件", systemImage: "wind")
                        }
                        .disabled(server.busy)
                        Spacer()
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("清空所有文件", systemImage: "trash")
                        }
                        .disabled(server.busy)
                    }
                    .buttonStyle(.bordered)
                }

                card("文件（\(files.count)）") {
                    if files.isEmpty {
                        Text("还没有文件。在左侧添加，或从电脑上传。").foregroundColor(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 14) {
                            ForEach(files) { f in
                                Button { route = .file(f.name) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ThumbView(item: f)
                                        Text(f.name).font(.caption).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                card("传输记录") {
                    if server.history.isEmpty {
                        Text("暂无记录").foregroundColor(.secondary)
                    } else {
                        ForEach(server.history.prefix(50)) { r in
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: r))
                                    .foregroundColor(r.ok ? .accentColor : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name).lineLimit(1)
                                    Text("\(label(for: r.direction)) · \(formatBytes(r.size)) · \(r.note)")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(r.date, style: .time).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Button("清除记录") { server.history.removeAll() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 900)            // 宽屏时限制可读宽度，不让内容无限拉伸
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("传输中心")
        .navigationBarTitleDisplayMode(.inline)
    }

    // ---------------- 小部件与方法 ----------------
    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.title3.weight(.semibold))
        }
    }

    private func label(for d: Direction) -> String {
        switch d {
        case .toPC: return "发送到电脑"
        case .fromPC: return "从电脑接收"
        case .deleted: return "已删除手机副本"
        }
    }

    private func icon(for r: Record) -> String {
        if !r.ok { return "exclamationmark.triangle.fill" }
        switch r.direction {
        case .toPC: return "arrow.up.circle.fill"
        case .fromPC: return "arrow.down.circle.fill"
        case .deleted: return "trash.circle.fill"
        }
    }

    private func reload() {
        files = Store.visibleFiles()
        used = Store.usedByApp()
        free = Store.freeSpace()
    }

    private func remove(_ f: FileItem) {
        try? FileManager.default.removeItem(at: f.url)
        if route == Route.file(f.name) { route = nil }
        reload()
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        importing = true
        Task {
            var skipped = 0
            for item in items {
                if Store.freeSpace() < Store.reserve { skipped += 1; continue } // 空间不足就停止复制
                let ok = (try? await item.loadTransferable(type: PickedFile.self)) != nil
                if !ok { skipped += 1 }
            }
            await MainActor.run {
                picked = []
                importing = false
                if skipped > 0 { notice = "有 \(skipped) 项因空间不足或读取失败被跳过" }
                reload()
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        importing = true
        DispatchQueue.global().async {
            var skipped = 0
            for url in urls {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                if size + Store.reserve > Store.freeSpace() { skipped += 1; continue }
                do { try FileManager.default.copyItem(at: url, to: Store.uniqueURL(url.lastPathComponent)) }
                catch { skipped += 1 }
            }
            DispatchQueue.main.async {
                importing = false
                if skipped > 0 { notice = "有 \(skipped) 个文件因空间不足或读取失败被跳过" }
                reload()
            }
        }
    }
}

@main
struct USBTransferApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
