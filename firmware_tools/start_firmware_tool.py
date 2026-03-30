#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
import queue
import subprocess
import sys
import threading
from pathlib import Path
from tkinter import BooleanVar, StringVar, Tk, filedialog, messagebox, ttk
from tkinter.scrolledtext import ScrolledText


def file_hashes(path: Path) -> tuple[str, str, int]:
    md5 = hashlib.md5()
    sha = hashlib.sha256()
    size = 0
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            size += len(chunk)
            md5.update(chunk)
            sha.update(chunk)
    return md5.hexdigest(), sha.hexdigest(), size


class FirmwareToolGUI:
    def __init__(self, root: Tk) -> None:
        self.root = root
        self.root.title("Firmware Extract/Repack Validator")
        self.root.geometry("1280x860")

        self.base_dir = Path(__file__).resolve().parent
        self.scripts_dir = self.base_dir / "scripts"
        self.extract_script = self.scripts_dir / "extract_firmware.py"
        self.repack_script = self.scripts_dir / "repack_firmware.py"
        self.validate_script = self.scripts_dir / "validate_firmware.py"
        self.msg_queue: queue.Queue[tuple[str, object]] = queue.Queue()
        self.worker_running = False
        self.current_task = ""
        self.progress_val = 0

        self.extract_workdir = StringVar(value=str(self.base_dir))
        self.gemini_bin = StringVar(value=str(self.base_dir / "GEMINI_PACK.BIN"))
        self.isp_bin = StringVar(value=str(self.base_dir / "ISPBOOOT.BIN"))
        self.extract_force = BooleanVar(value=True)

        self.repack_workdir = StringVar(value=str(self.base_dir))
        self.gemini_dir = StringVar(value=str(self.base_dir / "GEMINI_PACK"))
        self.isp_dir = StringVar(value=str(self.base_dir / "ISPBOOOT"))
        self.repack_output = StringVar(value="REPACKED")
        self.repack_clean = BooleanVar(value=True)

        self.val_gemini = StringVar(value=str(self.base_dir / "GEMINI_PACK.BIN"))
        self.val_isp = StringVar(value=str(self.base_dir / "ISPBOOOT.BIN"))
        self.val_gemini_mod = StringVar(value=str(self.base_dir / "REPACKED" / "MODIFIED_GEMINI_PACK.BIN"))
        self.val_isp_mod = StringVar(value=str(self.base_dir / "REPACKED" / "MODIFIED_ISPBOOOT.BIN"))
        self.val_json = StringVar(value=str(self.base_dir / "REPACKED" / "validation_report.json"))

        self._build_ui()
        self.root.after(100, self._poll_queue)

    def _build_ui(self) -> None:
        container = ttk.Frame(self.root, padding=10)
        container.pack(fill="both", expand=True)

        notebook = ttk.Notebook(container)
        notebook.pack(fill="both", expand=True)

        self.extract_tab = ttk.Frame(notebook, padding=10)
        self.repack_tab = ttk.Frame(notebook, padding=10)
        self.validate_tab = ttk.Frame(notebook, padding=10)
        self.checksum_tab = ttk.Frame(notebook, padding=10)

        notebook.add(self.extract_tab, text="Extract")
        notebook.add(self.repack_tab, text="Repack")
        notebook.add(self.validate_tab, text="Validate")
        notebook.add(self.checksum_tab, text="Checksums")

        self._build_extract_tab()
        self._build_repack_tab()
        self._build_validate_tab()
        self._build_checksum_tab()

        bottom = ttk.Frame(container, padding=(0, 8, 0, 0))
        bottom.pack(fill="both", expand=False)

        self.progress = ttk.Progressbar(bottom, mode="determinate", maximum=100)
        self.progress.pack(fill="x", pady=(0, 6))

        self.log_text = ScrolledText(bottom, height=14, wrap="word")
        self.log_text.pack(fill="both", expand=True)
        self.log_text.insert("end", "Ready.\n")
        self.log_text.configure(state="disabled")

    def _row(self, parent: ttk.Frame, row: int, label: str, var: StringVar, browse: str) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8), pady=4)
        ttk.Entry(parent, textvariable=var).grid(row=row, column=1, sticky="ew", padx=(0, 8), pady=4)
        if browse == "file":
            ttk.Button(parent, text="Browse", command=lambda: self._pick_file(var)).grid(row=row, column=2, pady=4)
        elif browse == "save":
            ttk.Button(parent, text="Save As", command=lambda: self._pick_save(var)).grid(row=row, column=2, pady=4)
        else:
            ttk.Button(parent, text="Browse", command=lambda: self._pick_dir(var)).grid(row=row, column=2, pady=4)

    def _build_extract_tab(self) -> None:
        self.extract_tab.columnconfigure(1, weight=1)
        self._row(self.extract_tab, 0, "Output Workdir", self.extract_workdir, "dir")
        self._row(self.extract_tab, 1, "GEMINI Bin", self.gemini_bin, "file")
        self._row(self.extract_tab, 2, "ISP Bin", self.isp_bin, "file")
        ttk.Checkbutton(self.extract_tab, text="Overwrite existing folders (--force)", variable=self.extract_force).grid(
            row=3, column=1, sticky="w", pady=(4, 10)
        )
        ttk.Button(self.extract_tab, text="Run Extraction", command=self.run_extract).grid(row=4, column=1, sticky="w")

    def _build_repack_tab(self) -> None:
        self.repack_tab.columnconfigure(1, weight=1)
        self._row(self.repack_tab, 0, "Working Directory", self.repack_workdir, "dir")
        self._row(self.repack_tab, 1, "GEMINI_PACK Folder", self.gemini_dir, "dir")
        self._row(self.repack_tab, 2, "ISPBOOOT Folder", self.isp_dir, "dir")
        self._row(self.repack_tab, 3, "Output Folder Name/Path", self.repack_output, "dir")
        ttk.Checkbutton(self.repack_tab, text="Clean output first (--clean-output)", variable=self.repack_clean).grid(
            row=4, column=1, sticky="w", pady=(4, 10)
        )
        ttk.Button(self.repack_tab, text="Run Repack", command=self.run_repack).grid(row=5, column=1, sticky="w")

    def _build_validate_tab(self) -> None:
        self.validate_tab.columnconfigure(1, weight=1)
        self._row(self.validate_tab, 0, "Original GEMINI", self.val_gemini, "file")
        self._row(self.validate_tab, 1, "Original ISP", self.val_isp, "file")
        self._row(self.validate_tab, 2, "Modified GEMINI", self.val_gemini_mod, "file")
        self._row(self.validate_tab, 3, "Modified ISP", self.val_isp_mod, "file")
        self._row(self.validate_tab, 4, "JSON Report Path", self.val_json, "save")
        ttk.Button(self.validate_tab, text="Run Validation", command=self.run_validate).grid(row=5, column=1, sticky="w")

    def _build_checksum_tab(self) -> None:
        top = ttk.Frame(self.checksum_tab)
        top.pack(fill="x")
        ttk.Button(top, text="Refresh Checksums", command=self.refresh_checksums).pack(side="left")
        ttk.Button(top, text="Open Repacked Folder", command=self.open_repacked_folder).pack(side="left", padx=(8, 0))

        cols = ("label", "path", "size", "md5", "sha256")
        self.checksum_tree = ttk.Treeview(self.checksum_tab, columns=cols, show="headings", height=18)
        for col, width in (
            ("label", 170),
            ("path", 380),
            ("size", 110),
            ("md5", 270),
            ("sha256", 430),
        ):
            self.checksum_tree.heading(col, text=col.upper())
            self.checksum_tree.column(col, width=width, anchor="w")
        self.checksum_tree.pack(fill="both", expand=True, pady=(8, 0))

    def _pick_file(self, var: StringVar) -> None:
        current = Path(var.get()).parent if var.get() else self.base_dir
        value = filedialog.askopenfilename(initialdir=str(current))
        if value:
            var.set(value)

    def _pick_dir(self, var: StringVar) -> None:
        current = Path(var.get()) if var.get() else self.base_dir
        value = filedialog.askdirectory(initialdir=str(current))
        if value:
            var.set(value)

    def _pick_save(self, var: StringVar) -> None:
        current = Path(var.get())
        value = filedialog.asksaveasfilename(
            initialdir=str(current.parent if current.parent.exists() else self.base_dir),
            initialfile=current.name if current.name else "validation_report.json",
            defaultextension=".json",
            filetypes=[("JSON files", "*.json"), ("All files", "*.*")],
        )
        if value:
            var.set(value)

    def _append_log(self, text: str) -> None:
        self.log_text.configure(state="normal")
        self.log_text.insert("end", text + "\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _start_task(self, task: str) -> bool:
        if self.worker_running:
            messagebox.showwarning("Busy", "Another task is currently running.")
            return False
        self.worker_running = True
        self.current_task = task
        self.progress_val = 0
        self.progress.configure(value=0)
        self._append_log(f"== {task} ==")
        return True

    def _finish_task(self) -> None:
        self.worker_running = False
        self.current_task = ""

    def _run_command(self, cmd: list[str], cwd: Path, on_done=None) -> None:
        def worker() -> None:
            rc = 1
            try:
                proc = subprocess.Popen(
                    cmd,
                    cwd=str(cwd),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )
                assert proc.stdout is not None
                for line in proc.stdout:
                    self.msg_queue.put(("log", line.rstrip("\n")))
                rc = proc.wait()
            except Exception as exc:
                self.msg_queue.put(("log", f"ERROR: {exc}"))
                rc = 1
            self.msg_queue.put(("done", {"rc": rc, "on_done": on_done}))

        threading.Thread(target=worker, daemon=True).start()

    def _run_pipeline(self, stages: list[tuple[str, list[str], Path]], on_done=None) -> None:
        def worker() -> None:
            rc = 0
            for name, cmd, cwd in stages:
                self.msg_queue.put(("log", f"[pipeline] stage: {name}"))
                try:
                    proc = subprocess.Popen(
                        cmd,
                        cwd=str(cwd),
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        text=True,
                        bufsize=1,
                    )
                    assert proc.stdout is not None
                    for line in proc.stdout:
                        self.msg_queue.put(("log", line.rstrip("\n")))
                    rc = proc.wait()
                except Exception as exc:
                    self.msg_queue.put(("log", f"ERROR: {exc}"))
                    rc = 1
                if rc != 0:
                    break
            self.msg_queue.put(("done", {"rc": rc, "on_done": on_done}))

        threading.Thread(target=worker, daemon=True).start()

    def _poll_queue(self) -> None:
        try:
            while True:
                kind, payload = self.msg_queue.get_nowait()
                if kind == "log":
                    line = str(payload)
                    self._append_log(line)
                    if self.current_task:
                        self.progress_val = min(95, self.progress_val + 1)
                        self.progress.configure(value=self.progress_val)
                elif kind == "done":
                    data = payload  # type: ignore[assignment]
                    rc = int(data["rc"])
                    if rc == 0:
                        self.progress.configure(value=100)
                        self._append_log("Task complete.")
                    else:
                        self.progress.configure(value=0)
                        self._append_log(f"Task failed (rc={rc}).")
                    cb = data.get("on_done")
                    self._finish_task()
                    if cb:
                        cb(rc)
        except queue.Empty:
            pass
        finally:
            self.root.after(100, self._poll_queue)

    def run_extract(self) -> None:
        if not self._start_task("Extraction"):
            return
        cmd = [
            sys.executable,
            "-u",
            str(self.extract_script),
            "--workdir",
            self.extract_workdir.get(),
            "--gemini-bin",
            self.gemini_bin.get(),
            "--isp-bin",
            self.isp_bin.get(),
        ]
        if self.extract_force.get():
            cmd.append("--force")

        self.gemini_dir.set(str(Path(self.extract_workdir.get()) / "GEMINI_PACK"))
        self.isp_dir.set(str(Path(self.extract_workdir.get()) / "ISPBOOOT"))
        self.repack_workdir.set(self.extract_workdir.get())
        self._run_command(cmd, Path(self.base_dir), on_done=lambda rc: self.refresh_checksums() if rc == 0 else None)

    def run_repack(self) -> None:
        if not self._start_task("Repack"):
            return
        cmd = [
            sys.executable,
            "-u",
            str(self.repack_script),
            "--workdir",
            self.repack_workdir.get(),
            "--gemini-dir",
            self.gemini_dir.get(),
            "--isp-dir",
            self.isp_dir.get(),
            "--output",
            self.repack_output.get(),
        ]
        if self.repack_clean.get():
            cmd.append("--clean-output")

        out_dir = Path(self.repack_output.get())
        if not out_dir.is_absolute():
            out_dir = Path(self.repack_workdir.get()) / out_dir
        self.val_gemini_mod.set(str(out_dir / "MODIFIED_GEMINI_PACK.BIN"))
        self.val_isp_mod.set(str(out_dir / "MODIFIED_ISPBOOOT.BIN"))
        self.val_json.set(str(out_dir / "validation_report.json"))
        self._run_command(cmd, Path(self.base_dir), on_done=lambda rc: self.refresh_checksums() if rc == 0 else None)

    def run_validate(self) -> None:
        if not self._start_task("Validate"):
            return
        cmd = [
            sys.executable,
            "-u",
            str(self.validate_script),
            "--gemini",
            self.val_gemini.get(),
            "--isp",
            self.val_isp.get(),
            "--gemini-mod",
            self.val_gemini_mod.get(),
            "--isp-mod",
            self.val_isp_mod.get(),
            "--json",
            self.val_json.get(),
        ]
        self._run_command(cmd, Path(self.base_dir), on_done=lambda rc: self.refresh_checksums() if rc == 0 else None)

    def refresh_checksums(self) -> None:
        for item in self.checksum_tree.get_children():
            self.checksum_tree.delete(item)

        candidates = [
            ("Original GEMINI", Path(self.gemini_bin.get())),
            ("Original ISP", Path(self.isp_bin.get())),
            ("Validated GEMINI", Path(self.val_gemini.get())),
            ("Validated ISP", Path(self.val_isp.get())),
            ("Modified GEMINI", Path(self.val_gemini_mod.get())),
            ("Modified ISP", Path(self.val_isp_mod.get())),
        ]
        seen = set()
        for label, path in candidates:
            key = str(path.resolve()) if path.exists() else str(path)
            if key in seen:
                continue
            seen.add(key)
            if path.exists() and path.is_file():
                md5, sha, size = file_hashes(path)
                self.checksum_tree.insert(
                    "",
                    "end",
                    values=(label, str(path), f"{size:,}", md5, sha),
                )
            else:
                self.checksum_tree.insert(
                    "",
                    "end",
                    values=(label, str(path), "missing", "-", "-"),
                )

    def open_repacked_folder(self) -> None:
        out_dir = Path(self.repack_output.get())
        if not out_dir.is_absolute():
            out_dir = Path(self.repack_workdir.get()) / out_dir
        if not out_dir.exists():
            messagebox.showwarning("Not found", f"Folder does not exist:\n{out_dir}")
            return
        if sys.platform == "darwin":
            subprocess.Popen(["open", str(out_dir)])
        elif os.name == "nt":
            os.startfile(str(out_dir))  # type: ignore[attr-defined]
        else:
            subprocess.Popen(["xdg-open", str(out_dir)])


def main() -> int:
    root = Tk()
    app = FirmwareToolGUI(root)
    app.refresh_checksums()
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
