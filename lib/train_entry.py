"""accelerate launch から起動され、Musubi Tuner の学習スクリプトを動かす。remote_train.py が使う。

    train_entry.py SCRIPT [引数...]

SCRIPT は Musubi Tuner のフォルダーにある <種類>_train_network.py。
環境変数 MUSUBI_COLAB_DONE_EPOCHS に済んだエポック数があれば、その数だけエポックを飛ばして続きから学習する。
Musubi Tuner の --resume は state を読み込むだけで、エポックは最初から数え直す。そのままでは済んだ分を繰り返し、
エポックごとのファイルも同じ名前で上書きするので、エポックの繰り返しの始まりをずらす。
"""

import builtins
import os
from pathlib import Path
import runpy
import sys

EPOCH_LOOP = "for epoch in range(epoch_to_start, num_train_epochs):"

script = sys.argv[1]
sys.argv = [script, *sys.argv[2:]]
done = int(os.environ.get("MUSUBI_COLAB_DONE_EPOCHS") or 0)
if done > 0:
    from musubi_tuner.training import trainer_base

    # エポックの繰り返しは trainer_base の中で 2 つの引数を取る唯一の range なので、そこだけを差し替える
    if EPOCH_LOOP not in Path(trainer_base.__file__).read_text(encoding="utf-8"):
        raise SystemExit("[musubi-tuner-colab-cli] This Musubi Tuner version changed its epoch loop. Resume is not supported.")

    def epoch_range(*args):
        if len(args) == 2 and args[0] == 0:
            return builtins.range(min(done, args[1]), args[1])
        return builtins.range(*args)

    trainer_base.range = epoch_range
    print(f"[musubi-tuner-colab-cli] skipping {done} finished epochs", flush=True)

runpy.run_path(script, run_name="__main__")
