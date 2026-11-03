"""Colab VM 上で、学習に使うモデルをダウンロードする。手元の model-download.sh と学習の開始処理が ssh 越しに起動する。

    python3 model_download.py download --models DIR [--drive-models DIR] --state DIR
                                       --url URL [--filename NAME] [--to-drive] [--tokens-stdin]
    python3 model_download.py ensure   --models DIR [--drive-models DIR] --state DIR
                                       --job FILE [--to-drive] [--tokens-stdin]
    python3 model_download.py missing  --models DIR [--drive-models DIR] --state DIR --job FILE

ensure は job.json の一覧のうち、VM に無いファイルだけを用意する。ドライブにあればそこからコピーし、無ければダウンロードする。
missing は、VM にもドライブにも無く、URL も分からないファイルを 1 行に 1 つ「キー<TAB>ファイル名」で書く。
ランタイムの models に .part として書き、書き終えてから正しい名前にする。--to-drive なら、続けて Google ドライブにもコピーする。
"""

import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, unquote, urljoin, urlsplit
import urllib.request

PICKLE_SUFFIXES = {".ckpt", ".pt", ".pth", ".bin", ".pkl"}

TEXTS = {
    "ja": {
        "bad_url": "https で始まる URL を指定してください。",
        "hf_url": "Hugging Face は、ファイルのページの URL を指定してください。例: https://huggingface.co/<作者>/<リポジトリ>/blob/main/<ファイル>",
        "civitai_url": "Civitai は、バージョンを選んだモデルのページの URL か、ダウンロードの URL を指定してください。",
        "bad_filename": "ファイル名にはフォルダーを含められません: {name}",
        "pickle": "pickle 形式のファイルは、読み込むとコードを実行できるので扱いません: {name}。safetensors を使ってください。",
        "not_https": "HTTPS ではない転送先には接続しません。",
        "private": "内部のアドレスには接続しません。",
        "unresolved": "接続先の名前を解決できません: {host}",
        "too_many_redirects": "転送が多すぎます。",
        "http_error": "ダウンロードに失敗しました。HTTP {status}{hint}",
        "hint_auth": "。認証が必要なモデルなら、config/config.local.env に {token} を書いてください",
        "not_a_model": "モデルではなく、Web ページが返ってきました。URL を確かめてください。認証が必要なモデルかもしれません。",
        "empty": "ダウンロードしたファイルが空でした。",
        "no_filename": "ファイル名が分かりません。ファイル名を指定してください。",
        "exists": "同じ名前のファイルが既にあります。上書きはしません: {path}",
        "no_space": "ランタイムのディスクの空きが足りません。必要 {need}、空き {free}。",
        "busy": "ほかのダウンロードが進んでいます。終わってからもう一度実行してください。",
        "no_drive": "Google ドライブがマウントされていないので、ドライブには保存できません。",
        "connection": "接続できませんでした: {reason}",
        "cancelled": "ダウンロードを中止しました。",
        "downloading": "ダウンロード中",
        "copying": "ドライブへコピー中",
        "restoring": "ドライブから取得中",
        "saved_runtime": "ランタイムに保存しました: {path}",
        "saved_drive": "ランタイムと Google ドライブに保存しました: {path}",
        "have": "用意できています: {name}",
        "from_drive": "ドライブのモデルを使います: {name}",
        "unknown_model": "{key} のモデルが VM にありません: {path}\n  config/models.txt に URL を足すか、model-download で VM にダウンロードしてください。",
    },
    "en": {
        "bad_url": "Give a URL that starts with https.",
        "hf_url": "For Hugging Face, give the URL of the file page, such as https://huggingface.co/<owner>/<repo>/blob/main/<file>",
        "civitai_url": "For Civitai, give the URL of a model page with a version selected, or a download URL.",
        "bad_filename": "The file name cannot contain a folder: {name}",
        "pickle": "Pickle files can run code when loaded and are not accepted: {name}. Use safetensors.",
        "not_https": "A non-HTTPS address is not followed.",
        "private": "An internal address is not followed.",
        "unresolved": "Cannot resolve the host name: {host}",
        "too_many_redirects": "Too many redirects.",
        "http_error": "The download failed with HTTP {status}{hint}",
        "hint_auth": ". If the model needs authentication, put {token} in config/config.local.env",
        "not_a_model": "A web page came back instead of a model. Check the URL. The model may need authentication.",
        "empty": "The downloaded file was empty.",
        "no_filename": "The file name is unknown. Give a file name.",
        "exists": "A file with the same name already exists and is not overwritten: {path}",
        "no_space": "Not enough free disk space on the runtime. Needed {need}, free {free}.",
        "busy": "Another download is in progress. Try again when it is done.",
        "no_drive": "Google Drive is not mounted, so the model cannot be saved there.",
        "connection": "Could not connect: {reason}",
        "cancelled": "The download was cancelled.",
        "downloading": "Downloading",
        "copying": "Copying to Drive",
        "restoring": "Copying from Drive",
        "saved_runtime": "Saved on the runtime: {path}",
        "saved_drive": "Saved on the runtime and on Google Drive: {path}",
        "have": "Ready: {name}",
        "from_drive": "Using the model on Drive: {name}",
        "unknown_model": "The model for {key} is not on the VM: {path}\n  Add its URL to config/models.txt, or download it to the VM with model-download.",
    },
}


def t(text_key, **values):
    lang = "ja" if os.environ.get("MSG_LANG") == "ja" else "en"
    return TEXTS[lang][text_key].format(**values)


class Failure(Exception):
    """利用者に見せる理由のある失敗。"""


def size_text(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


# ---- URL ----

def parse_model_url(url):
    """ブラウザからコピーした URL から、ダウンロードの URL と、分かればファイル名と、使うトークンの名前を返す。"""
    parsed = urlsplit(url.strip())
    parts = [unquote(part) for part in parsed.path.split("/") if part]
    host = (parsed.hostname or "").removeprefix("www.")
    if parsed.scheme != "https":
        raise Failure(t("bad_url"))
    if host == "huggingface.co":
        if len(parts) < 5 or parts[2] not in {"resolve", "blob"} or not re.fullmatch(r"[A-Za-z0-9_.-]+", parts[0] + parts[1]):
            raise Failure(t("hf_url"))
        file = "/".join(parts[4:])
        if any(p in {"", ".", ".."} for p in parts[4:]):
            raise Failure(t("hf_url"))
        return (f"https://huggingface.co/{parts[0]}/{parts[1]}/resolve/{quote(parts[3], safe='')}/{quote(file, safe='/')}",
                parts[-1], "HF_TOKEN")
    if host == "civitai.com":
        version = parse_qs(parsed.query).get("modelVersionId", [""])[0]
        if parts[:3] == ["api", "download", "models"] and len(parts) == 4:
            version = parts[3]
        elif parts[:1] != ["models"] or not version:
            raise Failure(t("civitai_url"))
        if not re.fullmatch(r"[1-9][0-9]*", version):
            raise Failure(t("civitai_url"))
        return "https://civitai.com/api/download/models/" + version, "", "CIVITAI_TOKEN"
    return url.strip(), parts[-1] if parts else "", ""


def checked_https(url):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.port not in {None, 443}:
        raise Failure(t("not_https"))
    if parsed.hostname in {"localhost", "metadata.google.internal"}:
        raise Failure(t("private"))
    try:
        addresses = {ipaddress.ip_address(parsed.hostname)}
    except ValueError:
        # 公開されていそうな名前でも、VM の内部のサービスを指していることがある
        try:
            found = socket.getaddrinfo(parsed.hostname, 443, type=socket.SOCK_STREAM)
        except OSError:
            raise Failure(t("unresolved", host=parsed.hostname)) from None
        addresses = {ipaddress.ip_address(item[4][0].split("%")[0]) for item in found}
    if any(not ip.is_global for ip in addresses):
        raise Failure(t("private"))
    return parsed


def served_filename(headers):
    """応答が示すファイル名。普通の名前でなければ空。"""
    from email.message import EmailMessage
    message = EmailMessage()
    try:
        message["Content-Disposition"] = headers.get("Content-Disposition") or "attachment"
        name = message.get_filename() or ""
    except (ValueError, TypeError, LookupError):
        return ""
    name = name.replace("\\", "/").rsplit("/", 1)[-1]
    return name if re.fullmatch(r"[^\x00-\x1f:/]{1,200}", name) and not name.startswith(".") else ""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


# 環境変数のプロキシや .netrc は使わず、転送は自分でたどる
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


def open_download(url, token):
    """転送をたどってダウンロードの応答を返す。トークンは最初の接続先にだけ送る。"""
    first_host = checked_https(url).hostname
    current = url
    for _ in range(11):
        parsed = checked_https(current)
        request = urllib.request.Request(current, headers={"User-Agent": "musubi-tuner-colab-cli/1"})
        if token and parsed.hostname == first_host:
            request.add_header("Authorization", "Bearer " + token)
        try:
            response = _OPENER.open(request, timeout=60)
        except HTTPError as error:
            if error.code in {301, 302, 303, 307, 308}:
                location = error.headers.get("Location")
                error.close()
                if not location:
                    raise Failure(t("too_many_redirects")) from None
                current = urljoin(current, location)
                continue
            raise
        content_type = (response.headers.get("Content-Type") or "").lower()
        if "text/html" in content_type or "application/json" in content_type:
            response.close()
            raise Failure(t("not_a_model"))
        return response
    raise Failure(t("too_many_redirects"))


def safe_filename(name):
    if "/" in name or "\\" in name:
        raise Failure(t("bad_filename", name=name))
    if not re.fullmatch(r"[^\x00-\x1f:]{1,200}", name) or name.startswith("."):
        raise Failure(t("bad_filename", name=name))
    if Path(name).suffix.lower() in PICKLE_SUFFIXES:
        raise Failure(t("pickle", name=name))
    return name


# ---- 進み具合 ----

class Progress:
    """進み具合を 1 行のバーに出す。ssh 越しだと標準出力と標準エラーは別々に届き、順番が入れ替わるので、標準出力に書く。"""

    def __init__(self):
        self.started = self.last = time.monotonic()
        self.label, self.done, self.total = "", 0, 0
        self.open = False

    def start(self, label, total):
        self.end_line()
        self.label, self.done, self.total = label, 0, total
        self.started = time.monotonic()
        self.draw()

    def draw(self):
        speed = self.done / max(time.monotonic() - self.started, 0.001)
        if self.total:
            filled = int(30 * self.done / self.total)
            line = (f"{self.label} [{'#' * filled}{'.' * (30 - filled)}] {self.done * 100 / self.total:5.1f}% "
                    f"{size_text(self.done)} / {size_text(self.total)} {size_text(speed)}/s")
        else:
            line = f"{self.label} {size_text(self.done)} {size_text(speed)}/s"
        sys.stdout.write("\r" + line + " " * 4)
        sys.stdout.flush()
        self.open = True

    def advance(self, amount):
        self.done += amount
        now = time.monotonic()
        if now - self.last >= 0.5:
            self.last = now
            self.draw()

    def end_line(self):
        if self.open:
            self.draw()
            sys.stdout.write("\n")
            self.open = False


# ---- ダウンロード ----

def copy_with_progress(source, target, label, progress):
    progress.start(label, source.stat().st_size)
    partial = target.with_name(".mt-colab-" + secrets.token_hex(8) + ".part")
    try:
        with source.open("rb") as src, partial.open("wb") as dst:
            for chunk in iter(lambda: src.read(8 * 1024 * 1024), b""):
                dst.write(chunk)
                progress.advance(len(chunk))
        if target.exists():
            raise Failure(t("exists", path=target))
        os.replace(partial, target)
    finally:
        partial.unlink(missing_ok=True)
    progress.end_line()


def fetch(url, filename, target_dir, tokens, progress):
    """target_dir にダウンロードして、保存したパスと SHA256 を返す。"""
    url, suggested, token_name = parse_model_url(url)
    given = filename.strip() or suggested
    name = safe_filename(given) if given else ""
    if name and (target_dir / name).exists():
        raise Failure(t("exists", path=target_dir / name))
    target_dir.mkdir(parents=True, exist_ok=True)
    partial = target_dir / (".mt-colab-" + secrets.token_hex(8) + ".part")
    token = tokens.get(token_name, "") if token_name else ""
    try:
        try:
            response = open_download(url, token)
        except HTTPError as error:
            hint = t("hint_auth", token=token_name) if error.code in {401, 403} and token_name and not token else ""
            raise Failure(t("http_error", status=error.code, hint=hint)) from None
        except URLError as error:
            raise Failure(t("connection", reason=error.reason)) from None
        with response:
            length = response.headers.get("Content-Length", "")
            total = int(length) if length.isdigit() else 0
            free = shutil.disk_usage(target_dir).free
            if total and total + 1024 ** 3 > free:
                raise Failure(t("no_space", need=size_text(total), free=size_text(free)))
            name = name or served_filename(response.headers)
            if not name:
                raise Failure(t("no_filename"))
            safe_filename(name)
            target = target_dir / name
            if target.exists():
                raise Failure(t("exists", path=target))
            digest = hashlib.sha256()
            progress.start(f"{t('downloading')} {name}", total)
            with partial.open("wb") as file:
                for chunk in iter(lambda: response.read(4 * 1024 * 1024), b""):
                    file.write(chunk)
                    digest.update(chunk)
                    progress.advance(len(chunk))
        if not partial.stat().st_size:
            raise Failure(t("empty"))
        if total and partial.stat().st_size != total:
            raise Failure(t("connection", reason=f"{partial.stat().st_size} / {total} bytes"))
        os.replace(partial, target)
    finally:
        partial.unlink(missing_ok=True)
    progress.end_line()
    return target, digest.hexdigest()


def to_drive(target, drive_models, progress):
    drive_target = drive_models / target.name
    if not drive_target.exists():
        drive_models.mkdir(parents=True, exist_ok=True)
        copy_with_progress(target, drive_target, t("copying"), progress)


def command_download(args, tokens, progress):
    models, drive_models = Path(args.models), Path(args.drive_models) if args.drive_models else None
    if args.to_drive and not (drive_models and drive_models.parent.parent.is_dir()):
        raise Failure(t("no_drive"))
    target, digest = fetch(args.url, args.filename, models, tokens, progress)
    if args.to_drive:
        to_drive(target, drive_models, progress)
        print(t("saved_drive", path=target.name) + " SHA256: " + digest)
    else:
        print(t("saved_runtime", path=target.name) + " SHA256: " + digest)
    print(target)


def command_ensure(args, tokens, progress):
    job = json.loads(Path(args.job).read_text(encoding="utf-8"))
    drive_models = Path(args.drive_models) if args.drive_models else None
    for item in job["models"]:
        path = Path(item["path"])
        if path.exists():
            print(t("have", name=path.name))
            continue
        drive_copy = drive_models / path.name if drive_models else None
        if drive_copy and drive_copy.is_file():
            print(t("from_drive", name=path.name))
            path.parent.mkdir(parents=True, exist_ok=True)
            copy_with_progress(drive_copy, path, t("restoring"), progress)
            continue
        if not item["url"]:
            raise Failure(t("unknown_model", key=item["key"], path=path))
        target, _ = fetch(item["url"], path.name, path.parent, tokens, progress)
        if args.to_drive and drive_models:
            to_drive(target, drive_models, progress)


def command_missing(args):
    job = json.loads(Path(args.job).read_text(encoding="utf-8"))
    drive_models = Path(args.drive_models) if args.drive_models else None
    for item in job["models"]:
        path = Path(item["path"])
        if not item["url"] and not path.exists() and not (drive_models and (drive_models / path.name).is_file()):
            print(f"{item['key']}\t{path.name}")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["download", "ensure", "missing"])
    parser.add_argument("--models", required=True)
    parser.add_argument("--drive-models", default="")
    parser.add_argument("--state", required=True)
    parser.add_argument("--url", default="")
    parser.add_argument("--filename", default="")
    parser.add_argument("--job", default="")
    parser.add_argument("--to-drive", action="store_true")
    parser.add_argument("--tokens-stdin", action="store_true")
    args = parser.parse_args()
    if args.command == "missing":
        return command_missing(args)

    tokens = {}
    if args.tokens_stdin:
        try:
            tokens = json.loads(sys.stdin.read() or "{}")
        except ValueError:
            tokens = {}
    progress = Progress()

    # 中止されたら、書きかけのファイルを消してから終わる
    def stop(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)

    state = Path(args.state)
    state.mkdir(parents=True, exist_ok=True)
    with (state / "download.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(t("busy"))
            return 4
        try:
            (command_ensure if args.command == "ensure" else command_download)(args, tokens, progress)
        except Failure as failure:
            progress.end_line()
            print(failure)
            return 1
        except KeyboardInterrupt:
            progress.end_line()
            print(t("cancelled"))
            return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
