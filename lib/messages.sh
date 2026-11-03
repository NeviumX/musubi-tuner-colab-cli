#!/usr/bin/env bash
# スクリプトが表示する文章を日本語と英語でまとめたファイル。
# `msg キー 引数...` で、選ばれた言語の文章を返す。文章は printf の書式で、%s に引数が入る。改行は付かない。
# 文章に % を書くときは %% にする。
#
# 言語は次の順で決める。
#   1. MT_COLAB_LANG が ja か en ならそれに従う
#   2. LC_ALL / LC_MESSAGES / LANG が ja で始まれば日本語、ほかの言語が指定されていれば英語
#   3. C や POSIX のように言語の指定がなく、WSL 上で動いているときは Windows の表示言語に合わせる
#   4. どれにも当てはまらなければ英語
# MSG_LANG がすでに決まっているときは判定しない。Colab VM 側にはこの値を渡している。

_detect_msg_lang() {
    local v ui
    case "${MT_COLAB_LANG:-}" in
        ja|en) echo "$MT_COLAB_LANG"; return ;;
    esac
    for v in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
        [[ -n "$v" ]] || continue
        case "$v" in
            ja*) echo ja; return ;;
            C|C.*|POSIX|POSIX.*) break ;;
            *) echo en; return ;;
        esac
    done
    if [[ -n "${WSL_DISTRO_NAME:-}" ]] && command -v powershell.exe >/dev/null 2>&1; then
        ui="$(cd /mnt/c 2>/dev/null || true; powershell.exe -NoProfile -NonInteractive -Command \
            '[Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName' 2>/dev/null | tr -d '\r\n ')"
        if [[ "$ui" == ja ]]; then echo ja; return; fi
    fi
    echo en
}
MSG_LANG="${MSG_LANG:-$(_detect_msg_lang)}"

declare -A _MSG_JA=() _MSG_EN=()
# 文章を登録する: _m キー 日本語 英語
_m() { _MSG_JA[$1]="$2"; _MSG_EN[$1]="$3"; }

msg() {
    local key="$1" fmt
    shift
    if [[ "$MSG_LANG" == ja ]]; then fmt="${_MSG_JA[$key]-}"; else fmt="${_MSG_EN[$key]-}"; fi
    [[ -n "$fmt" ]] || fmt="[$key]"
    # shellcheck disable=SC2059
    printf "$fmt" "$@"
}

# ===== 共通 =====
_m cmd_missing \
    "%s が見つかりません。先に setup-wsl.bat を実行してください。" \
    "%s not found. Run setup-wsl.bat first."
_m no_runtime_skip_ssh \
    "ランタイム %s がないので、SSH は行いません。" \
    "Runtime %s does not exist, so SSH is skipped."
_m runtime_missing_start \
    "ランタイム %s がありません。start.bat か ./up.sh で起動してください。" \
    "Runtime %s does not exist. Start it with start.bat or ./up.sh."
_m ssh_busy_429 \
    "別の colab ssh がこのランタイムに接続中です。手動の colab ssh を閉じてください。%s/6 回目" \
    "Another colab ssh is connected to this runtime. Close your manual colab ssh. Attempt %s/6"
_m ssh_waiting \
    "SSH 接続を待っています。%s/6 回目" \
    "Waiting for SSH. Attempt %s/6"
_m ssh_failed \
    "SSH で接続できません。config/ssh_config を見直し、./ssh.sh -v true で詳細を確認してください。" \
    "Cannot connect over SSH. Check config/ssh_config and run ./ssh.sh -v true for details."
_m ssh_failed_429 \
    "SSH で接続できません。別の colab ssh が接続中なら閉じてください。HTTP 429 はそれが原因です。" \
    "Cannot connect over SSH. If another colab ssh is connected, close it. HTTP 429 means exactly that."
_m upload_failed \
    "Colab VM へファイルを送れませんでした。" \
    "Could not send files to the Colab VM."
_m token_invalid \
    "%s の値に使えない文字が含まれているので、送りません。" \
    "%s contains characters that are not accepted, so it is not sent."
_m token_upload_failed \
    "トークンを Colab VM へ送れませんでした。認証が必要なモデルは取得できません。" \
    "Could not send the tokens to the Colab VM. Models that need authentication cannot be fetched."
_m not_ready \
    "Musubi Tuner の準備ができていません。start.bat か ./up.sh を実行してください。" \
    "Musubi Tuner is not ready. Run start.bat or ./up.sh."

# ===== Google ドライブ =====
_m drive_ask \
    "Google ドライブに接続しますか？ モデルと学習結果を保存できます。 [Y/n] " \
    "Connect Google Drive? It can keep models and training results. [Y/n] "
_m drive_already \
    "Google ドライブはマウント済みです。" \
    "Google Drive is already mounted."
_m drive_mounting \
    "Google ドライブをマウントします。認可の URL が表示されたらブラウザで開いて許可し、このウィンドウで Enter を押してください。" \
    "Mounting Google Drive. If an authorization URL appears, open it in a browser, allow access, then press Enter in this window."
_m drive_ready \
    "Google ドライブの %s を使います。" \
    "Using %s on Google Drive."
_m drive_failed \
    "Google ドライブをマウントできませんでした。" \
    "Could not mount Google Drive."
_m drive_required \
    "保存先が Google ドライブですが、マウントできていません。--save-to local を指定するか、もう一度実行してください。" \
    "The save destination is Google Drive, but it is not mounted. Pass --save-to local or run this again."
_m drive_flushing \
    "Google ドライブへの書き込みを完了させて、アンマウントします。" \
    "Finishing writes to Google Drive and unmounting it."
_m drive_flushed \
    "Google ドライブをアンマウントしました。" \
    "Google Drive is unmounted."
_m drive_flush_failed \
    "Google ドライブのアンマウントを確認できませんでした。保存した学習結果は Drive の画面で確かめてください。" \
    "Could not confirm that Google Drive was unmounted. Check the saved training results on Google Drive."

# ===== ランタイム =====
_m units_left \
    "コンピューティングユニットの残り:" \
    "Compute units left:"
_m runtime_exists \
    "ランタイム %s は既にあります。" \
    "Runtime %s already exists."
_m runtime_creating \
    "ランタイムを作成します: %s" \
    "Creating the runtime: %s"
_m ssh_connecting \
    "SSH で接続します。" \
    "Connecting over SSH."
_m gpu_line \
    "GPU: %s" \
    "GPU: %s"
_m gpu_unknown \
    "取得できません" \
    "unknown"
_m gpu_mismatch \
    "GPU が想定と違います。想定: %s" \
    "The GPU is not the expected one. Expected: %s"
_m gpu_continue_prompt \
    "このまま続けますか？ [y/N] " \
    "Continue with this GPU? [y/N] "
_m stopping_to_save \
    "課金を止めるため、ランタイムを削除します。" \
    "Deleting the runtime to stop billing."
_m gpu_aborted \
    "GPU が想定と違うので中止しました。" \
    "Aborted because the GPU is not the expected one."
_m preparing \
    "Musubi Tuner の環境を準備します。初回は数分かかります。" \
    "Preparing Musubi Tuner. The first time takes a few minutes."
_m setup_failed \
    "Musubi Tuner の環境を準備できませんでした。もう一度実行すると続きから進みます。" \
    "Could not prepare Musubi Tuner. Run this again to continue from where it stopped."
_m instance_ready \
    "準備ができました。start-training_QwenImage.bat や start-training_ZImage.bat で学習を始められます。" \
    "Ready. Start training with start-training_QwenImage.bat, start-training_ZImage.bat and the others."
_m usage_hint \
    "ランタイムは動き続け、課金されます。使い終わったら stop.bat で削除してください。" \
    "The runtime keeps running and is billed. Delete it with stop.bat when you are done."
_m stopping_runtime \
    "ランタイム %s を削除します。" \
    "Deleting runtime %s."
_m runtime_already_gone \
    "ランタイム %s は既にありません。" \
    "Runtime %s is already gone."
_m usage_after_stop \
    "コンピューティングユニットの使用状況:" \
    "Compute unit usage:"
_m not_deleted \
    "ランタイムは削除していません。課金は続いています。" \
    "The runtime was not deleted and is still being billed."
_m delete_anyway \
    "回収できなかった学習結果があります。それでも削除しますか？ 結果は失われます。 [y/N] " \
    "Some training results could not be fetched. Delete anyway? They will be lost. [y/N] "
_m training_running_delete \
    "学習 %s が動いています。止めてランタイムを削除しますか？ [y/N] " \
    "Training %s is running. Stop it and delete the runtime? [y/N] "

# ===== 学習 =====
_m unknown_route \
    "知らない学習の種類です: %s" \
    "Unknown training type: %s"
_m unknown_option \
    "知らないオプションです: %s" \
    "Unknown option: %s"
_m bad_save_to \
    "保存先は ask、local、drive のどれかです: %s" \
    "The save destination must be ask, local or drive: %s"
_m already_training \
    "学習 %s が動いているので、新しくは始めません。ログを表示します。" \
    "Training %s is running, so a new one is not started. Showing its log."
_m job_invalid \
    "学習の設定を直してから、もう一度実行してください。" \
    "Fix the training settings and run this again."
_m save_to_choices \
    "学習したモデルの保存先:
  1) 手元の PC。学習の途中と終了時に自動でダウンロードします
  2) Google ドライブ。VM が途中で消えても、そこまでの結果が残ります" \
    "Where to save the trained model:
  1) This PC. It is downloaded automatically during and after training
  2) Google Drive. Results so far survive even if the VM goes away"
_m save_to_prompt \
    "番号 [1]: " \
    "Number [1]: "
_m job_ready \
    "学習 %s の設定を確かめました。保存先: %s" \
    "Checked the settings of training %s. Saving to: %s"
_m sending_job \
    "学習の設定を VM へ送ります。" \
    "Sending the training settings to the VM."
_m sending_dataset \
    "データセットを VM へ送ります: %s" \
    "Sending the dataset to the VM: %s"
_m sending_state \
    "手元の再開用の状態を VM へ送ります。" \
    "Sending the local resume state to the VM."
_m checking_models \
    "モデルを確かめます。無ければ取得します。" \
    "Checking the models. Missing ones are fetched."
_m model_not_found \
    "%s のモデル %s が見つかりません。VM にも Google ドライブにも models.txt にもありません。" \
    "The model for %s, %s, was not found on the VM, on Google Drive or in models.txt."
_m model_url_prompt \
    "モデルの URL。空のまま Enter で中止: " \
    "Model URL. Press Enter to cancel: "
_m model_url_none \
    "URL が無いので中止します。%s を用意してから、もう一度実行してください。ランタイムは動いています。" \
    "Cancelled because no URL was given. Prepare %s and run this again. The runtime is still running."
_m model_url_saved \
    "%s の URL を config/models.local.txt に残しました。次からは尋ねません。" \
    "Saved the URL of %s in config/models.local.txt. It will not be asked again."
_m models_failed \
    "モデルを用意できませんでした。ランタイムは動いています。" \
    "Could not prepare the models. The runtime is still running."
_m unknown_keys \
    "Musubi Tuner が知らないキーが TOML にあります。綴りを確かめてください: %s" \
    "The TOML has keys Musubi Tuner does not know. Check the spelling: %s"
_m missing_files \
    "VM にファイルがありません: %s" \
    "Files are missing on the VM: %s"
_m no_state \
    "再開できる状態がありません: %s" \
    "There is no state to resume from: %s"
_m nothing_left \
    "最後のエポックまで学習済みなので、再開するものがありません。" \
    "Training already reached the last epoch, so there is nothing to resume."
_m resuming \
    "再開します。状態 %s から続けます。" \
    "Resuming from state %s."
_m check_failed \
    "実行前の検査に失敗しました: %s" \
    "The check before training failed: %s"
_m launch_failed \
    "学習を開始できませんでした。" \
    "Could not start training."
_m training_started \
    "学習 %s を開始しました。" \
    "Training %s has started."
_m no_job \
    "学習の記録がありません。" \
    "There is no training on record."
_m follow_start \
    "学習 %s のログを表示します。Ctrl+C で表示をやめても学習は続きます。" \
    "Showing the log of training %s. Ctrl+C stops the display, and training keeps running."
_m follow_reconnect \
    "SSH が切れました。つなぎ直します。学習は VM で続いています。" \
    "SSH was cut. Reconnecting. Training continues on the VM."
_m detached \
    "表示をやめました。学習は VM で続いています。logs.bat で表示し直せます。止めるときは stop-training.bat を実行します。" \
    "Stopped the display. Training continues on the VM. logs.bat shows it again, and stop-training.bat stops it."
_m train_succeeded \
    "学習 %s が完了しました。" \
    "Training %s finished."
_m train_stopped \
    "学習 %s は止められました。" \
    "Training %s was stopped."
_m train_failed \
    "学習 %s は失敗しました。状態: %s。上のログを確かめてください。" \
    "Training %s failed. State: %s. Check the log above."
_m train_gone \
    "ランタイム %s が消えました。保存先が手元の PC なら、途中までの結果は outputs にあります。--resume で再開できます。" \
    "Runtime %s is gone. If saving to this PC, results so far are in outputs. --resume continues training."
_m saved_on_drive \
    "学習結果は Google ドライブにあります: %s" \
    "The training results are on Google Drive: %s"
_m runtime_still_billed \
    "ランタイムは動き続け、課金されます。使い終わったら stop.bat で削除してください。" \
    "The runtime keeps running and is billed. Delete it with stop.bat when you are done."
_m stopping_training \
    "学習 %s を止めます。" \
    "Stopping training %s."
_m no_running_job \
    "動いている学習はありません。" \
    "No training is running."
_m stop_training_failed \
    "学習を止められませんでした。" \
    "Could not stop training."

# ===== 学習結果 =====
_m pull_none \
    "VM に学習結果はありません。" \
    "There are no training results on the VM."
_m pull_start \
    "学習結果 %s を手元へコピーします: %s" \
    "Copying training results %s here: %s"
_m pull_verified \
    "%s をコピーし、中身が一致することを確かめました。" \
    "Copied %s and confirmed that the contents match."
_m pull_failed \
    "%s のコピーを確かめられませんでした。もう一度 pull-outputs.bat を実行してください。" \
    "Could not confirm the copy of %s. Run pull-outputs.bat again."
_m pull_drive_needed \
    "Google ドライブがマウントされていません。" \
    "Google Drive is not mounted."

# ===== model-download =====
_m md_url \
    "モデルの URL: " \
    "Model URL: "
_m md_filename \
    "保存するファイル名。URL のままなら空のまま Enter: " \
    "File name to save as. Press Enter to use the one in the URL: "
_m md_where \
    "保存する場所:
  1) ランタイムだけ。いちばん速く、ランタイムの削除で消えます
  2) Google ドライブにも残す。次のランタイムでも使えます" \
    "Where to save it:
  1) The runtime only. Fastest, and it is deleted with the runtime
  2) Google Drive too. It can be used by the next runtime"
_m md_where_prompt \
    "番号 [2]: " \
    "Number [2]: "
_m md_no_drive \
    "Google ドライブがマウントされていないので、ランタイムに保存します。" \
    "Google Drive is not mounted, so the model is saved on the runtime."
_m md_starting \
    "ダウンロードします: %s" \
    "Downloading: %s"
_m md_failed \
    "ダウンロードできませんでした。" \
    "The download failed."
_m md_done \
    "終わりました。学習の TOML にファイル名を書くと使えます。" \
    "Done. Write the file name in the training TOML to use it."

# ===== status.sh =====
_m st_runtime \
    "ランタイム %s:" \
    "Runtime %s:"
_m st_vm \
    "VM:" \
    "VM:"
_m st_ssh_fail \
    "SSH で確認できません。" \
    "Cannot check over SSH."
_m st_none \
    "ありません。" \
    "None."
_m st_setup_done \
    "Musubi Tuner: 準備済み" \
    "Musubi Tuner: ready"
_m st_setup_not \
    "Musubi Tuner: 未準備" \
    "Musubi Tuner: not ready"
_m st_drive_on \
    "Google ドライブ: マウント済み" \
    "Google Drive: mounted"
_m st_drive_off \
    "Google ドライブ: 未接続" \
    "Google Drive: not mounted"
_m st_job \
    "学習 %s: %s" \
    "Training %s: %s"
_m st_units \
    "コンピューティングユニット:" \
    "Compute units:"

# ===== setup-wsl.sh =====
_m sw_apt \
    "必要なパッケージを入れます。" \
    "Installing the required packages."
_m sw_uv \
    "uv を確認します。" \
    "Checking uv."
_m sw_colab \
    "Colab CLI を入れます。" \
    "Installing the Colab CLI."
_m sw_key \
    "SSH 鍵を確認します。" \
    "Checking the SSH key."
_m sw_key_exists \
    "SSH 鍵はあります。" \
    "The SSH key exists."
_m sw_done \
    "準備ができました。次に colab usage を実行して Google アカウントを認証してください。" \
    "Done. Next, run colab usage to authenticate your Google account."

# ===== Colab VM 側 =====
_m r_lock_timeout \
    "ほかの準備が終わりません: %s" \
    "Another setup does not finish: %s"
_m r_already_ready \
    "Musubi Tuner は準備済みです。" \
    "Musubi Tuner is ready."
_m r_installing \
    "パッケージを入れます: %s" \
    "Installing packages: %s"
_m r_uv \
    "uv を入れます。" \
    "Installing uv."
_m r_fetching \
    "Musubi Tuner を取得します: %s %s" \
    "Fetching Musubi Tuner: %s %s"
_m r_venv \
    "uv で Python 環境を作ります: %s" \
    "Creating the Python environment with uv: %s"
_m r_torch \
    "PyTorch を入れます: %s" \
    "Installing PyTorch: %s"
_m r_torch_strict \
    "Colab の PyTorch が %s より古いか無いので、別の版を入れます。" \
    "Colab's PyTorch is older than %s or missing, so another version is installed."
_m r_requirements \
    "Musubi Tuner と依存するパッケージを入れます。" \
    "Installing Musubi Tuner and its dependencies."
_m r_extra \
    "追加のパッケージを入れます: %s" \
    "Installing extra packages: %s"
_m r_torch_replaced \
    "依存するパッケージが PyTorch を %s から %s に置き換えました。MUSUBI_EXTRA_PACKAGES か MUSUBI_REF を見直してください。" \
    "A dependency replaced PyTorch %s with %s. Review MUSUBI_EXTRA_PACKAGES or MUSUBI_REF."
_m r_import_failed \
    "入れたパッケージを読み込めません。上のエラーを確かめてください。" \
    "The installed packages cannot be imported. Check the error above."
_m r_ready \
    "Musubi Tuner の準備ができました。コミット %s" \
    "Musubi Tuner is ready. Commit %s"
