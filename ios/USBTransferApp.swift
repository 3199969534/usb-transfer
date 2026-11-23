import SwiftUI
import Network
import PhotosUI
import Photos
import UniformTypeIdentifiers

// ===== 存储与缓存工具 =====
struct FileItem: Identifiable {
    let name: String
    let size: Int64
    var id: String { name }
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
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { n in
            let u = docs.appendingPathComponent(n)
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  v.isDirectory != true else { return nil }
            return FileItem(name: n, size: Int64(v.fileSize ?? 0))
        }
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

// ===== TCP 服务：只监听本机回环，只有 USB 隧道能连进来 =====
// 协议（一个连接一个请求，请求为一行文本）：
//   LIST            -> JSON 数组 + \n
//   INFO            -> JSON {free, used, reserve} + \n
//   GET <name>      -> 8 字节大端长度（全 FF 表示不存在）+ 文件内容
//   PUT <name> <n>  -> 之后跟 n 字节内容；成功回复 OK\n
//   DEL <name>      -> 删除手机上的副本，回复 OK\n
final class TransferServer: ObservableObject {
    static let port: NWEndpoint.Port = 5005
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "usb.transfer.server")
    @Published var running = false
    @Published var revision = 0      // 文件列表变化时 +1
    @Published var activeCount = 0   // 正在进行的传输数量

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

    private func begin() { DispatchQueue.main.async { self.activeCount += 1 } }
    private func end() { DispatchQueue.main.async { self.activeCount = max(0, self.activeCount - 1); self.revision += 1 } }

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
            begin()
            sendHeader(UInt64(size), on: c) { self.pump(fh, c) }

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
            begin()
            receiveFile(fh, remaining: size, incoming: leftover, tmp: tmp, dest: dest, c)

        } else if line.hasPrefix("DEL ") {
            let name = (String(line.dropFirst(4)) as NSString).lastPathComponent
            try? FileManager.default.removeItem(at: Store.docs.appendingPathComponent(name))
            DispatchQueue.main.async { self.revision += 1 }
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
    private func pump(_ fh: FileHandle, _ c: NWConnection) {
        guard let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty else {
            try? fh.close()
            c.send(content: nil, contentContext: .finalMessage, isComplete: true,
                   completion: .contentProcessed { [weak self] _ in c.cancel(); self?.end() })
            return
        }
        c.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if err != nil { try? fh.close(); c.cancel(); self?.end() } else { self?.pump(fh, c) }
        })
    }

    private func abortUpload(_ fh: FileHandle, _ tmp: URL, _ c: NWConnection) {
        try? fh.close()
        try? FileManager.default.removeItem(at: tmp) // 丢弃不完整的文件，不占空间
        c.cancel()
        end()
    }

    private func receiveFile(_ fh: FileHandle, remaining: UInt64, incoming: Data,
                             tmp: URL, dest: URL, _ c: NWConnection) {
        var left = remaining
        if !incoming.isEmpty {
            let part = incoming.prefix(Int(min(UInt64(incoming.count), left)))
            do { try fh.write(contentsOf: part) } catch { abortUpload(fh, tmp, c); return } // 磁盘写满时优雅失败
            left -= UInt64(part.count)
        }
        if left == 0 {
            try? fh.close()
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: tmp, to: dest)
            finishUpload(dest, c)
            return
        }
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveFile(fh, remaining: left, incoming: data, tmp: tmp, dest: dest, c)
            } else {
                self.abortUpload(fh, tmp, c)
            }
        }
    }

    private func finishUpload(_ dest: URL, _ c: NWConnection) {
        let reply = { [weak self] in
            c.send(content: Data("OK\n".utf8), completion: .contentProcessed { _ in c.cancel() })
            self?.end()
        }
        let ext = dest.pathExtension.lowercased()
        let isMedia = Store.photoExts.contains(ext) || Store.videoExts.contains(ext)
        guard UserDefaults.standard.bool(forKey: "saveToAlbum"), isMedia else { reply(); return }
        Store.saveToAlbum(dest) { ok in
            if ok { try? FileManager.default.removeItem(at: dest) } // 已进相册，删除副本省空间
            reply()
        }
    }
}

// ===== 从相册导入：直接复制文件，不把整个视频读进内存 =====
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

// ===== 界面 =====
struct ContentView: View {
    @StateObject private var server = TransferServer()
    @AppStorage("saveToAlbum") private var saveToAlbum = false
    @State private var files: [FileItem] = []
    @State private var used: Int64 = 0
    @State private var free: Int64 = 0
    @State private var picked: [PhotosPickerItem] = []
    @State private var showImporter = false
    @State private var confirmClear = false
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        NavigationView {
            List {
                Section("状态") {
                    Label(server.running ? "服务运行中（端口 5005）" : "服务未启动",
                          systemImage: server.running ? "cable.connector" : "pause.circle")
                    if server.activeCount > 0 {
                        Label("正在传输 \(server.activeCount) 个文件，请保持此界面在前台", systemImage: "arrow.left.arrow.right")
                    } else {
                        Text("请保持此界面在前台，并用数据线连接电脑").font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section("添加要传到电脑的文件（大小不限）") {
                    PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos])) {
                        Label("从相册选择照片/视频", systemImage: "photo.on.rectangle")
                    }
                    Button { showImporter = true } label: {
                        Label("从“文件”App 选择", systemImage: "folder")
                    }
                    if importing { ProgressView("正在导入…") }
                    if let message { Text(message).font(.footnote).foregroundColor(.orange) }
                }

                Section("存储与缓存") {
                    Text("本 App 内文件：\(formatBytes(used))")
                    Text("手机剩余空间：\(formatBytes(free))")
                    Toggle("电脑传来的照片/视频自动存入相册并删除副本", isOn: $saveToAlbum)
                    Button("清理临时文件") { Store.cleanTemp(); message = "临时文件已清理"; reload() }
                        .disabled(server.activeCount > 0)
                    Button("清空所有文件", role: .destructive) { confirmClear = true }
                        .disabled(server.activeCount > 0)
                }

                Section("可传输文件（\(files.count)）") {
                    ForEach(files) { f in
                        HStack {
                            Text(f.name).lineLimit(1)
                            Spacer()
                            Text(formatBytes(f.size)).font(.footnote).foregroundColor(.secondary)
                        }
                    }
                    .onDelete { idx in
                        idx.map { files[$0].name }.forEach {
                            try? FileManager.default.removeItem(at: Store.docs.appendingPathComponent($0))
                        }
                        reload()
                    }
                }
            }
            .navigationTitle("USB 传输")
            .confirmationDialog("清空本 App 内的所有文件？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { Store.clearAll(); reload() }
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
    }

    private func reload() {
        files = Store.visibleFiles()
        used = Store.usedByApp()
        free = Store.freeSpace()
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        importing = true
        message = nil
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
                message = skipped > 0 ? "有 \(skipped) 项因空间不足或读取失败被跳过" : nil
                reload()
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        importing = true
        message = nil
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
                message = skipped > 0 ? "有 \(skipped) 个文件因空间不足或读取失败被跳过" : nil
                reload()
            }
        }
    }
}

@main
struct USBTransferApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
