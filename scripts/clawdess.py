#!/usr/bin/env python3
"""clawdess: send photos, videos, or voice messages via OpenClaw."""

import argparse
import os
import sys

# Allow imports from scripts/ directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

DEFAULT_PROVIDERS = {
    "photo": "YUNWU",
    "video": "YUNWU",
    "voice": "YUNWU",
}


def build_parser():
    parser = argparse.ArgumentParser(
        description="clawdess: send photos, videos, or voice messages via OpenClaw",
        epilog="Run `python3 scripts/clawdess.py providers` to list available providers.",
    )
    sub = parser.add_subparsers(dest="mode", required=True)

    sub.add_parser("providers", help="List available providers")

    # -- photo --
    p_photo = sub.add_parser("photo", help="Generate an edited photo")
    p_photo.add_argument("--api", help="Photo API key (or env CLAWDESS_PHOTO_API)")
    p_photo.add_argument("--prompt", "-p", required=True, help="Image edit prompt")
    p_photo.add_argument("--image", "-i", required=True, help="Reference image URL")
    p_photo.add_argument(
        "--provider",
        "-s",
        default=DEFAULT_PROVIDERS["photo"],
        help=f"Photo provider (default: {DEFAULT_PROVIDERS['photo']})",
    )

    # -- video --
    p_video = sub.add_parser("video", help="Generate a video from an image")
    p_video.add_argument("--api", help="Video API key (or env CLAWDESS_VIDEO_API)")
    p_video.add_argument("--prompt", "-p", required=True, help="Video prompt")
    p_video.add_argument("--image", "-i", required=True, help="Source image URL")
    p_video.add_argument(
        "--provider",
        "-s",
        default=DEFAULT_PROVIDERS["video"],
        help=f"Video provider (default: {DEFAULT_PROVIDERS['video']})",
    )

    # -- voice --
    p_voice = sub.add_parser("voice", help="Generate a voice message")
    p_voice.add_argument("--api", help="Voice TTS API key (or env CLAWDESS_VOICE_API)")
    p_voice.add_argument("--prompt", "-p", required=True, help="Text to speak")
    p_voice.add_argument(
        "--provider",
        "-s",
        default=DEFAULT_PROVIDERS["voice"],
        help=f"Voice provider (default: {DEFAULT_PROVIDERS['voice']})",
    )

    return parser


def list_providers():
    from common import discover_providers

    for mode, default in DEFAULT_PROVIDERS.items():
        providers = sorted(discover_providers(mode))
        names = [
            f"{name} (default)" if name == default else name
            for name in providers
        ]
        print(f"{mode}: {', '.join(names)}")


def main():
    parser = build_parser()
    args = parser.parse_args()

    if args.mode == "providers":
        list_providers()
        return
    elif args.mode == "photo":
        from photo import run_photo
        run_photo(args)
    elif args.mode == "video":
        from video import run_video
        run_video(args)
    elif args.mode == "voice":
        from voice import run_voice
        run_voice(args)

    print("\nDone!")


if __name__ == "__main__":
    main()
