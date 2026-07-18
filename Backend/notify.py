import subprocess


def notify(title, message):
    safe_title = title.replace('"', '\\"')
    safe_message = message.replace('"', '\\"')
    try:
        subprocess.run(
            [
                "osascript",
                "-e",
                f'display notification "{safe_message}" with title "{safe_title}"',
            ],
            check=False,
            capture_output=True,
        )
    except Exception:
        pass
