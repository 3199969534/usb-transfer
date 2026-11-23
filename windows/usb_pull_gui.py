"""USB 传输 - Windows 极简图形界面（打包成单文件 exe 后无需安装）。"""
import os
import shutil
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import usb_pull as core

PHOTO = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".webp", ".tiff", ".dng"}
VIDEO = {".mp4", ".mov", ".m4v", ".avi", ".mkv"}
MEDIA_PATTERN = " ".join("*" + e for e in sorted(PHOTO | VIDEO))


def fmt(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("USB 传输")
        self.geometry("560x460")
        self.save_dir = os.path.join(os.path.expanduser("~"), "Downloads")
        self.all_files = []
        self.shown = []
        self.del_after = tk.BooleanVar(value=False)

        top = ttk.Frame(self, padding=(8, 8, 8, 2))
        top.pack(fill="x")
        ttk.Button(top, text="刷新", command=self.refresh).pack(side="left")
        ttk.Button(top, text="下载选中", command=self.download).pack(side="left", padx=4)
        ttk.Button(top, text="上传到手机…", command=self.upload).pack(side="left")
        ttk.Button(top, text="保存位置…", command=self.choose_dir).pack(side="left", padx=4)
        ttk.Button(top, text="清理未完成下载", command=self.clean).pack(side="left")

        opt = ttk.Frame(self, padding=(8, 2))
        opt.pack(fill="x")
        ttk.Label(opt, text="显示：").pack(side="left")
        self.kind = ttk.Combobox(opt, values=["全部", "照片", "视频"], width=6, state="readonly")
        self.kind.current(0)
        self.kind.pack(side="left")
        self.kind.bind("<<ComboboxSelected>>", lambda e: self.show())
        ttk.Checkbutton(opt, text="下载成功后删除手机上的副本（释放手机空间）",
                        variable=self.del_after).pack(side="left", padx=12)

        self.listbox = tk.Listbox(self, selectmode="extended")
        self.listbox.pack(fill="both", expand=True, padx=8, pady=4)

        self.bar = ttk.Progressbar(self, maximum=100)
        self.bar.pack(fill="x", padx=8)
        self.status = tk.StringVar(value="请用数据线连接 iPhone，并在手机上打开 App")
        ttk.Label(self, textvariable=self.status, padding=8).pack(fill="x")
        self.after(300, self.refresh)

    # ---------- 小工具 ----------
    def say(self, text):
        self.after(0, lambda: self.status.set(text))

    def set_bar(self, pct):
        self.after(0, lambda: self.bar.configure(value=pct))

    def run_bg(self, fn):
        def wrapper():
            try:
                fn()
            except Exception as e:
                msg = str(e) or e.__class__.__name__
                self.after(0, lambda: messagebox.showerror("出错了", msg))
                self.say("失败：" + msg)
        threading.Thread(target=wrapper, daemon=True).start()

    def choose_dir(self):
        d = filedialog.askdirectory(initialdir=self.save_dir)
        if d:
            self.save_dir = d
            self.say(f"保存位置：{d}")

    def show(self):
        kind = self.kind.get()
        def keep(f):
            ext = os.path.splitext(f["name"])[1].lower()
            return kind == "全部" or (kind == "照片" and ext in PHOTO) or (kind == "视频" and ext in VIDEO)
        self.shown = [f for f in self.all_files if keep(f)]
        self.listbox.delete(0, "end")
        for f in self.shown:
            self.listbox.insert("end", f"{f['name']}   ({fmt(f['size'])})")

    # ---------- 功能 ----------
    def refresh(self):
        def job():
            self.say("正在查找设备…")
            dev = core.find_usb_device()
            self.all_files = core.list_files(dev)
            info = core.phone_info(dev)
            pc_free = shutil.disk_usage(self.save_dir).free if os.path.isdir(self.save_dir) else 0
            self.after(0, self.show)
            self.say(f"已连接，{len(self.all_files)} 个文件｜手机剩余 {fmt(info['free'])}｜电脑剩余 {fmt(pc_free)}")
        self.run_bg(job)

    def download(self):
        picked = [self.shown[i] for i in self.listbox.curselection()]
        if not picked:
            messagebox.showinfo("提示", "请先选择文件")
            return
        delete_after = self.del_after.get()

        def job():
            dev = core.find_usb_device()
            for n, f in enumerate(picked, 1):
                def prog(a, b, f=f, n=n):
                    pct = a * 100 / b if b else 100
                    self.set_bar(pct)
                    self.say(f"[{n}/{len(picked)}] {f['name']}  {pct:.0f}%")
                core.download(dev, f["name"], self.save_dir, prog, delete_after)
            self.say(f"完成，已保存到 {self.save_dir}")
            self.after(0, self.refresh)
        self.run_bg(job)

    def upload(self):
        paths = filedialog.askopenfilenames(
            title="选择要传到手机的文件（照片、视频或任意文件）",
            filetypes=[("所有文件", "*.*"), ("照片和视频", MEDIA_PATTERN)])
        if not paths:
            return

        def job():
            dev = core.find_usb_device()
            for n, p in enumerate(paths, 1):
                name = os.path.basename(p)
                def prog(a, b, name=name, n=n):
                    pct = a * 100 / b if b else 100
                    self.set_bar(pct)
                    self.say(f"上传 [{n}/{len(paths)}] {name}  {pct:.0f}%")
                core.send_file(dev, p, prog)
            self.say(f"已上传 {len(paths)} 个文件到手机")
            self.after(0, self.refresh)
        self.run_bg(job)

    def clean(self):
        n, b = core.clean_partial(self.save_dir)
        self.say(f"已清理 {n} 个未完成文件，释放 {fmt(b)}")


if __name__ == "__main__":
    App().mainloop()
