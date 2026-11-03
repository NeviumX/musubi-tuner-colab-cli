"""Colab VM 上で学習を実行する。手元の lib/common.sh が VM へ送り、ssh 越しに呼ぶ。

    python3 remote_train.py check DIR --musubi DIR [--resume]   実行前の検査
    python3 remote_train.py run DIR --musubi DIR --venv DIR     キャッシュと学習。tmux の中で動く
    python3 remote_train.py stop DIR                            学習を止める

DIR は job.json と training.toml を置いたジョブのフォルダー。ログは run.log に、状態は status.json に書く。
tmux の中で動くので、手元の SSH が切れても学習は止まらない。
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import tomllib

EPOCH_STATE = re.compile(r"-(\d{6})-state$")
# prepare_job.py と同じ、JSONL の 1 行のうちファイルを指すキー
JSONL_PATH_KEY = re.compile(r"(image|video|audio)_path|control_path(_[0-9]+)?")
EXIT_NOT_NEEDED = 3
# 再開で使う、済んだエポック数の記録。最後の state はファイル名にエポックが無いので、学習の後でここに書く
EPOCHS_FILE = "musubi_colab_epochs.txt"
TAG = "[musubi-tuner-colab-cli]"


def scripts(route):
    return {"train": f"{route}_train_network.py", "latents": f"{route}_cache_latents.py",
            "text": f"{route}_cache_text_encoder_outputs.py"}


def known_options(musubi, script):
    """スクリプトの引数の名前を、本物の引数の定義から集める。parse_args の呼び出しで止めるので、学習やキャッシュは始まらない。"""
    code = f"""
import argparse, runpy, sys
class Captured(Exception):
    pass
def capture(self, *args, **kwargs):
    raise Captured(sorted(a.dest for a in self._actions))
argparse.ArgumentParser.parse_args = capture
argparse.ArgumentParser.parse_known_args = capture
sys.argv = [{json.dumps(script)}]
try:
    runpy.run_path({json.dumps(script)}, run_name="__main__")
except Captured as found:
    print("\\n".join(found.args[0]))
"""
    result = subprocess.run([sys.executable, "-c", code], cwd=musubi, capture_output=True, text=True)
    names = set(result.stdout.split())
    if not names:
        raise SystemExit(f"cannot read the options of {script}: {result.stderr[-2000:]}")
    return names


def cache_options(command):
    return {item[2:] for item in command if item.startswith("--")}


def complete_states(output_dir, name):
    """保存が終わった状態のフォルダーを (フォルダー, 済んだエポック数) で古い順に返す。ステップごとの状態はエポックが分からないので使わない。"""
    states = []
    for path in Path(output_dir).glob(f"{name}*-state"):
        if not any(path.glob("optimizer*")):
            continue
        match = EPOCH_STATE.search(path.name)
        if match and path.name == f"{name}-{match[1]}-state":
            states.append((path, int(match[1])))
        elif path.name == f"{name}-state" and (path / EPOCHS_FILE).is_file():
            states.append((path, int((path / EPOCHS_FILE).read_text())))
    return sorted(states, key=lambda item: item[0].stat().st_mtime)


def check(args):
    job = Path(args.job)
    info = json.loads((job / "job.json").read_text(encoding="utf-8"))
    training = job / "training.toml"
    config = tomllib.loads(training.read_text(encoding="utf-8"))
    musubi = Path(args.musubi)

    names = scripts(info["route"])
    unknown = sorted(set(config) - known_options(musubi, names["train"]))
    for kind in ("latents", "text"):
        unknown += sorted(f"[{kind}] {key}" for key in cache_options(info["cache"][kind]) - known_options(musubi, names[kind]))
    if unknown:
        print("UNKNOWN_KEYS " + " ".join(unknown))
        return 1
    missing = [f"{key}={value}" for key, value in config.items()
               if key in {"dataset_config", "sample_prompts"} and not Path(value).exists()]
    if missing:
        print("MISSING " + " ".join(missing))
        return 1
    (job / "resume_epochs").unlink(missing_ok=True)
    if args.resume:
        states = complete_states(config["output_dir"], config["output_name"])
        if not states:
            print("NO_STATE " + config["output_dir"])
            return 1
        state, done = states[-1]
        total = config.get("max_train_epochs") or 0
        if done >= total:
            print(f"NOTHING_LEFT {done} {total}")
            return EXIT_NOT_NEEDED
        with training.open("a", encoding="utf-8") as file:
            file.write(f"resume = {json.dumps(str(state), ensure_ascii=False)}\n")
        (job / "resume_epochs").write_text(str(done))
        print(f"RESUME {state}")
    return 0


class Status:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.data = {"state": "running", "phase": "", "started_at": now(), "updated_at": "", "exit_code": None}

    def write(self, **changes):
        with self.lock:
            self.data.update(changes, updated_at=now())
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(json.dumps(self.data), encoding="utf-8")
            temporary.replace(self.path)


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def token_env(job):
    """手元から送ったトークンを、値をコマンドの引数に載せずに学習のプロセスへ渡す。"""
    env = {}
    path = job.parent.parent / "state" / "tokens.json"
    if path.is_file():
        env = {k: v for k, v in json.loads(path.read_text()).items() if k in {"HF_TOKEN", "WANDB_API_KEY"}}
    # トークンが無ければ、huggingface_hub にマシンのトークンを探させない
    if "HF_TOKEN" not in env:
        env["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
    return env


def jsonl_files(path):
    """JSONL が指すファイルのうち、絶対パスで書かれたものを返す。手元から送った JSONL は prepare_job.py が絶対パスにしてある。"""
    found = []
    if not path.is_file():
        return found
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        values = [v for k, v in item.items() if JSONL_PATH_KEY.fullmatch(k)]
        for reference in item.get("references") or []:
            if isinstance(reference, dict):
                values += [reference.get("path"), reference.get("audio_path")]
        found += [Path(v) for v in values if isinstance(v, str) and v.startswith("/")]
    return found


def dataset_fingerprint(dataset_config):
    """データセットのファイルの名前、大きさ、更新時刻をまとめる。rsync は更新時刻を保つので、手元で変えたときだけ変わる。"""
    config = tomllib.loads(Path(dataset_config).read_text(encoding="utf-8"))
    # キャッシュはジョブの場所に分けて置くので、データセットのフォルダーにキャッシュは混ざらない
    digest = hashlib.sha256()
    for entry in config.get("datasets", []):
        for key in ("image_directory", "video_directory", "control_directory", "image_jsonl_file", "video_jsonl_file"):
            if not entry.get(key):
                continue
            root = Path(entry[key])
            paths = sorted(root.rglob("*")) if root.is_dir() else jsonl_files(root)
            # 手元から送った JSONL の写しは毎回送り直して更新時刻が変わるので、中身で比べる
            if root.is_file():
                digest.update(hashlib.sha256(root.read_bytes()).digest())
            for path in paths:
                if path.is_file():
                    stat = path.stat()
                    digest.update(f"{path}\0{stat.st_size}\0{int(stat.st_mtime)}\n".encode())
    return digest.hexdigest()


def cache_key(info, dataset_config):
    text = json.dumps(info["cache"]) + Path(dataset_config).read_text(encoding="utf-8") + dataset_fingerprint(dataset_config)
    return hashlib.sha256(text.encode()).hexdigest()


def run(args):
    job = Path(args.job)
    info = json.loads((job / "job.json").read_text(encoding="utf-8"))
    config = tomllib.loads((job / "training.toml").read_text(encoding="utf-8"))
    names = scripts(info["route"])
    status = Status(job / "status.json")
    (job / "pid").write_text(str(os.getpid()))
    status.write()

    stopping = threading.Event()
    finished = threading.Event()
    current = {"process": None}

    def heartbeat():
        while not finished.wait(30):
            status.write()

    def on_stop(signum, frame):
        stopping.set()
        process = current["process"]
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGINT)
            except ProcessLookupError:
                pass

    signal.signal(signal.SIGTERM, on_stop)
    signal.signal(signal.SIGINT, on_stop)
    # rich のログがパイプの幅で折り返されないようにする
    env = {**os.environ, **token_env(job), "PYTHONUNBUFFERED": "1", "COLUMNS": "160"}
    done_file = job / "resume_epochs"
    if done_file.is_file():
        env["MUSUBI_COLAB_DONE_EPOCHS"] = done_file.read_text().strip()
    python = str(Path(args.venv) / "bin" / "python")

    def note(text):
        with (job / "run.log").open("a", encoding="utf-8") as log:
            log.write(f"\n{TAG} {text}\n")

    def execute(phase, command):
        if stopping.is_set():
            return 1
        status.write(phase=phase)
        note(phase)
        process = subprocess.Popen(command, cwd=args.musubi, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        current["process"] = process
        with (job / "run.log").open("ab") as log:
            while chunk := os.read(process.stdout.fileno(), 65536):
                log.write(chunk)
                log.flush()
        code = process.wait()
        current["process"] = None
        return code

    threading.Thread(target=heartbeat, daemon=True).start()
    code = 1
    try:
        # キャッシュは設定とデータセットが前の回と同じなら作り直さない。変わったら古いものを消して作る
        cache_root = Path(info["cache_root"])
        key = cache_key(info, config["dataset_config"])
        key_file = cache_root / "key"
        if key_file.is_file() and key_file.read_text() == key:
            note("cache is up to date")
            code = 0
        else:
            shutil.rmtree(cache_root, ignore_errors=True)
            cache_root.mkdir(parents=True)
            code = execute("caching latents", [python, names["latents"], *info["cache"]["latents"]])
            if code == 0:
                code = execute("caching text encoder outputs", [python, names["text"], *info["cache"]["text"]])
            if code == 0:
                key_file.write_text(key)
        if code == 0:
            entry = str(Path(__file__).with_name("train_entry.py"))
            command = [str(Path(args.venv) / "bin" / "accelerate"), "launch", "--num_cpu_threads_per_process=1",
                       f"--mixed_precision={config.get('mixed_precision', 'no')}", entry, names["train"],
                       f"--config_file={job / 'training.toml'}"]
            code = execute("training", command)
            if code == 0:
                last = Path(config["output_dir"]) / f"{config['output_name']}-state"
                if last.is_dir():
                    (last / EPOCHS_FILE).write_text(str(config.get("max_train_epochs") or 0))
    finally:
        finished.set()
        state = "stopped" if stopping.is_set() else "succeeded" if code == 0 else "failed"
        note(f"training {state}, exit code {code}")
        status.write(state=state, exit_code=code)
    return code


def stop(args):
    job = Path(args.job)
    pid = int((job / "pid").read_text())
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return 1
    for _ in range(60):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return 0
        time.sleep(1)
    return 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["check", "run", "stop"])
    parser.add_argument("job")
    parser.add_argument("--musubi", default="")
    parser.add_argument("--venv", default="")
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    return {"check": check, "run": run, "stop": stop}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
