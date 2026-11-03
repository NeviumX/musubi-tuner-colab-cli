# musubi-tuner-colab-cli

[日本語](README_JP.md)

A tool to run [Musubi Tuner](https://github.com/kohya-ss/musubi-tuner) LoRA training on Google Colab GPUs.
Give it your training settings on a Windows PC, and it creates a Colab runtime, sends the dataset, builds the latent and text caches, trains, and fetches the results.

It trains LoRAs for Qwen-Image, Z-Image, Krea 2 and MiniMax H3. MiniMax H3 can be trained on images or on videos.

## Requirements

- Windows 10 or 11 with Ubuntu on WSL2
- A paid Colab plan with GPU access
- A Google account

## Setup

1. Run `setup-wsl.bat`. It installs what WSL needs, including the [Colab CLI](https://github.com/googlecolab/google-colab-cli).
2. Run this command in WSL and follow the prompts to sign in to your Google account.

```bash
colab usage
```

Settings are in `config/config.env`. To change a value, create `config/config.local.env` in the same folder and write it there. Its values override `config.env`, which you leave unchanged.

```bash
# config/config.local.env
GPU=A100
```

These are the settings you are most likely to change.

| Setting | Meaning | Default |
|---|---|---|
| `GPU` | The GPU to use: `T4`, `L4`, `G4`, `H100` or `A100` | `L4` |
| `USE_DRIVE` | Whether to connect Google Drive. `ask` asks every time | `ask` |
| `SAVE_TO` | Where to save the trained model: `ask`, `local` or `drive` | `ask` |
| `STOP_AFTER_TRAINING` | Set to 1 to delete the runtime after a successful run once the results are verified | `0` |

## Training run

This example uses Qwen-Image. The steps are the same for the other models.

1. Put your images in `datasets/my-chara`, each with a `.txt` caption of the same name. Musubi Tuner stops at an image without a caption, so caption every image. Write the trigger word in the captions.
2. Create these three files.

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

3. Run `start-training_QwenImage.bat`.

If there is no runtime, one is created first, so you do not need to run `start.bat` beforehand.
The first run takes a while to download the models and build the caches. The training log shows in the window, and the results are fetched when training ends.

4. When you are done, delete the runtime with `stop.bat`.

> [!IMPORTANT]
> The runtime keeps running after training ends, and you are billed for it. Always delete it with `stop.bat` when you are done.

## Commands

Each command is a pair of a Windows `.bat` and a WSL `.sh`.

| Command | Windows | WSL |
|---|---|---|
| Create a runtime and prepare Musubi Tuner | `start.bat` | `./up.sh` |
| Train a Qwen-Image LoRA | `start-training_QwenImage.bat` | `./start-training_QwenImage.sh` |
| Train a Z-Image LoRA | `start-training_ZImage.bat` | `./start-training_ZImage.sh` |
| Train a Krea 2 LoRA | `start-training_Krea2.bat` | `./start-training_Krea2.sh` |
| Train a MiniMax H3 LoRA | `start-training_MiniMaxH3.bat` | `./start-training_MiniMaxH3.sh` |
| Show the training log again | `logs.bat` | `./logs.sh` |
| Stop training | `stop-training.bat` | `./stop-training.sh` |
| Copy the results to this PC | `pull-outputs.bat` | `./pull-outputs.sh` |
| Download a model | `model-download.bat` | `./model-download.sh` |
| Show the state | `status.bat` | `./status.sh` |
| Delete the runtime | `stop.bat` | `./down.sh` |
| Open a shell on the VM | `ssh.bat` | `./ssh.sh` |

Pressing Ctrl+C or closing the training window only stops the display. Training continues on Colab.
`logs.bat` shows it again. To stop training, use `stop-training.bat`.

## Your settings

The training settings, the dataset and the sample prompts each have an original. The originals are in `config/training/templates/`, `config/datasets/templates/` and `config/prompts/templates/`, and are used when you write nothing.

Do not edit the originals. Write only the values you want to change in local files. Git ignores local files, so updating the tool keeps them.

| Original | Your settings | How it applies |
|---|---|---|
| `config/training/templates/qwen_image.toml` | `config/training/qwen_image.local.toml` | Overrides the keys you write |
| `config/datasets/templates/qwen_image.toml` | `config/datasets/qwen_image.local.toml` | Overrides the keys you write. `[[datasets]]` entries apply in order to the entry at the same position in the original |
| `config/prompts/templates/qwen_image.txt` | `config/prompts/qwen_image.local.txt` | Replaces the whole file |

For the other models, replace `qwen_image` with `zimage`, `krea2` or `minimax_h3`.

- Keys are the argument names of the Musubi Tuner training script.
- To remove a key from the original, set it to `""`, as in `blocks_to_swap = ""`.
- Sections such as `[model]` are optional in local files.

### Cache settings

The `[cache_latents]` and `[cache_text_encoder_outputs]` tables in the training TOML are not passed to training. They become arguments of the cache scripts.
The VAE, the text encoder, `dataset_config` and similar values are passed from the training settings, so these tables only hold settings for caching.

```toml
# config/training/qwen_image.local.toml
[cache_text_encoder_outputs]
fp8_vl = true
```

In TOML, keys after a table header belong to that table, so put the cache tables at the end of your local file.

The caches stay on the VM, one set per job. When the dataset files and cache settings are the same as last time, they are not rebuilt and training starts right away.
When you change images or captions, the old caches are deleted and built again.

### Using another TOML

Drop a training TOML on the `.bat`, or pass it as in `./start-training_QwenImage.sh my.toml`. Only that file is used, and local files are not applied.

## Datasets

### Image folders

The folder in `image_directory` is searched at every depth. Each folder with images is trained as its own dataset.

Name a folder `<number>_<name>` to set its number of repeats. This is the same naming as sd-scripts' `train_data_dir`.

```text
datasets/my-chara/
  10_main/       repeated 10 times
  3_background/  repeated 3 times
  0_unused/      not used
```

- A folder without a number takes its parent folder's repeats.
- Images directly in `image_directory` are repeated `num_repeats` times.
- Readable images are `.png`, `.jpg`, `.jpeg`, `.webp`, `.bmp` and `.avif`.

### JSONL datasets

To list images or videos and their captions in a JSONL file, put the JSONL file and every file it names in one folder under `datasets`.
Write each path relative to the folder of the JSONL file.

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

- The whole folder is sent to the VM, so the paths in the JSONL file work as written.
- Files outside the folder and paths that start with `C:\` or `/` are not accepted. A missing file or a line without a caption stops before a runtime is created.
- For videos, use `video_jsonl_file`. It is written the same way.

### Images on Google Drive

Start `image_directory` with `/content/drive/MyDrive/` to use images on Drive without sending them from your PC. Drive must be connected.

```toml
[[datasets]]
image_directory = "/content/drive/MyDrive/datasets/my-chara"
```

`image_jsonl_file` and `video_jsonl_file` can name a file on the VM the same way. Its paths are then used as they are.

## Sample images

During training, images are generated from the prompt file so you can check progress. By default this happens every epoch, and the images are saved in `sample` in the results folder.

Change the interval in your local training file.

```toml
sample_every_n_epochs = 2   # every 2 epochs
```

```toml
sample_every_n_epochs = 0   # no sample images
```

MiniMax H3 puts about 25 GB of text encoder on the GPU to make samples, so it makes none by default.

## Models

### Models downloaded automatically

Models listed in `config/models.txt` are downloaded automatically when training starts. Write only the file name in the training TOML.

```toml
dit = "qwen_image_2512_bf16.safetensors"
```

### Other models

Run `model-download.bat` and paste the model URL. Hugging Face and Civitai page URLs work as they are. Other sites work with an https URL.

```bash
./model-download.sh https://huggingface.co/owner/repo/blob/main/model.safetensors --to-drive
```

With `--to-drive`, the model is also saved to Drive and reused by the next runtime. After downloading, write the file name in the training TOML.

You can also write the file name in the TOML first and start training. If the model is not found, you are asked for its URL. Paste it, and the model is downloaded and training continues. The URL is kept in `config/models.local.txt`, so you are not asked again.

For safety, pickle files are not downloaded. Use safetensors.

### Models that need a token

Put the tokens in `config/config.local.env`. Do not put them in a TOML file.

```bash
HF_TOKEN=hf_...
CIVITAI_TOKEN=...
```

Krea 2 RAW and Turbo need an `HF_TOKEN` of an account that accepted the license on the model page on Hugging Face.

## Google Drive and the save destination

By default, you are asked whether to connect Google Drive before a runtime is created. The first time, an authorization URL appears. Open it in a browser, allow access, then go back to the window and press Enter.

Before training, you are asked where to save the trained model.

| Destination | How it is saved |
|---|---|
| This PC | Copied to `outputs/<output_name>` every 5 minutes during training, then verified by content at the end |
| Google Drive | Saved directly to `My Drive/musubi-tuner-colab/outputs/<output_name>`. Results so far survive if the runtime goes away |

For long runs, Drive is the safer choice, because Colab usage limits can end a runtime partway through.

- To give the same answer every time, write `USE_DRIVE=1` or `0` and `SAVE_TO=local` or `drive` in `config.local.env`.
- To change it for one run, add `--drive`, `--no-drive` or `--save-to drive` to the training command.
- To copy the results on Drive to your PC, run `./pull-outputs.sh --drive`.

## Resuming

`--resume` continues from the last saved state.

```bash
./start-training_QwenImage.sh --resume
```

Finished epochs are skipped, and epoch numbers continue from there. The per-epoch files of the earlier run are not overwritten.
This works on a new runtime too, as long as the state is on your PC or on Drive. After a run reaches the end, raise `max_train_epochs` and use `--resume` to train only the added epochs. Settings that change the network shape cannot resume.

Musubi Tuner's own `--resume` only loads the state and counts epochs from the start again. This tool shifts the start of the epoch loop so training continues where it stopped. States saved by step are not used for resuming, because their epoch is unknown.

## Model-specific usage

### Qwen-Image

The default fits the 22 GB of an L4 with `fp8_base`, `fp8_scaled` and `blocks_to_swap = 20`. On an A100 or H100, write `blocks_to_swap = ""` in your local file to train faster.
To train on the 2512 release, write `dit = "qwen_image_2512_bf16.safetensors"` in your local file. The Edit models and `model_version` also work; then add `control_directory` to the dataset.

### Z-Image

The default trains on the base model `z_image_bf16.safetensors`. For a LoRA used with Turbo, write `dit = "z_image_de_turbo_v1_bf16.safetensors"` in your local file.

### Krea 2

The recommended workflow is to train on RAW and use the LoRA with Turbo. To make samples with Turbo, write `turbo_dit = "krea2_turbo.safetensors"` and `blocks_to_swap = ""` in your local file, and use `--l 1 --s 8` in the prompts. `turbo_dit` cannot be combined with `blocks_to_swap`.

### MiniMax H3

MiniMax H3 makes videos with sound, and you can train LoRAs for it on images or on videos. Read and accept the [MiniMax-H3 Community License](https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE) before using it.

- The default settings train on images. To train on videos, point the dataset at a folder of videos and switch the training settings to video.
- Give each video a caption with the same name, as with images. If a video has sound, the sound is trained too.
- Video training needs more memory and time than image training. An A100 or a larger GPU is expected.
- When training on images, captions that say the image is a silent still are recommended.

## Checks before training

Before a runtime is created, your settings and dataset are checked on your PC. Missing images or captions and settings that cannot be combined stop with a reason before billing starts.
Misspelled keys are checked right before training, after the runtime is ready, because the check needs the Musubi Tuner source.

## Notes

- **Billing:** The runtime keeps running after training ends, and you are billed for it. Delete it with `stop.bat`. With `STOP_AFTER_TRAINING=1`, it is deleted automatically after a successful run once the results are verified.
- **Automatic deletion needs your PC:** Your PC's window does the automatic deletion. If you turn off or sleep your PC during training, training and saving continue, but the runtime is not deleted.
- **Copying before deletion:** `stop.bat` copies the results left on the runtime to your PC before deleting it. If that fails, it asks before deleting.
- **Google Drive:** Training runs with administrator rights on Colab and can read and write all of the connected Google Drive. Use a Google account without personal data.
- **Opening a shell on the VM:** A Colab runtime accepts only one SSH connection at a time. Use `ssh.bat`, not `colab ssh`.
- **Licenses:** Check the license of each model yourself.
- **Language:** Messages are in Japanese on a Japanese system and in English otherwise. Set `MT_COLAB_LANG` to `ja` or `en` to fix the language.
- **WSL distribution:** To use a WSL distribution other than the default, set the environment variable `MT_COLAB_WSL_DISTRO` to its name before running the `.bat` files.
