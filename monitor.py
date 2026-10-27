#!/usr/bin/env python3

import os
import sys
import re
import time
import shlex
import datetime
import html
import json
import argparse
import threading
import subprocess
import tempfile
import collections
import urllib.request
import urllib.error

WIB = datetime.timezone(datetime.timedelta(hours=7))

ANSI_RE = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]|\x1b[()][A-Z0-9]|\x1b[a-zA-Z]')
NINJA_RE = re.compile(r'\[\s*(?:(\d+)%\s+)?(\d+)\/(\d+)\](?:\s+(.*))?')
KBUILD_RE = re.compile(r'^\s*(CC|CXX|LD|AR|AS|DTC|MODPOST|OBJCOPY|GZIP|CAT|GEN|SYSMAP|LTO)\s+(?:\[M\]\s+)?([a-zA-Z0-9_\-\.\/]+)')
REPO_FETCH_RE = re.compile(r'(?:Fetching projects|Syncing work tree|Checking out projects):\s*(\d+)%')
ENV_PRODUCT_RE = re.compile(r'^TARGET_PRODUCT=(.*)$', re.M)
ENV_KVER_RE = re.compile(r'^KERNEL_VERSION=(.*)$', re.M)
ENV_VARIANT_RE = re.compile(r'^TARGET_BUILD_VARIANT=(.*)$', re.M)
PKG_ZIP_RE = re.compile(r'adding:\s+Image|FINAL_ZIP_NAME=(.*)|Package Complete:\s*(.*)')
BUILD_SUCCESS_RE = re.compile(r'#### build completed successfully\s*(?:\((.*?)\))?\s*####')
BUILD_EXIT_RE = re.compile(r'####\s*BUILD_EXIT_CODE=(\d+)\s*####')
BUILD_FAILURE_SUMMARY_RE = re.compile(r'Build Failure:\s*(\d+)\s+done,\s*(\d+)\s+failed,\s*(\d+)\s+remaining')
NINJA_EXIT_RE = re.compile(r'ninja failed with:\s*exit status (\d+)')
STEPS_FAILED_RE = re.compile(r'(\d+ steps failed: exit=\d+)')
COMPILER_ERR_RE = re.compile(r'([a-zA-Z0-9_\-\.\/]+\.(?:c|h|S|cc|cpp|rs|mk|bp)):(\d+)(?::\d+)?: (?:fatal )?error: (.*)', re.I)
FATAL_RE = re.compile(r'^FATAL:\s*(.*)$')

TERMINAL_STATES = ("COMPILING", "PATCHING", "PACKAGING", "UPLOADING", "FINISHED", "FAILED", "SUCCESS", "CANCELLED")


def load_secrets():
    candidates = [
        "/tmp/src/android/.secrets",
        os.path.expanduser("~/.secrets"),
        os.path.join(os.getcwd(), ".secrets"),
    ]
    for p in candidates:
        if not os.path.isfile(p):
            continue
        try:
            with open(p, "r", encoding="utf-8") as f:
                for line in f:
                    try:
                        parts = shlex.split(line, comments=True)
                    except ValueError:
                        continue
                    if parts and parts[0] == "export":
                        parts = parts[1:]
                    for part in parts:
                        if "=" not in part:
                            continue
                        k, v = part.split("=", 1)
                        if k.isidentifier() and k not in os.environ:
                            os.environ[k] = v
        except Exception:
            pass


def load_script_metadata(script_path: str = None):
    candidates = []
    if script_path and os.path.isfile(script_path):
        candidates.append(script_path)
    try:
        cmdline_file = f"/proc/{os.getppid()}/cmdline"
        if os.path.isfile(cmdline_file):
            with open(cmdline_file, "rb") as f:
                raw_args = [a.decode("utf-8", errors="ignore") for a in f.read().split(b"\x00") if a]
            for arg in raw_args:
                if arg.endswith(".sh") and os.path.isfile(arg):
                    candidates.append(arg)
    except Exception:
        pass
    try:
        for fn in os.listdir(os.getcwd()):
            if fn.endswith(".sh") and fn != "all.sh" and os.path.isfile(fn):
                candidates.append(fn)
    except Exception:
        pass

    var_keys = (
        "DEVICE_CODE",
        "DEVICE_DISPLAY",
        "DEVICE_NAME",
        "KERNEL_NAME",
        "ROOT_VARIANT",
        "KERNEL_BRANCH",
        "COMPILER_NAME",
        "TARGET_PRODUCT",
        "BUILD_VARIANT",
        "KERNEL_VERSION",
    )

    for p in candidates:
        try:
            with open(p, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
            for line in content.splitlines():
                s = line.strip()
                if s.startswith("export "):
                    s = s[7:].strip()
                for k in var_keys:
                    if s.startswith(k + "=") and k not in os.environ:
                        val = s.split("=", 1)[1].strip().strip('"').strip("'")
                        if val and "$" not in val:
                            os.environ[k] = val
        except Exception:
            pass


def extract_module_name(act: str) -> str:
    if not act:
        return ""
    kb_m = KBUILD_RE.search(act)
    if kb_m:
        return f"{kb_m.group(1)}: {os.path.basename(kb_m.group(2))}"[:28]
    if act.startswith("Install:"):
        return os.path.basename(act.split()[-1])[:28]
    m_colon = re.search(r':([a-zA-Z0-9_\-\.\@]+)\s+', act)
    if m_colon:
        target = m_colon.group(1)
        src_m = re.search(r'(?:clang\+\+|clang)\s+.*?\s+([a-zA-Z0-9_\-\.\/]+\.[cS])', act)
        if src_m:
            src = os.path.basename(src_m.group(1))
            return f"{target}: {src}"[:28]
        return target[:28]
    if "Building Kernel" in act or "Compiling Kernel" in act:
        return act[:28]
    tokens = act.split()
    return os.path.basename(tokens[-1])[:28] if tokens else ""


class KernelBuildState:
    def __init__(self, target_product: str = None, device: str = None, kernel_name: str = None, root_variant: str = None):
        self.lock = threading.Lock()
        self.device_code = os.environ.get("DEVICE_CODE") or ""
        self.device = device or os.environ.get("DEVICE_DISPLAY") or os.environ.get("DEVICE_NAME") or self.device_code or "Unknown Device"
        self.kernel_name = kernel_name or os.environ.get("KERNEL_NAME") or "Custom Kernel"
        self.kernel_version = os.environ.get("KERNEL_VERSION") or ""
        self.root_variant = root_variant or os.environ.get("ROOT_VARIANT") or "Standard"
        self.compiler_name = os.environ.get("COMPILER_NAME") or "Custom LLVM Clang"
        default_target = f"lineage_{self.device_code}" if self.device_code else "kernel"
        self.target_product = target_product or os.environ.get("TARGET_PRODUCT") or default_target
        self.build_variant = os.environ.get("BUILD_VARIANT") or "user"
        self.status = "INITIALIZING"
        self.phase_detail = "Initializing kernel build environment..."
        self.percentage = 0
        self.cur_tasks = 0
        self.total_tasks = 0
        self.task_rate = 0.0
        self.rate_history = []
        self.current_module = ""
        self.artifact_name = ""
        self.md5_hash = ""
        self.error_file = None
        self.error_reason = None
        self.failure_summary = None
        self.build_ok = False
        self.script_exit_code = None
        self.start_time = time.time()
        dt = datetime.datetime.fromtimestamp(self.start_time, tz=datetime.timezone.utc)
        self.start_time_str = dt.astimezone(WIB).strftime("%H:%M:%S WIB")
        self.compile_start_time = None
        self.end_time = None
        self.finished = False

    def render_progress_bar(self, width: int = 20) -> str:
        pct = max(0, min(100, int(self.percentage)))
        filled = max(0, min(width, int(width * pct / 100)))
        return "█" * filled + "░" * (width - filled)

    def update_task_rate(self, cur: int):
        now = time.time()
        self.rate_history.append((now, cur))
        while len(self.rate_history) > 2 and (now - self.rate_history[0][0]) > 45:
            self.rate_history.pop(0)
        if len(self.rate_history) >= 2:
            t_span = self.rate_history[-1][0] - self.rate_history[0][0]
            c_span = self.rate_history[-1][1] - self.rate_history[0][1]
            if t_span > 1.5 and c_span >= 0:
                self.task_rate = c_span / t_span

    def format_dur(self, sec: int) -> str:
        sec = max(0, int(sec))
        return f"{sec//3600:02d}:{(sec%3600)//60:02d}:{sec%60:02d}"

    def get_build_str(self) -> str:
        end = self.end_time or time.time()
        return self.format_dur(end - self.start_time)

    def get_eta_str(self) -> str:
        if self.task_rate <= 0 or self.total_tasks <= self.cur_tasks:
            return ""
        rem = self.total_tasks - self.cur_tasks
        sec = int(rem / self.task_rate)
        if sec < 60:
            return f"{sec}s"
        h = sec // 3600
        m = (sec % 3600) // 60
        return f"{h}h {m:02d}m" if h > 0 else f"{m}m"

    def update_from_line(self, raw_line: str):
        line = ANSI_RE.sub("", raw_line).strip()
        if not line:
            return

        with self.lock:
            fatal_m = FATAL_RE.search(line)
            if fatal_m and not self.error_reason:
                self.error_reason = fatal_m.group(1).strip()

            exit_m = BUILD_EXIT_RE.search(line)
            if exit_m:
                code = int(exit_m.group(1))
                self.script_exit_code = code
                self.finished = True
                self.end_time = time.time()
                if code == 0:
                    self.build_ok = True
                    self.status = "SUCCESS"
                    self.percentage = 100
                    self.phase_detail = "Kernel build & packaging completed"
                else:
                    self.build_ok = False
                    self.status = "FAILED"
                    self.phase_detail = "Kernel build exited with errors"
                    if not self.error_reason:
                        self.error_reason = f"Script exit code {code}"
                return

            kver_m = ENV_KVER_RE.search(line)
            if kver_m:
                self.kernel_version = kver_m.group(1).strip()

            if line.startswith("FINAL_ZIP_NAME="):
                self.artifact_name = line.split("=", 1)[1].strip()
                self.status = "PACKAGING"
                self.percentage = 100
                self.phase_detail = f"Packaging {self.artifact_name}"
                return

            if line.startswith("MD5_CHECK="):
                self.md5_hash = line.split("=", 1)[1].strip()
                return

            fetch_m = REPO_FETCH_RE.search(line)
            if fetch_m:
                if self.status not in TERMINAL_STATES:
                    self.status = "SYNCING"
                    self.percentage = int(fetch_m.group(1))
                    self.phase_detail = f"Syncing repositories ({self.percentage}%)"
                return

            if any(k in line for k in ("repo init", "repo sync", "/opt/crave/resync.sh", "Cloning device", "Cloning kernel", "Cloning clang", "Pulling LFS", "Skipping repo sync")):
                if self.status not in TERMINAL_STATES:
                    self.status = "SYNCING"
                    if "Cloning clang" in line:
                        self.phase_detail = "Cloning Alchemist LLVM toolchain"
                    elif "Cloning device" in line or "Cloning kernel" in line:
                        self.phase_detail = "Cloning device & kernel trees"
                    else:
                        self.phase_detail = "Synchronizing source tree"

            prod_m = ENV_PRODUCT_RE.search(line)
            if prod_m:
                self.target_product = prod_m.group(1).strip()
                if not self.device_code and "_" in self.target_product:
                    self.device_code = self.target_product.split("_", 1)[1]
                if self.device == "Unknown Device" and self.device_code:
                    self.device = self.device_code
                if self.status not in TERMINAL_STATES:
                    if self.status == "SYNCING":
                        self.percentage = 0
                    self.status = "CONFIGURING"
                    self.phase_detail = f"Configured {self.target_product}"

            var_m = ENV_VARIANT_RE.search(line)
            if var_m:
                self.build_variant = var_m.group(1).strip()

            if any(k in line for k in ("make kernel bootimage", "Starting Kernel Compilation")):
                if self.compile_start_time is None:
                    self.compile_start_time = time.time()
                self.status = "COMPILING"
                self.phase_detail = "Compiling kernel & bootimage"

            kb_m = KBUILD_RE.search(line)
            if kb_m and self.status not in ("FAILED", "SUCCESS", "CANCELLED"):
                if self.compile_start_time is None:
                    self.compile_start_time = time.time()
                self.status = "COMPILING"
                self.current_module = f"{kb_m.group(1)}: {os.path.basename(kb_m.group(2))}"[:28]

            ninja_m = NINJA_RE.search(line)
            if ninja_m:
                pct_str, cur_str, total_str, act_str = ninja_m.groups()
                cur = int(cur_str)
                total = int(total_str)
                if total > 10:
                    if self.compile_start_time is None:
                        self.compile_start_time = time.time()
                    if self.status not in ("FAILED", "SUCCESS", "CANCELLED", "PATCHING", "PACKAGING", "UPLOADING"):
                        self.status = "COMPILING"
                    self.cur_tasks = cur
                    self.total_tasks = total
                    if total > 0 and self.status == "COMPILING":
                        self.percentage = float(pct_str) if pct_str else ((cur / total) * 100.0)
                    self.update_task_rate(cur)
                    if act_str:
                        mod = extract_module_name(act_str.strip())
                        if mod:
                            self.current_module = mod
                    return

            if any(k in line for k in ("patch_linux", "Applying KPM patch", "oImage")):
                if self.status not in ("FAILED", "CANCELLED"):
                    self.status = "PATCHING"
                    self.percentage = 100
                    self.phase_detail = "Patching Kernel Image with KPM"
                return

            if any(k in line for k in ("AnyKernel3", "Packaging AnyKernel3", "Uploading kernel zip")):
                if self.status not in ("FAILED", "CANCELLED"):
                    self.status = "PACKAGING"
                    self.percentage = 100
                    if "Uploading" in line:
                        self.phase_detail = "Uploading flashable zip to Telegram"
                    else:
                        self.phase_detail = "Packaging AnyKernel3 flashable zip"
                return

            succ_m = BUILD_SUCCESS_RE.search(line)
            if succ_m:
                self.build_ok = True
                self.percentage = 100
                if self.status not in ("PATCHING", "PACKAGING", "FAILED"):
                    self.status = "PACKAGING"
                    self.phase_detail = "Kernel compiled, preparing AnyKernel3"
                return

            fail_m = BUILD_FAILURE_SUMMARY_RE.search(line)
            if fail_m:
                self.status = "FAILED"
                self.failure_summary = f"{fail_m.group(1)} done, {fail_m.group(2)} failed"
                self.phase_detail = "Kernel build stopped with errors"
                return

            steps_m = STEPS_FAILED_RE.search(line)
            if steps_m and self.status != "SUCCESS":
                self.status = "FAILED"
                self.failure_summary = steps_m.group(1)

            ninja_exit_m = NINJA_EXIT_RE.search(line)
            if ninja_exit_m and self.status != "SUCCESS":
                self.status = "FAILED"
                if not self.error_reason:
                    self.error_reason = f"Ninja exit status {ninja_exit_m.group(1)}"

            err_m = COMPILER_ERR_RE.search(line)
            if err_m:
                fpath, line_no, reason = err_m.group(1), err_m.group(2), err_m.group(3).strip()
                if not self.error_file:
                    self.error_file = f"{os.path.basename(fpath)}:{line_no}"
                if not self.error_reason:
                    self.error_reason = reason

            if "FAILED:" in line and self.status != "SUCCESS":
                self.status = "FAILED"
                failed_target = line.split("FAILED:", 1)[1].strip()
                if not self.error_file and failed_target:
                    self.error_file = os.path.basename(failed_target.split()[0])[:28]

            if ("make: *** [" in line or "ninja: build stopped" in line) and self.status != "SUCCESS":
                self.status = "FAILED"

    def render_dashboard(self) -> str:
        with self.lock:
            title_map = {
                "INITIALIZING": "KERNEL INITIALIZING // CRAVE CLOUD",
                "SYNCING": "KERNEL SOURCE SYNC // CRAVE CLOUD",
                "CONFIGURING": "CONFIGURING KERNEL // CRAVE CLOUD",
                "COMPILING": "KERNEL COMPILATION // CRAVE CLOUD",
                "PATCHING": "KPM IMAGE PATCHING // CRAVE CLOUD",
                "PACKAGING": "ANYKERNEL3 PACKAGING // CRAVE CLOUD",
                "SUCCESS": "KERNEL BUILD COMPLETED // SUCCESS",
                "FAILED": "KERNEL BUILD STOPPED // FAILED",
                "CANCELLED": "KERNEL BUILD STOPPED // CANCELLED",
            }
            header = title_map.get(self.status, "KERNEL BUILD MONITOR // CRAVE CLOUD")
            dev_str = f"{self.device} ({self.device_code})" if self.device_code and self.device_code not in self.device else self.device
            kver_str = f"{self.kernel_name} ({self.kernel_version})" if self.kernel_version else self.kernel_name

            lines = [
                f"<b>{header}</b>",
                "━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
                f"<b>Device  :</b> {html.escape(dev_str)}",
                f"<b>Kernel  :</b> {html.escape(kver_str)}",
                f"<b>Root    :</b> <code>{html.escape(self.root_variant)}</code>",
                f"<b>Compiler:</b> {html.escape(self.compiler_name)}",
                f"<b>Status  :</b> <code>{self.status}</code>",
                f"<b>Stage   :</b> {html.escape(self.phase_detail or self.status)}",
                ""
            ]

            pct = max(0, min(100, int(self.percentage)))
            bar = self.render_progress_bar(width=20)
            b_str = self.get_build_str()
            now_wib = datetime.datetime.now(tz=WIB).strftime("%H:%M:%S WIB")

            pre_lines = [f"[{bar}] {pct:>3d}%"]
            if self.status in ("INITIALIZING", "SYNCING", "CONFIGURING"):
                pre_lines.append(f"Elapsed : {b_str}")
                if self.phase_detail:
                    pre_lines.append(f"Phase   : {self.phase_detail[:28]}")
                pre_lines.append(f"Started : {self.start_time_str}")
                pre_lines.append(f"Updated : {now_wib}")
            elif self.status == "COMPILING":
                if self.total_tasks > 0:
                    pre_lines.append(f"Tasks   : {self.cur_tasks:,} / {self.total_tasks:,}")
                if self.task_rate > 0:
                    rate_str = f"{self.task_rate:.1f} tasks/s"
                    eta = self.get_eta_str()
                    if eta:
                        rate_str += f" | ETA: {eta}"
                    pre_lines.append(f"Speed   : {rate_str}")
                pre_lines.append(f"Elapsed : {b_str}")
                if self.current_module:
                    pre_lines.append(f"Target  : {self.current_module[:28]}")
                pre_lines.append(f"Started : {self.start_time_str}")
                pre_lines.append(f"Updated : {now_wib}")
            elif self.status in ("PATCHING", "PACKAGING"):
                pre_lines.append(f"Elapsed : {b_str}")
                if self.artifact_name:
                    pre_lines.append(f"Zip     : {self.artifact_name}")
                pre_lines.append(f"Started : {self.start_time_str}")
                pre_lines.append(f"Updated : {now_wib}")
            elif self.status == "SUCCESS":
                if self.total_tasks > 0:
                    pre_lines.append(f"Tasks   : {self.total_tasks:,} / {self.total_tasks:,} done")
                pre_lines.append(f"Total   : {b_str}")
                if self.artifact_name:
                    pre_lines.append(f"Zip     : {self.artifact_name}")
                if self.md5_hash:
                    pre_lines.append(f"MD5     : {self.md5_hash}")
                pre_lines.append(f"Started : {self.start_time_str}")
            elif self.status in ("FAILED", "CANCELLED"):
                if self.total_tasks > 0:
                    pre_lines.append(f"Tasks   : {self.cur_tasks:,} / {self.total_tasks:,}")
                pre_lines.append(f"Elapsed : {b_str}")
                if self.failure_summary:
                    pre_lines.append(f"Summary : {self.failure_summary[:28]}")
                if self.error_file:
                    pre_lines.append(f"Error   : {self.error_file[:28]}")
                if self.error_reason:
                    pre_lines.append(f"Reason  : {self.error_reason[:28]}")
                pre_lines.append(f"Started : {self.start_time_str}")

            lines.append("<pre>")
            lines.append(html.escape("\n".join(pre_lines)))
            lines.append("</pre>")

            return "\n".join(lines)


class TelegramNotifier:
    def __init__(self, token: str, chat_id: str):
        self.token = token
        self.chat_id = str(chat_id)
        self.message_id = None
        self.last_sent_text = None
        self.rate_limit_until = 0.0
        self._last_err = None
        self.edit_lock = threading.Lock()

    def _log(self, msg: str):
        msg = str(msg).replace(self.token, "***")
        if msg == self._last_err:
            return
        self._last_err = msg
        try:
            sys.stderr.write(f"[monitor] {msg}\n")
            sys.stderr.flush()
        except Exception:
            pass

    def _build_markup(self, show_button: bool = True) -> dict:
        if show_button:
            return {"inline_keyboard": [[{"text": "🔄 Refresh", "callback_data": "refresh_status"}]]}
        return {"inline_keyboard": []}

    def send_initial_message(self, initial_text: str, show_button: bool = True) -> bool:
        with self.edit_lock:
            if self.message_id:
                return True
            url = f"https://api.telegram.org/bot{self.token}/sendMessage"
            payload = {
                "chat_id": self.chat_id,
                "text": initial_text,
                "parse_mode": "HTML",
                "disable_web_page_preview": True,
                "reply_markup": self._build_markup(show_button),
            }
            req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    res = json.loads(resp.read().decode("utf-8"))
                    if res.get("ok"):
                        self.message_id = res["result"]["message_id"]
                        self.last_sent_text = initial_text
                        self._last_err = None
                        return True
                    self._log(f"sendMessage not ok: {res}")
            except urllib.error.HTTPError as e:
                body = e.read().decode("utf-8", errors="ignore")[:200]
                self._log(f"sendMessage HTTP {e.code}: {body}")
                if e.code == 429:
                    self.rate_limit_until = time.time() + 10
            except Exception as e:
                self._log(f"sendMessage {type(e).__name__}: {e}")
            return False

    def edit_message(self, new_text: str, force: bool = False, show_button: bool = True) -> bool:
        if not self.message_id:
            return self.send_initial_message(new_text, show_button=show_button)
        with self.edit_lock:
            if not force and new_text == self.last_sent_text:
                return True
            if not force and time.time() < self.rate_limit_until:
                return False
            url = f"https://api.telegram.org/bot{self.token}/editMessageText"
            payload = {
                "chat_id": self.chat_id,
                "message_id": self.message_id,
                "text": new_text,
                "parse_mode": "HTML",
                "disable_web_page_preview": True,
                "reply_markup": self._build_markup(show_button),
            }
            req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    res = json.loads(resp.read().decode("utf-8"))
                    if res.get("ok"):
                        self.last_sent_text = new_text
                        self._last_err = None
                        return True
                    self._log(f"editMessageText not ok: {res}")
            except urllib.error.HTTPError as e:
                resp_body = e.read().decode("utf-8", errors="ignore")
                if e.code == 400 and "message is not modified" in resp_body:
                    self.last_sent_text = new_text
                    return True
                self._log(f"editMessageText HTTP {e.code}: {resp_body[:200]}")
                if e.code == 429:
                    self.rate_limit_until = time.time() + 15
            except Exception as e:
                self._log(f"editMessageText {type(e).__name__}: {e}")
            return False

    def answer_callback(self, callback_query_id: str, text: str = "Status refreshed!"):
        url = f"https://api.telegram.org/bot{self.token}/answerCallbackQuery"
        payload = {"callback_query_id": callback_query_id, "text": text, "show_alert": False}
        req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=8) as resp:
                resp.read()
        except Exception:
            pass

    def send_document(self, file_path: str, caption: str = "", tail_lines: int = 3000) -> bool:
        if not os.path.isfile(file_path):
            return False
        url = f"https://api.telegram.org/bot{self.token}/sendDocument"
        tmp_path = None
        try:
            with open(file_path, "r", encoding="utf-8", errors="replace") as f:
                tail = collections.deque(f, maxlen=tail_lines)
            tmp = tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt", prefix="kernel-log-", encoding="utf-8")
            tmp.writelines(tail)
            tmp.close()
            tmp_path = tmp.name

            result = subprocess.run(
                ["curl", "-s", "-X", "POST", url,
                 "-F", f"chat_id={self.chat_id}",
                 "-F", f"document=@{tmp_path};filename=kernel-build-log.txt",
                 "--form-string", f"caption={caption}",
                 "--form-string", "parse_mode=HTML"],
                check=False, capture_output=True, timeout=180,
            )
            if result.returncode != 0:
                self._log(f"sendDocument curl exit {result.returncode}")
                return False
            try:
                ok = bool(json.loads(result.stdout.decode("utf-8", errors="ignore")).get("ok"))
                if not ok:
                    self._log(f"sendDocument not ok: {result.stdout.decode('utf-8', errors='ignore')[:200]}")
                return ok
            except Exception:
                return False
        except Exception as e:
            self._log(f"sendDocument {type(e).__name__}: {e}")
            return False
        finally:
            if tmp_path and os.path.exists(tmp_path):
                try:
                    os.remove(tmp_path)
                except Exception:
                    pass


def telegram_callback_worker(state: KernelBuildState, notifier: TelegramNotifier, stop_event: threading.Event):
    offset = 0
    try:
        init_url = f"https://api.telegram.org/bot{notifier.token}/getUpdates?offset=-1&timeout=0"
        with urllib.request.urlopen(init_url, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("ok") and data.get("result"):
                offset = data["result"][-1]["update_id"] + 1
    except Exception:
        pass

    while not stop_event.is_set():
        try:
            url = f"https://api.telegram.org/bot{notifier.token}/getUpdates"
            payload = {
                "offset": offset,
                "timeout": 4,
                "allowed_updates": ["callback_query"],
            }
            req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if not data.get("ok"):
                    time.sleep(2)
                    continue
                for upd in data.get("result", []):
                    offset = max(offset, upd.get("update_id", 0) + 1)
                    cb = upd.get("callback_query")
                    if not cb:
                        continue
                    cb_id = cb.get("id")
                    cb_data = cb.get("data")
                    msg = cb.get("message") or {}
                    msg_id = msg.get("message_id")
                    if cb_data == "refresh_status" and (not notifier.message_id or msg_id == notifier.message_id):
                        with state.lock:
                            is_done = state.finished
                            st = state.status
                            pct = int(state.percentage)
                        notifier.edit_message(state.render_dashboard(), force=True, show_button=not is_done)
                        if cb_id:
                            notifier.answer_callback(cb_id, f"Refreshed: {st} ({pct}%)")
        except Exception:
            stop_event.wait(timeout=2.0)


def telegram_updater_worker(state: KernelBuildState, notifier: TelegramNotifier, interval: float, stop_event: threading.Event):
    while not stop_event.is_set():
        try:
            with state.lock:
                is_done = state.finished
            notifier.edit_message(state.render_dashboard(), show_button=not is_done)
        except Exception:
            pass
        stop_event.wait(timeout=interval)

    try:
        for attempt in range(4):
            if notifier.edit_message(state.render_dashboard(), force=True, show_button=False):
                break
            time.sleep(3 + attempt * 2)
    except Exception:
        pass


def process_stream(stream, state: KernelBuildState, capture=None):
    def handle(line_str: str):
        sys.stdout.write(line_str + "\n")
        sys.stdout.flush()
        if capture:
            try:
                capture.write(ANSI_RE.sub("", line_str) + "\n")
            except Exception:
                pass
        state.update_from_line(line_str)

    buffer = bytearray()
    while True:
        chunk = stream.read(4096)
        if not chunk:
            break
        buffer.extend(chunk)
        while True:
            nl = buffer.find(b"\n")
            cr = buffer.find(b"\r")
            idx = min(nl, cr) if (nl != -1 and cr != -1) else max(nl, cr)
            if idx == -1:
                break
            line_bytes = buffer[:idx]
            buffer = buffer[idx + 1:]
            try:
                line_str = line_bytes.decode("utf-8", errors="replace")
            except Exception:
                continue
            handle(line_str)

    if buffer:
        try:
            handle(buffer.decode("utf-8", errors="replace"))
        except Exception:
            pass


def tail_log_file(file_path: str, state: KernelBuildState):
    parent_pid = os.getppid()
    wait_start = time.time()
    while not os.path.isfile(file_path):
        if os.getppid() != parent_pid or (time.time() - wait_start) > 60:
            return
        time.sleep(0.2)

    with open(file_path, "rb") as f:
        buffer = bytearray()
        while True:
            chunk = f.read(4096)
            if chunk:
                buffer.extend(chunk)
                while True:
                    nl = buffer.find(b"\n")
                    cr = buffer.find(b"\r")
                    idx = min(nl, cr) if (nl != -1 and cr != -1) else max(nl, cr)
                    if idx == -1:
                        break
                    line_bytes = buffer[:idx]
                    buffer = buffer[idx + 1:]
                    try:
                        line_str = line_bytes.decode("utf-8", errors="replace")
                    except Exception:
                        continue
                    state.update_from_line(line_str)
                    with state.lock:
                        if state.script_exit_code is not None:
                            return
            else:
                with state.lock:
                    if state.script_exit_code is not None:
                        return
                if os.getppid() != parent_pid:
                    if buffer:
                        try:
                            state.update_from_line(buffer.decode("utf-8", errors="replace"))
                        except Exception:
                            pass
                    return
                time.sleep(0.2)


def main():
    parser = argparse.ArgumentParser(description="Universal Kernel Build Progress Monitor for Telegram")
    parser.add_argument("--token", default=None, help="Telegram Bot Token")
    parser.add_argument("--chat-id", default=None, help="Telegram Chat ID (Personal or Admin)")
    parser.add_argument("--target", default=None, help="Target product/device name")
    parser.add_argument("--device", default=None, help="Device display name")
    parser.add_argument("--kernel", default=None, help="Kernel project name")
    parser.add_argument("--root", default=None, help="Root solution variant")
    parser.add_argument("--interval", type=float, default=5.0, help="Auto-refresh interval in seconds")
    parser.add_argument("--file", default=None, help="Path to build log file to tail (e.g. log.txt)")
    parser.add_argument("--script", default=None, help="Optional build bash script path to inspect for metadata")
    parser.add_argument("--capture", default=os.environ.get("MONITOR_CAPTURE", "monitor-stream.log"),
                        help="Local file path to save a copy of the build stream output")
    args = parser.parse_args()

    load_secrets()
    load_script_metadata(args.script)
    token = args.token or os.environ.get("TG_BOT_TOKEN") or os.environ.get("TELEGRAM_BOT_TOKEN")
    chat_id = args.chat_id or os.environ.get("TG_ADMIN_CHAT_ID") or os.environ.get("TG_BUILD_CHAT_ID") or os.environ.get("TG_CHAT_ID")

    tg_enabled = bool(token and chat_id)
    if not tg_enabled:
        sys.stderr.write("[monitor] Telegram disabled: TG_BOT_TOKEN or chat ID not found\n")

    state = KernelBuildState(target_product=args.target, device=args.device, kernel_name=args.kernel, root_variant=args.root)
    worker = None
    cb_worker = None
    notifier = None
    stop_event = threading.Event()

    if tg_enabled:
        notifier = TelegramNotifier(token=token, chat_id=chat_id)
        notifier.send_initial_message(state.render_dashboard(), show_button=True)
        worker = threading.Thread(target=telegram_updater_worker, args=(state, notifier, args.interval, stop_event), daemon=True)
        worker.start()
        cb_worker = threading.Thread(target=telegram_callback_worker, args=(state, notifier, stop_event), daemon=True)
        cb_worker.start()

    capture = None
    if not args.file:
        try:
            capture = open(args.capture, "w", encoding="utf-8", errors="replace", buffering=1)
        except Exception:
            capture = None

    exit_code = 0
    try:
        if args.file:
            tail_log_file(args.file, state)
        else:
            process_stream(sys.stdin.buffer, state, capture)
    except KeyboardInterrupt:
        with state.lock:
            state.status, state.phase_detail = "CANCELLED", "Build interrupted by user"
        exit_code = 130
    finally:
        if capture:
            try:
                capture.close()
            except Exception:
                pass

        with state.lock:
            state.finished, state.end_time = True, time.time()
            if exit_code == 0 and state.script_exit_code not in (None, 0):
                exit_code = state.script_exit_code

            if exit_code != 0:
                if state.status not in ("FAILED", "CANCELLED"):
                    state.status = "FAILED"
                if state.error_reason is None and state.failure_summary is None:
                    state.error_reason = f"Process exited with code {exit_code}"
            elif state.build_ok:
                state.status = "SUCCESS"
                state.percentage = 100
                if state.phase_detail != "Kernel build & packaging completed":
                    state.phase_detail = "Kernel build & packaging completed"
            else:
                state.status = "FAILED"
                exit_code = 1
                if state.error_reason is None and state.failure_summary is None:
                    state.error_reason = "Stream ended w/o success"

        stop_event.set()
        if worker:
            worker.join(timeout=30.0)

        if tg_enabled and notifier:
            candidates = []
            if exit_code != 0:
                candidates.append("out/error.log")
            if args.file:
                candidates.append(args.file)
            candidates.append("log.txt")
            if not args.file:
                candidates.append(args.capture)
            for cand in candidates:
                if cand and os.path.isfile(cand) and os.path.getsize(cand) > 0:
                    notifier.send_document(cand, f"<b>Kernel Build Log ({html.escape(state.root_variant)})</b>")
                    break

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
