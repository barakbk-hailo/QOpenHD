#!/usr/bin/env python3
"""
embed_recording.py — Offline embed tool for QOpenHD ground recordings.

Composites detection bounding boxes and/or HUD overlay onto recorded video.
Runs on the Pi (when OpenHD is off) or on any host with ffmpeg + Python 3.

Usage:
    python3 embed_recording.py ~/Videos/ground_20260324_165522.mp4
    python3 embed_recording.py ~/Videos/ground_20260324_165522.mp4 --no-hud -r 1280x720
    python3 embed_recording.py ~/Videos/ --all          # process all recordings in dir

Requirements:
    - ffmpeg and ffprobe on PATH
    - Python 3.8+
    - numpy, Pillow  (pip install numpy Pillow)

File conventions (from QOpenHD ground recorder):
    recording.mp4   — raw H.264 video
    recording.jsonl — one JSON object per frame: {ts_us, dets: [{cx,cy,w,h,tracked,...}]}
    recording.osd   — OSD3 binary (sparse RGBA tiles captured from HUD)
"""

import argparse
import json
import struct
import subprocess
import sys
import time
from pathlib import Path

try:
    import numpy as np
except ImportError:
    sys.exit("Error: numpy is required.  pip install numpy")
try:
    from PIL import Image
except ImportError:
    sys.exit("Error: Pillow is required.  pip install Pillow")


# ────────────────────────────────────────────────────────────
#  Video probing
# ────────────────────────────────────────────────────────────

def ffprobe_video(mp4_path):
    """Return (width, height, fps) for a video file."""
    cmd = [
        "ffprobe", "-v", "quiet", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate",
        "-of", "json", str(mp4_path),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"ffprobe failed on {mp4_path}")
    info = json.loads(r.stdout)
    s = info["streams"][0]
    w, h = int(s["width"]), int(s["height"])
    num, den = map(int, s["r_frame_rate"].split("/"))
    fps = num / den if den else 30.0
    return w, h, fps


# ────────────────────────────────────────────────────────────
#  BB loading  (JSONL)
# ────────────────────────────────────────────────────────────

def load_bbs(jsonl_path):
    """Load BB frames → list of (ts_us, dets_list), sorted by timestamp."""
    frames = []
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            frames.append((obj.get("ts_us", 0), obj.get("dets", [])))
    frames.sort(key=lambda x: x[0])
    return frames


# ────────────────────────────────────────────────────────────
#  OSD loading  (OSD3 binary — sparse RGBA tiles)
# ────────────────────────────────────────────────────────────

def load_osd3(osd_path):
    """Load OSD3 file → (osd_w, osd_h, [(ts_us, rgba_array), ...])."""
    with open(osd_path, "rb") as f:
        raw = f.read(24)
        if len(raw) < 24:
            return 0, 0, []
        magic, w, h, _fps, tile_size, _res = struct.unpack("<6I", raw)
        if magic != 0x4F534433:
            print(f"  Warning: not OSD3 (magic 0x{magic:08X}), skipping")
            return 0, 0, []
        if tile_size < 1:
            tile_size = 16
        tiles_x = (w + tile_size - 1) // tile_size
        tile_bytes = tile_size * tile_size * 4

        frames = []
        while True:
            ts_data = f.read(8)
            if len(ts_data) < 8:
                break
            ts_us = struct.unpack("<Q", ts_data)[0]
            nt_data = f.read(2)
            if len(nt_data) < 2:
                break
            num_tiles = struct.unpack("<H", nt_data)[0]

            rgba = np.zeros((h, w, 4), dtype=np.uint8)
            ok = True
            for _ in range(num_tiles):
                idx_data = f.read(2)
                if len(idx_data) < 2:
                    ok = False
                    break
                tile_idx = struct.unpack("<H", idx_data)[0]
                tdata = f.read(tile_bytes)
                if len(tdata) < tile_bytes:
                    ok = False
                    break
                tx = tile_idx % tiles_x
                ty = tile_idx // tiles_x
                x0, y0 = tx * tile_size, ty * tile_size
                tile = np.frombuffer(tdata, dtype=np.uint8).reshape(
                    tile_size, tile_size, 4
                )
                ch = min(tile_size, h - y0)
                cw = min(tile_size, w - x0)
                if ch > 0 and cw > 0:
                    rgba[y0 : y0 + ch, x0 : x0 + cw] = tile[:ch, :cw]
            if not ok:
                break
            frames.append((ts_us, rgba))

    print(f"  OSD loaded: {len(frames)} frames, {w}x{h}, tile={tile_size}")
    return w, h, frames


# ────────────────────────────────────────────────────────────
#  Timestamp matching
# ────────────────────────────────────────────────────────────

def find_closest(timestamps, target):
    """Return index of closest timestamp (linear scan with early exit)."""
    if not timestamps:
        return -1
    best, best_diff = 0, abs(timestamps[0] - target)
    for i in range(1, len(timestamps)):
        d = abs(timestamps[i] - target)
        if d < best_diff:
            best_diff = d
            best = i
        if timestamps[i] > target:
            break
    return best


# ────────────────────────────────────────────────────────────
#  Drawing helpers
# ────────────────────────────────────────────────────────────

def draw_bbs(frame, dets, out_w, out_h):
    """Draw bounding-box rectangles onto an RGB numpy frame (H×W×3)."""
    for det in dets:
        cx, cy = det["cx"], det["cy"]
        bw, bh = det["w"], det["h"]
        tracked = det.get("tracked", False)

        x1 = max(0, int((cx - bw / 2) * out_w))
        y1 = max(0, int((cy - bh / 2) * out_h))
        x2 = min(out_w, int((cx + bw / 2) * out_w))
        y2 = min(out_h, int((cy + bh / 2) * out_h))

        if tracked:
            color = [0, 255, 0]
            thick = 2
        else:
            color = [255, 255, 255]
            thick = 1

        c = np.array(color, dtype=np.uint8)

        # Top / bottom edges
        for t in range(thick):
            yt = min(y1 + t, out_h - 1)
            yb = max(y2 - 1 - t, 0)
            frame[yt, x1:x2] = c
            frame[yb, x1:x2] = c
        # Left / right edges
        for t in range(thick):
            xl = min(x1 + t, out_w - 1)
            xr = max(x2 - 1 - t, 0)
            frame[y1:y2, xl] = c
            frame[y1:y2, xr] = c


def composite_hud(frame, osd_rgba, out_w, out_h):
    """Alpha-composite RGBA OSD overlay onto RGB frame, resizing if needed."""
    oh, ow = osd_rgba.shape[:2]

    # Resize OSD to match output resolution via Lanczos
    if ow != out_w or oh != out_h:
        img = Image.fromarray(osd_rgba, "RGBA")
        img = img.resize((out_w, out_h), Image.LANCZOS)
        osd_rgba = np.array(img)

    alpha = osd_rgba[:, :, 3]
    mask = alpha > 0
    if not mask.any():
        return

    # Vectorised alpha blend only where HUD pixels exist
    a = alpha[mask].astype(np.float32)[:, np.newaxis] / 255.0
    frame[mask] = (
        (1.0 - a) * frame[mask].astype(np.float32)
        + a * osd_rgba[:, :, :3][mask].astype(np.float32)
    ).astype(np.uint8)


# ────────────────────────────────────────────────────────────
#  Main processing
# ────────────────────────────────────────────────────────────

def process_one(mp4_path, args):
    """Process a single recording."""
    mp4 = Path(mp4_path)
    base = mp4.with_suffix("")
    jsonl = base.with_suffix(".jsonl")
    osd = base.with_suffix(".osd")
    out = mp4.parent / f"{base.name}{args.suffix}.mp4"

    print(f"\n{'='*60}")
    print(f"  Input:  {mp4}")

    # ── probe ──
    vid_w, vid_h, vid_fps = ffprobe_video(mp4)
    print(f"  Source: {vid_w}x{vid_h} @ {vid_fps:.2f} fps")

    # ── output resolution ──
    if args.resolution.lower() == "original":
        out_w, out_h = vid_w, vid_h
    else:
        parts = args.resolution.lower().split("x")
        out_w, out_h = int(parts[0]), int(parts[1])
    print(f"  Output: {out_w}x{out_h} → {out}")

    # ── load BBs ──
    bb_frames, bb_ts = [], []
    do_det = args.detections
    if do_det and jsonl.exists():
        bb_frames = load_bbs(jsonl)
        bb_ts = [f[0] for f in bb_frames]
        print(f"  BBs:    {len(bb_frames)} entries")
    else:
        if do_det:
            print("  No .jsonl found — skipping detections")
        do_det = False

    # ── load OSD ──
    osd_w, osd_h, osd_frames = 0, 0, []
    osd_ts = []
    do_hud = args.hud
    if do_hud and osd.exists():
        osd_w, osd_h, osd_frames = load_osd3(osd)
        osd_ts = [f[0] for f in osd_frames]
        if not osd_frames:
            do_hud = False
    else:
        if do_hud:
            print("  No .osd found — skipping HUD")
        do_hud = False

    if not do_det and not do_hud:
        print("  Nothing to embed (no data or all disabled). Skipping.")
        return

    # ── decoder pipe (ffmpeg → raw RGB) ──
    dec_args = ["ffmpeg", "-i", str(mp4)]
    if out_w != vid_w or out_h != vid_h:
        dec_args += ["-vf", f"scale={out_w}:{out_h}:flags=lanczos"]
    dec_args += ["-f", "rawvideo", "-pix_fmt", "rgb24", "-v", "quiet", "-"]
    dec = subprocess.Popen(dec_args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    # ── encoder pipe (raw RGB → mp4) ──
    enc_args = [
        "ffmpeg",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-video_size", f"{out_w}x{out_h}",
        "-framerate", f"{vid_fps:.2f}",
        "-i", "pipe:0",
        "-pix_fmt", "yuv420p",
        "-c:v", "libx264", "-preset", args.preset, "-crf", str(args.crf),
        "-movflags", "+faststart",
        "-y", str(out),
    ]
    enc = subprocess.Popen(enc_args, stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)

    frame_size = out_w * out_h * 3
    frame_dur_us = 1_000_000.0 / vid_fps
    frame_idx = 0
    t0 = time.monotonic()

    try:
        while True:
            raw = dec.stdout.read(frame_size)
            if len(raw) < frame_size:
                break
            frame = np.frombuffer(raw, dtype=np.uint8).reshape(out_h, out_w, 3).copy()
            ts = int(frame_idx * frame_dur_us)

            if do_det and bb_frames:
                idx = find_closest(bb_ts, ts)
                if idx >= 0:
                    draw_bbs(frame, bb_frames[idx][1], out_w, out_h)

            if do_hud and osd_frames:
                idx = find_closest(osd_ts, ts)
                if idx >= 0:
                    composite_hud(frame, osd_frames[idx][1], out_w, out_h)

            enc.stdin.write(frame.tobytes())
            frame_idx += 1

            if frame_idx % 30 == 0:
                elapsed = time.monotonic() - t0
                fps_actual = frame_idx / elapsed if elapsed > 0 else 0
                print(f"\r  Frame {frame_idx} ({fps_actual:.1f} fps) ...", end="", flush=True)

    except BrokenPipeError:
        print(f"\n  Encoder pipe broke at frame {frame_idx}")
    finally:
        dec.stdout.close()
        dec.wait()
        if enc.stdin and not enc.stdin.closed:
            enc.stdin.close()
        enc.wait()

    elapsed = time.monotonic() - t0
    print(f"\n  Done: {frame_idx} frames in {elapsed:.1f}s → {out}")


def find_recordings(input_path, suffix):
    """Discover recording .mp4 files (skip already-embedded ones)."""
    p = Path(input_path)
    if p.is_file() and p.suffix == ".mp4":
        return [p]
    if p.is_dir():
        recs = []
        for mp4 in sorted(p.glob("*.mp4")):
            stem = mp4.stem
            # Skip files that are already embeds
            if stem.endswith(suffix) or stem.endswith("_BBs"):
                continue
            # Only process if there's companion data
            base = mp4.with_suffix("")
            if base.with_suffix(".jsonl").exists() or base.with_suffix(".osd").exists():
                recs.append(mp4)
        return recs
    print(f"Error: {input_path} is not a .mp4 file or directory")
    sys.exit(1)


def parse_args():
    p = argparse.ArgumentParser(
        description="Embed detections & HUD overlay into QOpenHD ground recordings",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
examples:
  %(prog)s ~/Videos/ground_20260324_165522.mp4
  %(prog)s ~/Videos/ground_20260324_165522.mp4 --no-hud -r 1280x720
  %(prog)s ~/Videos/ --all
  %(prog)s ~/Videos/ --all --no-detections --hud -r 1920x1080
""",
    )
    p.add_argument("input", help="Recording .mp4 file or directory")
    p.add_argument("--all", action="store_true",
                   help="Process all recordings in directory (default: latest only)")

    det_g = p.add_mutually_exclusive_group()
    det_g.add_argument("--detections", action="store_true", default=True, dest="detections",
                       help="Include detection bounding boxes (default)")
    det_g.add_argument("--no-detections", action="store_false", dest="detections",
                       help="Disable detection bounding boxes")

    hud_g = p.add_mutually_exclusive_group()
    hud_g.add_argument("--hud", action="store_true", default=True, dest="hud",
                       help="Include HUD overlay (default)")
    hud_g.add_argument("--no-hud", action="store_false", dest="hud",
                       help="Disable HUD overlay")

    p.add_argument("-r", "--resolution", default="1920x1080",
                   help="Output resolution WxH (default: 1920x1080, or 'original')")
    p.add_argument("--crf", type=int, default=20,
                   help="H.264 CRF quality (default: 20, lower = better)")
    p.add_argument("--preset", default="fast",
                   choices=["ultrafast", "superfast", "veryfast", "faster",
                            "fast", "medium", "slow", "slower", "veryslow"],
                   help="x264 encoding preset (default: fast)")
    p.add_argument("--suffix", default="_embed",
                   help="Output filename suffix (default: _embed)")
    return p.parse_args()


def main():
    args = parse_args()

    recordings = find_recordings(args.input, args.suffix)
    if not recordings:
        print("No recordings found to process.")
        sys.exit(0)

    # If directory given without --all, pick latest only
    if not args.all and len(recordings) > 1:
        recordings = [recordings[-1]]
        print(f"Processing latest recording only (use --all for all {len(recordings)} recordings)")

    print(f"Recordings to process: {len(recordings)}")
    print(f"Options: detections={args.detections}, hud={args.hud}, "
          f"resolution={args.resolution}, crf={args.crf}, preset={args.preset}")

    for mp4 in recordings:
        process_one(mp4, args)

    print(f"\nAll done. {len(recordings)} recording(s) processed.")


if __name__ == "__main__":
    main()
