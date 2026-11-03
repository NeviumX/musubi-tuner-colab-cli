"""学習の TOML を手元で調べて、Colab VM へ送るファイルを作る。

    python3 lib/prepare_job.py --training TOML --route NAME --out DIR --root DIR
                               --vm-root DIR --stage DIR --catalog FILE [--lang ja]

VM を確保する前に動くので、ここで止めれば課金は発生しない。問題があれば理由を表示して 1 で終わる。
config/<種類>/templates の原本に config/<種類>/<名前>.local.toml があれば重ねる。プロンプトは .local.txt が全体を置き換える。
--out には training.toml、dataset.toml、sample_prompts.txt、job.json を作り、最後に output_name を標準出力に書く。
output_dir は保存先が決まってから手元の lib/train.sh が足す。

学習の TOML のキーは Musubi Tuner の学習スクリプトの引数名。ただし次の 2 つの表は学習には渡さず、キャッシュを作るスクリプトの引数にする。

    [cache_latents]               <種類>_cache_latents.py の引数
    [cache_text_encoder_outputs]  <種類>_cache_text_encoder_outputs.py の引数

dataset_config とモデルのファイルは、種類ごとに決まったキーを学習の TOML から両方へ渡すので、表に書かなくてよい。
次の値は VM 上のパスに書き換える。

    モデルのキー     ファイル名だけなら VM の models フォルダー
    dataset_config   手元のファイルなら VM へ送る。省略すると config/datasets/templates/<種類>.toml
    sample_prompts   手元のファイルなら VM へ送る。省略すると config/prompts/templates/<種類>.txt
    image_directory  手元のフォルダーなら VM へ送る。画像のあるサブフォルダーごとにデータセットを分け、<数>_ の名前を繰り返し数にする
    video_directory  image_directory と同じ
    control_directory  手元のフォルダーなら VM へ送る
    image_jsonl_file 手元のファイルなら、JSONL のあるフォルダーを丸ごと VM へ送り、中のパスを VM の絶対パスにした写しを使う
    video_jsonl_file image_jsonl_file と同じ
    cache_directory  VM の cache/<output_name>/<番号> にする

手元の JSONL の中のパスは、JSONL のあるフォルダーからの相対パスで、そのフォルダーの中のファイルを指す。
Musubi Tuner は画像の JSONL の相対パスを実行したフォルダーから探すので、そのままでは VM で見つからない。そのため絶対パスにする。
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import tomllib
from urllib.parse import unquote, urlsplit

# 学習とキャッシュのスクリプト、キャッシュへ渡す学習のキー、モデルのファイルを指すキー
ROUTES = {
    "qwen_image": {
        "latents_keys": ["vae", "model_version"],
        "text_keys": ["text_encoder", "model_version", "fp8_vl"],
        "model_keys": ["dit", "vae", "text_encoder", "base_weights", "network_weights"],
    },
    "zimage": {
        "latents_keys": ["vae"],
        "text_keys": ["text_encoder", "fp8_llm"],
        "model_keys": ["dit", "vae", "text_encoder", "base_weights", "network_weights"],
    },
    "krea2": {
        "latents_keys": ["vae"],
        "text_keys": ["text_encoder"],
        "model_keys": ["dit", "vae", "text_encoder", "turbo_dit", "turbo_lora", "base_weights", "network_weights"],
    },
    "minimax_h3": {
        "latents_keys": ["video_vae", "audio_vae", "task", "one_frame"],
        "text_keys": ["text_encoder", "task", "one_frame"],
        "model_keys": ["dit", "video_vae", "audio_vae", "text_encoder", "base_weights", "network_weights"],
    },
}
CACHE_SECTIONS = {"cache_latents": "latents", "cache_text_encoder_outputs": "text"}
SECRET_KEY = re.compile(r"_token$|api_key|secret|password", re.I)
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".avif"}
VIDEO_SUFFIXES = {".mp4", ".webm", ".avi", ".mkv", ".mov", ".flv", ".wmv", ".m4v", ".mpg", ".mpeg"}
MEDIA_KEYS = {"image_directory": IMAGE_SUFFIXES, "video_directory": VIDEO_SUFFIXES}
JSONL_KEYS = ("image_jsonl_file", "video_jsonl_file")
# JSONL の 1 行のうち、ファイルを指すキー。control_path_0 のような番号付きのものと、H3 の references の中も含む
JSONL_PATH_KEY = re.compile(r"(image|video|audio)_path|control_path(_[0-9]+)?")
# 区切りの文字で始まるものと、Windows のドライブ名で始まるもの
ABSOLUTE_PATH = re.compile(r"[A-Za-z]:[\\/]|[\\/]")
H3_LOSS_KEYS = ("base_weights", "h3_guidance_loss_scale", "h3_teacher_matching")

TEXTS = {
    "ja": {
        "not_found": "ファイルが見つかりません: {path}",
        "bad_toml": "TOML を読めません: {path}: {error}",
        "no_output_name": "output_name がありません。学習の TOML に書いてください。",
        "bad_output_name": "output_name に使える文字は英数字と . _ - だけです: {name}",
        "secret": "{key} を TOML に書かないでください。トークンは config/config.local.env に書きます。",
        "no_dataset": "dataset_config がありません。",
        "no_datasets": "データセット TOML に [[datasets]] がありません: {path}",
        "save_zero": "save_every_n_epochs = 0 は Musubi Tuner が 0 で割って失敗します。キーを外してください。",
        "epochs_steps": "max_train_epochs と max_train_steps の両方があります。max_train_epochs が優先されます。",
        "no_media": "{key} がありません。image_directory、video_directory、image_jsonl_file、video_jsonl_file のどれかを書いてください。",
        "no_images": "画像や動画がありません: {path}",
        "no_captions": "キャプションの無い画像や動画が {missing} 件あります: {path}。例: {example}。Musubi Tuner はキャプションの無いファイルで止まります。",
        "no_extension": "caption_extension がありません。[general] に caption_extension = \".txt\" のように書いてください。",
        "no_folder": "フォルダーが見つかりません: {path}",
        "bad_jsonl": "JSONL の {line} 行目を読めません: {path}: {error}",
        "jsonl_absolute": "JSONL のパスは、JSONL のあるフォルダーからの相対パスで書いてください: {path} の {line} 行目 {value}",
        "jsonl_outside": "JSONL のパスが JSONL のあるフォルダーの外を指しています。ファイルは同じフォルダーの中に置いてください: {path} の {line} 行目 {value}",
        "jsonl_missing": "JSONL に書いたファイルが見つかりません: {path} の {line} 行目 {value}",
        "jsonl_caption": "caption の無い行が {missing} 行あります: {path}。例: {line} 行目",
        "ok_jsonl": "データセット {path}: {count} 件、ファイル {files} 個",
        "h3_batch": "MiniMax H3 の batch_size は 1 だけです。大きくするなら gradient_accumulation_steps を使ってください。",
        "h3_loss": "MiniMax H3 は base_weights、h3_guidance_loss_scale、h3_teacher_matching のどれか 1 つが必要です。無いと学習で絵が崩れます。",
        "placeholder": "{key} が例の値 mytrigger のままです。",
        "ok_local": "自分の設定を重ねます: {path}",
        "ok_media": "データセット {path}: {count} 件、繰り返し {repeats} 回",
        "problems": "学習の設定に問題があります。ランタイムは作っていません。",
    },
    "en": {
        "not_found": "File not found: {path}",
        "bad_toml": "Cannot read the TOML file: {path}: {error}",
        "no_output_name": "output_name is missing. Add it to the training TOML.",
        "bad_output_name": "output_name may only use letters, digits and . _ -: {name}",
        "secret": "Do not put {key} in a TOML file. Tokens go in config/config.local.env.",
        "no_dataset": "dataset_config is missing.",
        "no_datasets": "The dataset TOML has no [[datasets]]: {path}",
        "save_zero": "save_every_n_epochs = 0 makes Musubi Tuner divide by zero. Remove the key.",
        "epochs_steps": "Both max_train_epochs and max_train_steps are set. max_train_epochs wins.",
        "no_media": "{key} is missing. Set one of image_directory, video_directory, image_jsonl_file and video_jsonl_file.",
        "no_images": "No images or videos in {path}",
        "no_captions": "{missing} images or videos have no caption in {path}. Example: {example}. Musubi Tuner stops at a file without a caption.",
        "no_extension": "caption_extension is missing. Add caption_extension = \".txt\" or similar to [general].",
        "no_folder": "Folder not found: {path}",
        "bad_jsonl": "Cannot read line {line} of the JSONL file: {path}: {error}",
        "jsonl_absolute": "Write JSONL paths relative to the folder of the JSONL file: line {line} of {path}: {value}",
        "jsonl_outside": "A JSONL path points outside the folder of the JSONL file. Keep the files in that folder: line {line} of {path}: {value}",
        "jsonl_missing": "A file named in the JSONL file is missing: line {line} of {path}: {value}",
        "jsonl_caption": "{missing} lines have no caption in {path}. Example: line {line}",
        "ok_jsonl": "Dataset {path}: {count} items, {files} files",
        "h3_batch": "MiniMax H3 only accepts batch_size 1. Use gradient_accumulation_steps for a larger batch.",
        "h3_loss": "MiniMax H3 needs one of base_weights, h3_guidance_loss_scale and h3_teacher_matching. Without one, training breaks the images.",
        "placeholder": "{key} still has the example value mytrigger.",
        "ok_local": "Applying your settings: {path}",
        "ok_media": "Dataset {path}: {count} items, {repeats} repeats",
        "problems": "The training settings have problems. No runtime was created.",
    },
}
LANG = "en"
errors = []
warnings = []


def t(text_key, **values):
    return TEXTS[LANG][text_key].format(**values)


def fail(text_key, **values):
    errors.append(t(text_key, **values))


def warn(text_key, **values):
    warnings.append(t(text_key, **values))


# ---- TOML ----

def read_toml(path):
    try:
        with path.open("rb") as file:
            return tomllib.load(file)
    except OSError:
        raise SystemExit(t("not_found", path=path)) from None
    except tomllib.TOMLDecodeError as error:
        raise SystemExit(t("bad_toml", path=path, error=error)) from None


def flatten(data):
    """Musubi Tuner は TOML のセクションを 1 段だけ開いて平らなキーとして読む。"""
    flat = {}
    for key, value in data.items():
        if isinstance(value, dict):
            flat.update(value)
        else:
            flat[key] = value
    return flat


def merge(base, local):
    """local の値を base に重ねる。表は中へ入り、表の並びは位置ごとに重ねる。空文字の値はキーを消す。"""
    merged = dict(base)
    for key, value in local.items():
        old = merged.get(key)
        if value == "":
            merged.pop(key, None)
        elif isinstance(value, dict) and isinstance(old, dict):
            merged[key] = merge(old, value)
        elif (isinstance(value, list) and isinstance(old, list)
              and all(isinstance(item, dict) for item in value + old)):
            pairs = [merge(old[i], item) if i < len(old) else item for i, item in enumerate(value)]
            merged[key] = pairs + old[len(value):]
        else:
            merged[key] = value
    return merged


def local_file(path, root):
    """config/<種類>/templates/<名前>.<拡張子> に対応する config/<種類>/<名前>.local.<拡張子> を返す。テンプレートでなければ None。"""
    try:
        parts = path.resolve().relative_to((root / "config").resolve()).parts
    except ValueError:
        return None
    if len(parts) != 3 or parts[1] != "templates":
        return None
    candidate = root / "config" / parts[0] / f"{path.stem}.local{path.suffix}"
    if candidate.is_file():
        print(t("ok_local", path=candidate), file=sys.stderr)
        return candidate
    return None


def split_cache(data):
    """キャッシュの表を取り出し、残りを平らにして返す。"""
    data = dict(data)
    cache = {kind: data.pop(section, {}) for section, kind in CACHE_SECTIONS.items()}
    return flatten(data), cache


def toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{" + ", ".join(f"{json.dumps(k)} = {toml_value(v)}" for k, v in value.items()) + "}"
    raise TypeError(type(value))


def dump_flat(data):
    return "".join(f"{key} = {toml_value(value)}\n" for key, value in data.items())


def dump_dataset(data):
    """データセット TOML を書く。[general] と [[datasets]] の形だけを扱う。"""
    lines = []
    if "general" in data:
        lines += ["[general]"] + [f"{k} = {toml_value(v)}" for k, v in data["general"].items()]
    for dataset in data.get("datasets", []):
        lines.append("[[datasets]]")
        lines += [f"{k} = {toml_value(v)}" for k, v in dataset.items()]
    return "\n".join(lines) + "\n"


def cli_args(options):
    """表の値をコマンドラインの引数にする。true は旗だけ、false は付けない、並びは値を続ける。"""
    args = []
    for key, value in options.items():
        if value is False or value is None:
            continue
        args.append(f"--{key}")
        if value is True:
            continue
        args += [str(item) for item in value] if isinstance(value, list) else [str(value)]
    return args


# ---- 検査 ----

def sampling_disabled(config):
    return (config.get("sample_every_n_epochs", 0) <= 0 and config.get("sample_every_n_steps", 0) <= 0
            and not config.get("sample_at_first"))


def check_training(config, route):
    for key in config:
        if SECRET_KEY.search(key):
            fail("secret", key=key)
    name = config.get("output_name", "")
    if not name:
        fail("no_output_name")
    elif not re.fullmatch(r"[A-Za-z0-9._-]+", name) or name.startswith("."):
        fail("bad_output_name", name=name)
    if not config.get("dataset_config"):
        fail("no_dataset")
    if config.get("save_every_n_epochs") == 0:
        fail("save_zero")
    if "max_train_epochs" in config and "max_train_steps" in config:
        warn("epochs_steps")
    if route == "minimax_h3" and not any(config.get(key) for key in H3_LOSS_KEYS):
        fail("h3_loss")


def media_files(folder, suffixes):
    return [p for p in folder.iterdir() if p.is_file() and not p.name.startswith(".") and p.suffix.lower() in suffixes]


def check_media(folder, suffixes, extension, repeats):
    files = media_files(folder, suffixes)
    if not files:
        fail("no_images", path=folder)
        return
    missing = [p for p in files if not p.with_suffix(extension).is_file()]
    if missing:
        fail("no_captions", path=folder, missing=len(missing), example=missing[0].name)
    elif any("mytrigger" in p.with_suffix(extension).read_text(encoding="utf-8", errors="replace") for p in files):
        warn("placeholder", key=f"{folder.name}/*{extension}")
    print(t("ok_media", path=folder, count=len(files), repeats=repeats), file=sys.stderr)


# ---- パス ----

class Job:
    def __init__(self, args, name):
        self.args = args
        self.name = name
        self.out = Path(args.out)
        self.root = Path(args.root)
        self.vm_root = args.vm_root.rstrip("/")
        self.stage = args.stage.rstrip("/")
        self.sync = []          # VM へ送るフォルダー

    def on_vm(self, value):
        return value == self.vm_root or value.startswith(self.vm_root + "/")

    def local_path(self, value, base):
        """手元のパスを実際の場所にする。TOML のフォルダー、プロジェクトのフォルダーの順に探す。"""
        path = Path(value).expanduser()
        if path.is_absolute():
            return path
        return next((c for c in (base / path, self.root / path) if c.exists()), base / path)

    def vm_folder(self, folder):
        """手元のフォルダーを VM へ送る指示を足して、VM 上の場所を返す。同じ名前のフォルダーが重ならないよう、場所のハッシュを足す。"""
        tag = hashlib.sha256(str(folder.resolve()).encode()).hexdigest()[:8]
        name = re.sub(r"[^A-Za-z0-9._-]", "_", folder.name) or "dataset"
        remote = f"{self.vm_root}/datasets/{name}-{tag}"
        if not any(item["local"] == str(folder) for item in self.sync):
            self.sync.append({"local": str(folder), "remote": remote})
        return remote

    def job_file(self, name):
        return f"{self.stage}/jobs/{self.name}/{name}"

    def cache_root(self):
        return f"{self.vm_root}/cache/{self.name}"


def repeat_folders(folder, repeats, suffixes):
    """folder とその下のフォルダーのうち、画像や動画のあるものを (フォルダー, 繰り返し数) で返す。

    sd-scripts の train_data_dir と同じく、名前が <数>_ で始まるフォルダーはその数を繰り返し数にする。
    名前に数の無いフォルダーは親の繰り返し数を受け継ぎ、0_ で始まるフォルダーは中身ごと使わない。
    """
    found = [(folder, repeats)] if media_files(folder, suffixes) else []
    for child in sorted(folder.iterdir()):
        if not child.is_dir() or child.name.startswith("."):
            continue
        match = re.match(r"([0-9]+)_", child.name)
        if match and int(match[1]) < 1:
            continue
        found += repeat_folders(child, int(match[1]) if match else repeats, suffixes)
    return found


def rewrite_jsonl_paths(item, convert):
    """1 行の中のファイルを指す値を convert で置き換える。references の中の値も扱う。"""
    for key, value in item.items():
        if JSONL_PATH_KEY.fullmatch(key) and isinstance(value, str) and value:
            item[key] = convert(value)
    for reference in item.get("references") or []:
        if isinstance(reference, dict):
            for key in ("path", "audio_path"):
                if isinstance(reference.get(key), str) and reference[key]:
                    reference[key] = convert(reference[key])


def prepare_jsonl(job, entry, key, base, number):
    """手元の JSONL を調べ、そのフォルダーを VM へ送る指示を足して、パスを VM の絶対パスにした写しを作る。"""
    path = job.local_path(entry[key], base)
    if not path.is_file():
        fail("not_found", path=path)
        return entry
    folder = path.parent
    remote = job.vm_folder(folder)
    lines = []
    files = set()
    no_caption = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as error:
            fail("bad_jsonl", path=path, line=line_number, error=error)
            continue

        def convert(value):
            # Windows で書いた \ の区切りも受け付ける
            relative = value.replace("\\", "/")
            if ABSOLUTE_PATH.match(value):
                fail("jsonl_absolute", path=path, line=line_number, value=value)
                return value
            target = (folder / relative).resolve()
            if not target.is_relative_to(folder.resolve()):
                fail("jsonl_outside", path=path, line=line_number, value=value)
                return value
            if not target.is_file():
                fail("jsonl_missing", path=path, line=line_number, value=value)
                return value
            files.add(target)
            return f"{remote}/{target.relative_to(folder.resolve()).as_posix()}"

        rewrite_jsonl_paths(item, convert)
        if not item.get("caption"):
            no_caption.append(line_number)
        lines.append(json.dumps(item, ensure_ascii=False))
    if no_caption:
        fail("jsonl_caption", path=path, missing=len(no_caption), line=no_caption[0])
    print(t("ok_jsonl", path=path, count=len(lines), files=len(files)), file=sys.stderr)
    name = f"{number:02d}-{path.name}"
    (job.out / "jsonl").mkdir(exist_ok=True)
    (job.out / "jsonl" / name).write_text("".join(line + "\n" for line in lines), encoding="utf-8")
    return {**entry, key: job.job_file(f"jsonl/{name}")}


def prepare_entry(job, entry, general, base, number):
    """[[datasets]] の 1 つを調べて、学習に使うデータセットの並びを返す。手元のフォルダーはサブフォルダーごとに分ける。"""
    for key in JSONL_KEYS:
        if entry.get(key) and not job.on_vm(entry[key]):
            entry = prepare_jsonl(job, entry, key, base, number)
    key = next((k for k in MEDIA_KEYS if entry.get(k)), None)
    if key is None:
        if not any(entry.get(k) for k in JSONL_KEYS):
            fail("no_media", key="image_directory")
        return [entry]
    extension = entry.get("caption_extension", general.get("caption_extension"))
    if not extension and not job.on_vm(entry[key]):
        fail("no_extension")
        return [entry]

    control = entry.get("control_directory")
    if control and not job.on_vm(control):
        folder = job.local_path(control, base)
        if folder.is_dir():
            entry = {**entry, "control_directory": job.vm_folder(folder)}
        else:
            fail("no_folder", path=folder)
    if job.on_vm(entry[key]):
        return [entry]
    folder = job.local_path(entry[key], base)
    if not folder.is_dir():
        fail("no_folder", path=folder)
        return [entry]
    remote = job.vm_folder(folder)
    # 対になる制御画像はファイル名で引き当てるので、サブフォルダーに分けない
    if control:
        check_media(folder, MEDIA_KEYS[key], extension, entry.get("num_repeats", 1))
        return [{**entry, key: remote}]
    folders = repeat_folders(folder, entry.get("num_repeats", 1), MEDIA_KEYS[key])
    if not folders:
        fail("no_images", path=folder)
        return [entry]
    entries = []
    for found, repeats in folders:
        check_media(found, MEDIA_KEYS[key], extension, repeats)
        part = found.relative_to(folder).as_posix()
        entries.append({**entry, key: remote if part == "." else f"{remote}/{part}", "num_repeats": repeats})
    return entries


def prepare_dataset(job, config, base, route):
    """dataset_config を読み、手元のフォルダーを VM の場所に書き換えて書き出す。"""
    value = config.get("dataset_config", "")
    if not value or job.on_vm(value):
        return
    path = job.local_path(value, base)
    if not path.is_file():
        fail("not_found", path=path)
        return
    dataset = read_toml(path)
    local = local_file(path, job.root)
    if local:
        dataset = merge(dataset, read_toml(local))
    general = dataset.get("general", {})
    if not dataset.get("datasets"):
        fail("no_datasets", path=path)
        return
    entries = [part for number, entry in enumerate(dataset["datasets"])
               for part in prepare_entry(job, entry, general, path.parent, number)]
    # キャッシュはジョブごとの場所に置く。データセットのフォルダーは --delete で同期するので、その中には置かない
    for number, entry in enumerate(entries):
        if not job.on_vm(entry.get("cache_directory", "")):
            entry["cache_directory"] = f"{job.cache_root()}/{number:02d}"
    if route == "minimax_h3" and any(e.get("batch_size", general.get("batch_size", 1)) != 1 for e in entries):
        fail("h3_batch")
    dataset["datasets"] = entries
    (job.out / "dataset.toml").write_text(dump_dataset(dataset), encoding="utf-8")
    config["dataset_config"] = job.job_file("dataset.toml")


def prepare_prompts(job, config, base):
    value = config.get("sample_prompts", "")
    if sampling_disabled(config):
        # Musubi Tuner は 0 を間隔として割るので、生成確認のキーごと外す
        for key in ("sample_prompts", "sample_every_n_epochs", "sample_every_n_steps"):
            config.pop(key, None)
        return
    if not value or job.on_vm(value):
        return
    path = job.local_path(value, base)
    if not path.is_file():
        fail("not_found", path=path)
        return
    path = local_file(path, job.root) or path
    text = path.read_text(encoding="utf-8")
    if "mytrigger" in re.sub(r"(?m)^#.*$", "", text):
        warn("placeholder", key="sample_prompts")
    shutil.copyfile(path, job.out / "sample_prompts.txt")
    config["sample_prompts"] = job.job_file("sample_prompts.txt")


def read_catalog(path):
    """ファイル名と URL の対応を読む。1 行は「URL」か「URL ファイル名」。models.local.txt があれば後から読んで上書きする。"""
    catalog = {}
    for source in (path, path.with_name(path.stem + ".local" + path.suffix)):
        if not source.is_file():
            continue
        for line in source.read_text(encoding="utf-8").splitlines():
            parts = line.split()
            if parts and not parts[0].startswith("#"):
                name = parts[1] if len(parts) > 1 else unquote(urlsplit(parts[0]).path.rsplit("/", 1)[-1])
                catalog[name] = parts[0]
    return catalog


def prepare_models(job, config, route):
    """モデルのキーを VM のパスにして、VM に必要なファイルの一覧を返す。ファイル名だけの値は models フォルダーを指す。"""
    catalog = read_catalog(Path(job.args.catalog))
    needed = []

    def resolve(key, value):
        if not isinstance(value, str) or not value:
            return value
        if "/" not in value:
            value = f"{job.vm_root}/models/{value}"
        if job.on_vm(value):
            needed.append({"key": key, "path": value, "url": catalog.get(value.rsplit("/", 1)[-1], "")})
        return value

    for key in ROUTES[route]["model_keys"]:
        value = config.get(key)
        # base_weights は複数のファイルを並べられる
        config_value = [resolve(key, v) for v in value] if isinstance(value, list) else resolve(key, value)
        if value is not None:
            config[key] = config_value
    return needed


def prepare_cache(job, config, cache, route):
    """キャッシュを作るスクリプトの引数を組み立てる。学習の値を先に、表に書いた値を後に並べる。"""
    route_info = ROUTES[route]
    # MiniMax H3 の guidance loss は、テキストのキャッシュで作る無条件の埋め込みを使う
    if route == "minimax_h3" and config.get("h3_guidance_loss_scale") and not config.get("h3_guidance_loss_uncond_cache"):
        config["h3_guidance_loss_uncond_cache"] = f"{job.cache_root()}/uncond.safetensors"
        cache["text"].setdefault("uncond_output", config["h3_guidance_loss_uncond_cache"])
    commands = {}
    for kind in ("latents", "text"):
        shared = {k: config[k] for k in route_info[f"{kind}_keys"] if k in config}
        commands[kind] = ["--dataset_config", config["dataset_config"]] + cli_args({**shared, **cache[kind]})
    return commands


def main():
    global LANG
    parser = argparse.ArgumentParser()
    parser.add_argument("--training", required=True)
    parser.add_argument("--route", required=True, choices=sorted(ROUTES))
    parser.add_argument("--out", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--vm-root", required=True)
    parser.add_argument("--stage", required=True)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--lang", default="en")
    args = parser.parse_args()
    LANG = "ja" if args.lang == "ja" else "en"

    path = Path(args.training)
    config, cache = split_cache(read_toml(path))
    local = local_file(path, Path(args.root))
    # 学習の TOML は平らなキーとして読むので、セクションが違っても同じキーなら上書きできるよう、開いてから重ねる
    if local:
        local_config, local_cache = split_cache(read_toml(local))
        config = merge(config, local_config)
        cache = {kind: merge(cache[kind], local_cache[kind]) for kind in cache}
    out = Path(args.out)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    job = Job(args, config.get("output_name") or "job")
    # 省略したときは学習の種類と同じ名前の原本を使う。local があれば、いつもどおり原本に重なる
    if not config.get("dataset_config"):
        config["dataset_config"] = str(job.root / "config" / "datasets" / "templates" / f"{args.route}.toml")
    if not config.get("sample_prompts"):
        config["sample_prompts"] = str(job.root / "config" / "prompts" / "templates" / f"{args.route}.txt")
    check_training(config, args.route)
    prepare_dataset(job, config, path.parent, args.route)
    prepare_prompts(job, config, path.parent)
    models = prepare_models(job, config, args.route)
    commands = prepare_cache(job, config, cache, args.route)

    for message in warnings:
        print("  ! " + message, file=sys.stderr)
    if errors:
        print(t("problems"), file=sys.stderr)
        for message in errors:
            print("  - " + message, file=sys.stderr)
        return 1

    config["logging_dir"] = job.job_file("logs")
    for key in ("output_dir", "resume"):
        config.pop(key, None)
    (out / "training.toml").write_text(dump_flat(config), encoding="utf-8")
    (out / "job.json").write_text(json.dumps({
        "name": job.name, "route": args.route, "sync": job.sync, "models": models,
        "cache_root": job.cache_root(), "cache": commands,
    }, ensure_ascii=False, indent=1), encoding="utf-8")
    print(job.name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
