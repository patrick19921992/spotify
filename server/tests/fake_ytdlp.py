"""Attrappe für yt-dlp: gibt Fortschritt im selben Format aus und erzeugt echte kleine Mediendateien.

Video-IDs steuern das Verhalten: "fail…" = Fehler, "hang…" = hängt (zum Abbrechen), sonst Erfolg.
"""

import json
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

args = sys.argv[1:]


def out(line: str) -> None:
    print(line, flush=True)


if "--version" in args:
    out("2026.08.19-fake")
    sys.exit(0)

url = args[-1]
query = parse_qs(urlparse(url).query)
video_id = (query.get("v") or ["unknown0000"])[0]

if "--flat-playlist" in args:
    if "list" in query:
        for index in range(1, 4):
            out("SELFIFY-ENTRY " + json.dumps(
                {"id": f"playlist00{index}", "title": f"Playlist Song {index}", "channel": "Band - Topic",
                 "duration": 2}
            ))
    else:
        out("SELFIFY-ENTRY " + json.dumps({"id": video_id, "title": "Einzelnes Video", "uploader": "Kanal"}))
    sys.exit(0)

template = args[args.index("-o") + 1]
workdir = Path(template).parent
is_audio = "-x" in args

if video_id.startswith("fail"):
    print(f"ERROR: [youtube] {video_id}: Video unavailable. This video is private", file=sys.stderr, flush=True)
    sys.exit(1)

formats = [("251", 60000)] if is_audio else [("137", 300000), ("140", 100000)]
if is_audio:
    out("SELFIFY-PLAN NA")
else:
    out("SELFIFY-PLAN " + json.dumps([{"format_id": f, "filesize": s, "filesize_approx": None} for f, s in formats]))

for format_id, size in formats:
    for step in range(1, 6):
        done = size * step // 5
        status = "finished" if step == 5 else "downloading"
        out(f"SELFIFY-DL {status}|{done}|{size}|NA|100000.0|{(size - done) // 100000}|{format_id}")
        time.sleep(0.03)
        if video_id.startswith("hang"):
            time.sleep(60)

out("SELFIFY-PP started|" + ("ExtractAudio" if is_audio else "Merger"))
ffmpeg = shutil.which("ffmpeg")
if is_audio:
    target = workdir / f"{video_id}.opus"
    subprocess.run([ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=500:duration=1.5",
                    "-c:a", "libopus", "-b:a", "96k", str(target)], check=True)
else:
    target = workdir / f"{video_id}.mp4"
    subprocess.run([ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=1.5:size=640x360:rate=10",
                    "-f", "lavfi", "-i", "sine=frequency=500:duration=1.5", "-c:v", "libx264", "-pix_fmt",
                    "yuv420p", "-c:a", "aac", "-shortest", str(target)], check=True)
    from PIL import Image

    Image.new("RGB", (1280, 720), (10, 120, 200)).save(workdir / f"{video_id}.jpg", "JPEG")
out("SELFIFY-PP finished|" + ("ExtractAudio" if is_audio else "Merger"))
out(f"SELFIFY-FILE {target}")
out("SELFIFY-INFO " + json.dumps({
    "id": video_id, "title": "Original Titel (Official Video)", "track": "Yt Track", "artist": "Yt Artist",
    "album": "Yt Album", "release_year": 2021, "duration": 1.5, "channel": "Yt Artist - Topic",
}))
