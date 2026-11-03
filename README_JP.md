# musubi-tuner-colab-cli

[English](README.md)

[Musubi Tuner](https://github.com/kohya-ss/musubi-tuner) の LoRA 学習を Google Colab の GPU で動かすツールです。
Windows の PC で学習の設定を用意すると、Colab のランタイムを作り、データセットを送り、latent とテキストのキャッシュを作って学習し、結果を手元に回収します。

Qwen-Image、Z-Image、Krea 2、MiniMax H3 の LoRA を学習できます。MiniMax H3 は画像でも動画でも学習できます。

## 必要なもの

- Ubuntu を入れた WSL2 のある Windows 10 か 11
- GPU を使える有料の Colab プラン
- Google アカウント

## 準備

1. `setup-wsl.bat` を実行します。[Colab CLI](https://github.com/googlecolab/google-colab-cli) など、WSL に必要なものが入ります。
2. WSL で次のコマンドを実行し、表示に従って Google アカウントにログインします。

```bash
colab usage
```

設定は `config/config.env` にあります。値を変えるときは、同じフォルダーに `config/config.local.env` を作ってそこに書きます。`config.env` は書き換えずに残し、`config.local.env` の値が優先されます。

```bash
# config/config.local.env
GPU=A100
```

よく変える設定は次のとおりです。

| 設定 | 意味 | 既定 |
|---|---|---|
| `GPU` | 使う GPU。`T4`、`L4`、`G4`、`H100`、`A100` | `L4` |
| `USE_DRIVE` | Google ドライブをつなぐか。`ask` なら毎回尋ねる | `ask` |
| `SAVE_TO` | 学習したモデルの保存先。`ask`、`local`、`drive` | `ask` |
| `STOP_AFTER_TRAINING` | 1 にすると、学習が成功して結果を確かめた後にランタイムを削除する | `0` |

## 学習の流れ

Qwen-Image を例にします。ほかのモデルでも手順は同じです。

1. `datasets/my-chara` に画像を置き、それぞれに同じ名前の `.txt` のキャプションを付けます。Musubi Tuner はキャプションの無い画像で止まるので、すべての画像に付けます。トリガーワードはキャプションに書きます。
2. 次の 3 つのファイルを作ります。

```toml
# config/training/qwen_image.local.toml
output_name = "my-chara"
```

```toml
# config/datasets/qwen_image.local.toml
[[datasets]]
image_directory = "datasets/my-chara"
```

```text
# config/prompts/qwen_image.local.txt
mychara, a woman standing in a park --w 1024 --h 1024 --s 30 --l 4 --d 42
```

3. `start-training_QwenImage.bat` を実行します。

ランタイムが無ければ先に作るので、`start.bat` を事前に実行しなくてもかまいません。
初回はモデルのダウンロードとキャッシュの作成に時間がかかります。学習のログはウィンドウに表示され、学習が終わると結果を回収します。

4. 使い終わったら `stop.bat` でランタイムを削除します。

> [!IMPORTANT]
> 学習が終わってもランタイムは動き続け、課金されます。使い終わったら必ず `stop.bat` で削除してください。

## コマンド

どのコマンドも Windows の `.bat` と WSL の `.sh` の組です。

| コマンド | Windows | WSL |
|---|---|---|
| ランタイムを作り、Musubi Tuner を準備する | `start.bat` | `./up.sh` |
| Qwen-Image の LoRA を学習する | `start-training_QwenImage.bat` | `./start-training_QwenImage.sh` |
| Z-Image の LoRA を学習する | `start-training_ZImage.bat` | `./start-training_ZImage.sh` |
| Krea 2 の LoRA を学習する | `start-training_Krea2.bat` | `./start-training_Krea2.sh` |
| MiniMax H3 の LoRA を学習する | `start-training_MiniMaxH3.bat` | `./start-training_MiniMaxH3.sh` |
| 学習のログを表示し直す | `logs.bat` | `./logs.sh` |
| 学習を止める | `stop-training.bat` | `./stop-training.sh` |
| 結果を手元にコピーする | `pull-outputs.bat` | `./pull-outputs.sh` |
| モデルをダウンロードする | `model-download.bat` | `./model-download.sh` |
| 状態を表示する | `status.bat` | `./status.sh` |
| ランタイムを削除する | `stop.bat` | `./down.sh` |
| VM のシェルに入る | `ssh.bat` | `./ssh.sh` |

学習のウィンドウで Ctrl+C を押すか、ウィンドウを閉じても、止まるのは表示だけです。学習は Colab で続きます。
`logs.bat` で表示し直せます。学習を止めるときは `stop-training.bat` を使います。

## 自分の設定

学習の設定、データセット、生成確認のプロンプトには、それぞれ原本があります。原本は `config/training/templates/`、`config/datasets/templates/`、`config/prompts/templates/` にあり、何も書かなければ原本の値で学習します。

原本は書き換えず、変えたい値だけを local のファイルに書きます。local のファイルは git の管理外なので、ツールを更新しても残ります。

| 原本 | 自分の設定 | 効き方 |
|---|---|---|
| `config/training/templates/qwen_image.toml` | `config/training/qwen_image.local.toml` | 書いたキーだけを上書きする |
| `config/datasets/templates/qwen_image.toml` | `config/datasets/qwen_image.local.toml` | 書いたキーだけを上書きする。`[[datasets]]` は上から順に、原本の同じ位置の表へ重なる |
| `config/prompts/templates/qwen_image.txt` | `config/prompts/qwen_image.local.txt` | ファイル全体を置き換える |

ほかのモデルでは `qwen_image` を `zimage`、`krea2`、`minimax_h3` に読み替えます。

- 学習の TOML のキーは、Musubi Tuner の学習スクリプトの引数名です。
- 原本のキーを消すには、`blocks_to_swap = ""` のように値を `""` にします。
- `[model]` などのセクションは local では省いてかまいません。

### キャッシュの設定

学習の TOML の `[cache_latents]` と `[cache_text_encoder_outputs]` は学習には渡さず、キャッシュを作るスクリプトの引数にします。
VAE、テキストエンコーダー、`dataset_config` などは学習の値をそのまま渡すので、ここに書くのはキャッシュだけの設定です。

```toml
# config/training/qwen_image.local.toml
[cache_text_encoder_outputs]
fp8_vl = true
```

TOML では表の見出しより後のキーはその表に入るので、キャッシュの表は local のファイルの最後に書きます。

キャッシュは VM にジョブごとに残します。データセットのファイルとキャッシュの設定が前の回と同じなら作り直さず、すぐに学習を始めます。
画像やキャプションを変えると、古いキャッシュを消して作り直します。

### 別の TOML を使う

学習の TOML を `.bat` にドラッグするか、`./start-training_QwenImage.sh my.toml` のように渡すと、そのファイルだけを使います。local のファイルは重ねません。

## データセット

### 画像のフォルダー

`image_directory` のフォルダーは、下の階層まで探します。画像のあるフォルダーは、それぞれ別のデータセットとして学習します。

フォルダーの名前を `<数>_<名前>` にすると、その数が繰り返し数になります。sd-scripts の `train_data_dir` と同じ名前の付け方です。

```text
datasets/my-chara/
  10_main/       10 回繰り返す
  3_background/  3 回繰り返す
  0_unused/      使わない
```

- 数の無いフォルダーは、親のフォルダーの繰り返し数を受け継ぎます。
- `image_directory` の直下の画像は `num_repeats` 回繰り返します。
- 読める画像は `.png`、`.jpg`、`.jpeg`、`.webp`、`.bmp`、`.avif` です。

### JSONL のデータセット

画像や動画とキャプションの組を JSONL に書くときは、JSONL と、そこに書くファイルを `datasets` の下の 1 つのフォルダーにまとめます。
パスは JSONL のあるフォルダーからの相対パスで書きます。

```text
datasets/my-chara-refs/
  items.jsonl
  targets/pose_01.png
  refs/front.png
```

```json
{"image_path": "targets/pose_01.png", "caption": "mychara, standing", "references": [{"type": "image", "path": "refs/front.png"}]}
```

```toml
# config/datasets/minimax_h3.local.toml
[[datasets]]
image_directory = ""
image_jsonl_file = "datasets/my-chara-refs/items.jsonl"
```

- フォルダーを丸ごと VM へ送るので、JSONL に書いたパスはそのまま使えます。
- フォルダーの外のファイルや、`C:\` や `/` で始まるパスは書けません。見つからないファイルや caption の無い行があれば、ランタイムを作る前に止まります。
- 動画は `video_jsonl_file` に書きます。書き方は画像と同じです。

### Google ドライブの画像

`image_directory` を `/content/drive/MyDrive/` で始めると、手元の PC から送らずにドライブの画像を使えます。ドライブをつないでおく必要があります。

```toml
[[datasets]]
image_directory = "/content/drive/MyDrive/datasets/my-chara"
```

`image_jsonl_file` と `video_jsonl_file` も、同じように VM 上のファイルを指定できます。その場合、中のパスは書き換えずにそのまま使います。

## 生成確認

学習の途中にプロンプトのファイルから画像を作り、進み具合を確かめられます。既定ではエポックごとに作り、結果のフォルダーの `sample` に保存します。

間隔は local の学習の設定で変えます。

```toml
sample_every_n_epochs = 2   # 2 エポックごと
```

```toml
sample_every_n_epochs = 0   # 作らない
```

MiniMax H3 は生成確認にテキストエンコーダーを GPU へ 25GB ほど載せるので、既定では作りません。

## モデル

### 自動でダウンロードするモデル

`config/models.txt` にあるモデルは、学習の開始時に自動でダウンロードします。学習の TOML にはファイル名だけを書きます。

```toml
dit = "qwen_image_2512_bf16.safetensors"
```

### ほかのモデル

`model-download.bat` を実行して、モデルの URL を貼り付けます。Hugging Face と Civitai はページの URL をそのまま使えます。ほかのサイトは https の URL なら使えます。

```bash
./model-download.sh https://huggingface.co/owner/repo/blob/main/model.safetensors --to-drive
```

`--to-drive` を付けると、ドライブにも保存して次のランタイムで再利用します。ダウンロードしたら、そのファイル名を学習の TOML に書きます。

TOML に先にファイル名を書いて学習を始めることもできます。モデルが見つからないと URL を尋ねるので、貼り付けるとダウンロードして学習を続けます。URL は `config/models.local.txt` に残し、次からは尋ねません。

安全のため、pickle 形式のファイルはダウンロードしません。safetensors を使ってください。

### トークンが必要なモデル

トークンは `config/config.local.env` に書きます。TOML には書かないでください。

```bash
HF_TOKEN=hf_...
CIVITAI_TOKEN=...
```

Krea 2 の RAW と Turbo は、Hugging Face のモデルのページでライセンスに同意したアカウントの `HF_TOKEN` が要ります。

## Google ドライブと保存先

既定では、ランタイムを作る前に Google ドライブをつなぐかを尋ねます。初回は認可の URL が表示されます。ブラウザで開いて許可し、ウィンドウに戻って Enter を押します。

学習の前に、学習したモデルの保存先を尋ねます。

| 保存先 | 保存のしかた |
|---|---|
| この PC | 学習中は 5 分ごとに `outputs/<output_name>` へコピーし、終わったら中身を比べて確かめる |
| Google ドライブ | `マイドライブ/musubi-tuner-colab/outputs/<output_name>` に直接保存する。ランタイムが消えても、そこまでの結果が残る |

長い学習ではドライブが安全です。Colab の利用上限で、ランタイムが途中で終わることがあるためです。

- 毎回同じ答えにするには、`config.local.env` に `USE_DRIVE=1` か `0` と、`SAVE_TO=local` か `drive` を書きます。
- 1 回だけ変えるには、学習のコマンドに `--drive`、`--no-drive`、`--save-to drive` を付けます。
- ドライブの結果を PC にコピーするには `./pull-outputs.sh --drive` を実行します。

## 再開

`--resume` を付けると、最後に保存した状態から続けます。

```bash
./start-training_QwenImage.sh --resume
```

済んだエポックは飛ばし、エポックの番号もそこから続けます。前の回のエポックごとのファイルは上書きしません。
状態が PC かドライブにあれば、新しいランタイムでも再開できます。最後まで学習した後に `max_train_epochs` を増やして `--resume` すると、増やした分だけ学習します。ネットワークの形を変える設定では再開できません。

Musubi Tuner の `--resume` そのものは状態を読み込むだけで、エポックを最初から数え直します。このツールはエポックの繰り返しの始まりをずらして続きから学習します。ステップごとに保存した状態は、何エポック目か分からないので再開には使いません。

## モデルごとの使い方

### Qwen-Image

既定は L4 の 22GB に収まるよう、`fp8_base`、`fp8_scaled`、`blocks_to_swap = 20` を使います。A100 や H100 では local に `blocks_to_swap = ""` と書くと速くなります。
2512 版で学習するには local に `dit = "qwen_image_2512_bf16.safetensors"` と書きます。Edit 系のモデルと `model_version` も使えます。その場合はデータセットに `control_directory` を書きます。

### Z-Image

既定はベースモデルの `z_image_bf16.safetensors` で学習します。Turbo で使う LoRA を作るなら、local に `dit = "z_image_de_turbo_v1_bf16.safetensors"` と書きます。

### Krea 2

RAW で学習し、Turbo で使うのが推奨の使い方です。生成確認を Turbo で行うには、local に `turbo_dit = "krea2_turbo.safetensors"` と `blocks_to_swap = ""` を書き、プロンプトを `--l 1 --s 8` にします。`turbo_dit` と `blocks_to_swap` は同時に使えません。

### MiniMax H3

MiniMax H3 は音声付きの動画を作るモデルで、画像と動画のどちらでも LoRA を学習できます。使う前に [MiniMax-H3 Community License](https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE) を読んで同意してください。

- 既定の設定は画像で学習します。動画で学習するときは、データセットに動画のフォルダーを指定し、学習の設定を動画向けに切り替えます。
- 動画にも、画像と同じく同じ名前のキャプションを付けます。動画に音声があれば、音声も一緒に学習します。
- 動画の学習は画像より多くのメモリと時間を使います。A100 以上の GPU を想定しています。
- 画像で学習するときは、キャプションに無音の静止画であることを書くとよいとされています。

## 学習の前の検査

ランタイムを作る前に、設定とデータセットを PC で調べます。画像やキャプションの不足、組み合わせられない設定は、課金の前に理由を表示して止まります。
キーの綴りの誤りは、Musubi Tuner のソースが要るので、ランタイムの準備の後、学習の直前に調べます。

## 注意

- **課金:** 学習が終わってもランタイムは動き続け、課金されます。`stop.bat` で削除してください。`STOP_AFTER_TRAINING=1` なら、学習が成功して結果を確かめた後に自動で削除します。
- **自動の削除には PC が要る:** 自動の削除は PC のウィンドウが行います。学習中に PC の電源を切ったりスリープさせたりすると、学習と保存は続きますが、ランタイムは削除されません。
- **削除の前のコピー:** `stop.bat` は、削除の前にランタイムに残った結果を PC にコピーします。コピーできなかったときは、削除するかを尋ねます。
- **Google ドライブ:** 学習は Colab の管理者の権限で動き、つないだ Google ドライブ全体を読み書きできます。個人のデータを置いていない Google アカウントを使ってください。
- **VM のシェル:** Colab のランタイムには同時に 1 本しか SSH をつなげません。`colab ssh` ではなく `ssh.bat` を使ってください。
- **ライセンス:** モデルのライセンスはそれぞれ自分で確かめてください。
- **言語:** 日本語の環境では日本語で、それ以外では英語で表示します。`MT_COLAB_LANG` を `ja` か `en` にすると固定できます。
- **WSL のディストリビューション:** 既定以外のディストリビューションを使うには、`.bat` を実行する前に環境変数 `MT_COLAB_WSL_DISTRO` にその名前を設定します。
