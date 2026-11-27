import os
import stat
import sys
import tempfile
from pathlib import Path

import tomlkit

target = Path(sys.argv[1])
managed_path = Path(sys.argv[2])
owned_keys = {
    "model",
    "model_reasoning_effort",
    "approval_policy",
    "sandbox_mode",
    "web_search",
    "allow_login_shell",
}
managed_table_keys = {
    "shell_environment_policy": {"ignore_default_excludes"},
    "sandbox_workspace_write": {"network_access"},
    "tui": {"status_line"},
}

target.parent.mkdir(parents=True, exist_ok=True)
mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o600
current_text = target.read_text() if target.exists() else ""
current = tomlkit.parse(current_text) if current_text.strip() else tomlkit.document()
managed = tomlkit.parse(managed_path.read_text())

for key in owned_keys:
    current.pop(key, None)
for table_name, keys in managed_table_keys.items():
    table = current.get(table_name)
    if table is not None:
        for key in keys:
            table.pop(key, None)
for key, value in managed.items():
    if key in managed_table_keys:
        table = current.get(key)
        if table is None:
            table = tomlkit.table()
            current[key] = table
        for option, option_value in value.items():
            table[option] = option_value
    else:
        current[key] = value

file_descriptor, temporary_name = tempfile.mkstemp(dir=target.parent, prefix=".codex-config-")
try:
    with os.fdopen(file_descriptor, "w") as temporary_file:
        temporary_file.write(tomlkit.dumps(current))
    os.chmod(temporary_name, mode)
    os.replace(temporary_name, target)
except BaseException:
    os.unlink(temporary_name)
    raise
