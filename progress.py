#!/usr/bin/env python3
"""backup／restore 的進度顯示。由 common.sh 呼叫，不單獨執行。

畫面一律畫在 stderr，且只在 stderr 是終端機時才會被呼叫（見 common.sh 的 show_progress）。

  scan  <標籤>          讀 rsync 試跑（-n --out-format='%i %l'）的輸出，邊比對邊顯示經過時間與
                        待傳量；結束時在 stdout 印出待傳位元組數，作為後兩種模式的總量
  rsync <標籤> <總量>    讀 rsync --info=progress2 的輸出，以試跑得到的總量重算百分比與剩餘時間。
                        不用 rsync 自己的百分比：它以整棵樹為分母，未變動的檔案又不計入已完成，
                        增量同步跑完常只停在個位數百分比，剩餘時間也跟著失準
  pipe  <標籤> <總量>    夾在 tar 打包與解壓之間，stdin 原樣轉送到 stdout 並計量
  flush                 執行 sync，顯示尚未寫入磁碟的資料量
"""
import collections
import os
import sys
import threading
import time
import unicodedata

TICK = 0.5        # 畫面更新間隔（秒）
RATE_WINDOW = 5   # 速度取最近幾秒的平均，太短則剩餘時間跳動，太長則反應遲鈍


def human(n):
    for u in "BKMGT":
        if n < 1024 or u == "T":
            return f"{n:.0f}{u}" if u == "B" else f"{n:.1f}{u}"
        n /= 1024


def hms(s):
    s = int(s)
    h, s = divmod(s, 3600)
    m, s = divmod(s, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def columns():
    # 部分虛擬終端機（script、某些 IDE 面板）回報寬度 0，視同取不到
    try:
        return os.get_terminal_size(2).columns or 80
    except OSError:
        return 80


def draw(text):
    # 超出終端機寬度會折行，\r 就回不到行首而洗出一整串，故先截斷
    cols = max(columns() - 1, 1)
    while text and width(text) > cols:
        text = text[:-1]
    sys.stderr.write("\r" + text + "\x1b[K")
    sys.stderr.flush()


def clear():
    sys.stderr.write("\r\x1b[K")
    sys.stderr.flush()


class Meter:
    """背景每 TICK 秒重畫一次，即使資料停住（例如 rsync 正在比對大量未變動的檔案）
    經過時間仍會走動，看得出還活著。"""

    def __init__(self, render):
        self.render = render
        self.start = time.monotonic()
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def elapsed(self):
        return time.monotonic() - self.start

    def _loop(self):
        while not self.stop.wait(TICK):
            with self.lock:
                draw(self.render(self))

    def close(self):
        self.stop.set()
        self.thread.join()
        clear()


class Transfer:
    """有總量的傳輸（rsync／pipe 共用）：進度條、百分比、速度、剩餘時間。"""

    def __init__(self, label, total):
        self.label = label
        self.total = total
        self.done = 0
        self.samples = collections.deque([(time.monotonic(), 0)])
        self.meter = Meter(self.render)

    def update(self, done):
        self.done = done

    def rate(self):
        now = time.monotonic()
        self.samples.append((now, self.done))
        while len(self.samples) > 2 and now - self.samples[0][0] > RATE_WINDOW:
            self.samples.popleft()
        t0, d0 = self.samples[0]
        return (self.done - d0) / (now - t0) if now > t0 else 0

    def render(self, meter):
        el = meter.elapsed()
        rate = self.rate()
        head = f"  [{self.label}] "
        if self.total <= 0:
            # 試跑判定無須傳輸，只剩屬性、目錄等比對，沒有可算的分母
            return f"{head}同步中… {hms(el)}"
        # 總量是試跑時的估計（tar 另有檔頭），未結束前不顯示 100%
        frac = min(self.done / self.total, 0.999)
        eta = hms((self.total - self.done) / rate) if rate > 0 and self.done < self.total else "--"
        tail = f" {int(frac * 100):3d}%  {human(self.done)}/{human(self.total)}  {human(rate)}/s  剩 {eta}  已 {hms(el)}"
        bar_w = min(30, columns() - 1 - width(head) - width(tail))
        if bar_w < 5:
            return head + tail.lstrip()
        fill = int(frac * bar_w)
        return head + "█" * fill + "░" * (bar_w - fill) + tail

    def finish(self):
        self.meter.close()
        el = self.meter.elapsed()
        if self.done > 0:
            avg = self.done / el if el > 0 else 0
            sys.stderr.write(f"  └ 傳輸 {human(self.done)}，用時 {hms(el)}，平均 {human(avg)}/s\n")
        else:
            sys.stderr.write(f"  └ 無須傳輸，用時 {hms(el)}\n")


def mode_scan(label):
    files = 0
    size = 0

    def render(meter):
        return f"  [{label}] 比對中… {hms(meter.elapsed())}  待傳 {files} 檔 {human(size)}"

    meter = Meter(render)
    try:
        for line in sys.stdin.buffer:
            parts = line.split()
            # 只計真正要搬資料的一般檔案（itemize 開頭 >f 或 <f）；
            # 目錄、符號連結、本地建立的硬連結都不傳內容
            if len(parts) >= 2 and parts[0][:1] in (b">", b"<") and parts[0][1:2] == b"f":
                try:
                    size += int(parts[1].replace(b",", b""))
                    files += 1
                except ValueError:
                    pass
    finally:
        meter.close()
        print(size)


def mode_rsync(label, total):
    t = Transfer(label, total)
    buf = b""
    try:
        while True:
            chunk = os.read(0, 65536)
            if not chunk:
                break
            buf += chunk
            # progress2 以 \r 覆寫同一行，取最後一段完整的記錄
            *records, buf = buf.replace(b"\r", b"\n").split(b"\n")
            for r in reversed(records):
                f = r.split()
                if f:
                    n = f[0].replace(b",", b"")
                    if n.isdigit():
                        t.update(int(n))
                        break
    finally:
        t.finish()


def mode_pipe(label, total):
    t = Transfer(label, total)
    done = 0
    try:
        while True:
            chunk = os.read(0, 1 << 20)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                view = view[os.write(1, view):]
            done += len(chunk)
            t.update(done)
    finally:
        t.finish()


def dirty_bytes():
    # 系統整體尚未落到磁碟的量；sync 期間只剩本次備份寫入的部分占大宗
    n = 0
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith(("Dirty:", "Writeback:")):
                    n += int(line.split()[1]) * 1024
    except OSError:
        pass
    return n


def mode_flush():
    def render(meter):
        return f"  寫入磁碟中… 剩 {human(dirty_bytes())}  已 {hms(meter.elapsed())}"

    meter = Meter(render)
    try:
        os.sync()
    finally:
        meter.close()
    sys.stderr.write(f"已寫入磁碟，用時 {hms(meter.elapsed())}\n")


def main():
    mode, args = sys.argv[1], sys.argv[2:]
    if mode == "scan":
        mode_scan(args[0])
    elif mode == "rsync":
        mode_rsync(args[0], int(args[1] or 0))
    elif mode == "pipe":
        mode_pipe(args[0], int(args[1] or 0))
    elif mode == "flush":
        mode_flush()
    else:
        sys.exit(f"progress.py: 未知模式 {mode}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        clear()
        sys.exit(130)
    except BrokenPipeError:
        # 下游（tar 解壓）先掛了，由呼叫端依 PIPESTATUS 回報
        clear()
        sys.exit(1)
