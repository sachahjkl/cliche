type: Changed

**Each capture runs its workflow**: the shortcuts, the tray's items and the commands (`--region`, `--screen`, `--window`, `--edit`, `--qr`, `--ocr`) each run one workflow, chosen in the workflow's triggers. A capture may start while another one's workflow waits on the editor.
