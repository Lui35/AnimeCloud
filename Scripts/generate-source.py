#!/usr/bin/env python3
"""Build a LiveContainer/AltStore source from the exact IPA being released."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
from urllib.parse import quote
import zipfile


def generate_source(ipa, tag, repository, date):
    with zipfile.ZipFile(ipa) as archive:
        manifests = [name for name in archive.namelist()
                     if name.startswith("Payload/") and name.endswith(".app/Info.plist") and name.count("/") == 2]
        if len(manifests) != 1:
            raise ValueError("Expected exactly one application Info.plist in the IPA")
        info = plistlib.loads(archive.read(manifests[0]))
    version = info["CFBundleShortVersionString"]
    if tag != "v" + version:
        raise ValueError("Release tag must match the IPA version")
    if info["CFBundleIdentifier"] != "com.animecloud.reborn":
        raise ValueError("IPA bundle identifier must match AnimeCloud")
    base = f"https://github.com/{repository}"
    icon = f"https://raw.githubusercontent.com/{repository}/main/AnimeCloud/Resources/Assets.xcassets/AppIcon.appiconset/AnimeCloudIcon.png"
    release = {
        "version": version,
        "buildVersion": str(info["CFBundleVersion"]),
        "date": date,
        "downloadURL": f"{base}/releases/download/{quote(tag, safe='')}/{quote(ipa.name, safe='')}",
        "size": ipa.stat().st_size,
        "minOSVersion": info["MinimumOSVersion"],
    }
    return {
        "name": "AnimeCloud",
        "identifier": "com.animecloud.source",
        "subtitle": "Official AnimeCloud releases",
        "description": "Install and update AnimeCloud in LiveContainer.",
        "website": base,
        "sourceURL": f"{base}/releases/latest/download/source.json",
        "iconURL": icon,
        "apps": [{
            "name": "Anime Cloud",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": repository.split("/")[0],
            "subtitle": "Discover, track, and watch anime",
            "localizedDescription": "A native anime client with offline downloads, watch tracking, and Anime4K playback. Import this unsigned app with LiveContainer.",
            "iconURL": icon,
            "category": "entertainment",
            "versions": [release],
            "version": version,
            "versionDate": date,
            "downloadURL": release["downloadURL"],
            "size": release["size"],
            "appPermissions": {"entitlements": [], "privacy": [
                {"name": "NSPhotoLibraryUsageDescription", "usageDescription": info["NSPhotoLibraryUsageDescription"]}
            ]},
        }],
        "news": [],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("tag")
    parser.add_argument("output", type=Path)
    parser.add_argument("--repository", default="Lui35/AnimeCloud")
    parser.add_argument("--date", default=datetime.now(timezone.utc).isoformat())
    args = parser.parse_args()
    source = generate_source(args.ipa, args.tag, args.repository, args.date)
    args.output.write_text(json.dumps(source, indent=2) + "\n", encoding="utf-8")
