#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Pulsar OS - Release Manifest & Cloudflare Pages Generator
Generates and updates hierarchical releases.json and static HTML site for Internet Recovery.
Preserves historical releases and scans all build artifacts (Debian & Arch, GRUB & rEFInd).
"""

import sys
import os
import re
import argparse
import hashlib
import json
import urllib.request
from pathlib import Path

DEFAULT_PROJECT = "pulsaros-inled"
DEFAULT_BASE_URL = "https://downloads.sourceforge.net/project"

DEFAULT_MIRRORS = [
    {"id": "auto", "name": "Automático (SourceForge CDN / Fast Anycast)"},
    {"id": "netix", "name": "NetIX (Europa / Internacional)"},
    {"id": "deac-riga", "name": "DEAC Riga (Europa del Norte)"},
    {"id": "altushost-swe", "name": "AltusHost (Suecia)"},
    {"id": "liquidtelecom", "name": "Liquid Telecom (África / Global)"},
    {"id": "cfhcable", "name": "CFH Cable (Norteamérica)"}
]

ALL_BASES = ["arch", "debian"]
ALL_BOOTLOADERS = ["grub", "refind"]

def sha256_file(filepath: str) -> str:
    if not os.path.exists(filepath):
        return ""
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def get_file_size(filepath: str) -> int:
    try:
        return os.path.getsize(filepath)
    except Exception:
        return 0

def fetch_remote_manifest() -> dict:
    urls = [
        "https://pulsaros-releases.pages.dev/releases.json",
        "https://releases.pulsaros.inled.es/releases.json",
        "https://raw.githubusercontent.com/Inled-Pulsar-OS/ISO/main/configs/releases.json"
    ]
    for u in urls:
        try:
            req = urllib.request.Request(u, headers={"User-Agent": "PulsarOS-Manifest-Builder/1.0"})
            with urllib.request.urlopen(req, timeout=4) as response:
                if response.status == 200:
                    return json.loads(response.read().decode("utf-8"))
        except Exception:
            continue
    return {}

def generate_manifest(args):
    manifest_path = Path(args.output_json)
    data = {}

    # 1. Load existing manifest from local file or remote fallback to preserve version history
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            print(f"Warning: Could not read local manifest: {e}")

    if not data or "versions" not in data or not data["versions"]:
        template_configs = Path("ISO/configs/releases.json")
        if not template_configs.exists():
            template_configs = Path("configs/releases.json")
        if template_configs.exists():
            try:
                with open(template_configs, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except Exception:
                pass

    if not data or "versions" not in data or not data["versions"]:
        remote_data = fetch_remote_manifest()
        if remote_data and "versions" in remote_data:
            data = remote_data

    if "mirrors" not in data or not data["mirrors"]:
        data["mirrors"] = DEFAULT_MIRRORS

    if "versions" not in data:
        data["versions"] = {}

    version = args.version
    if "latest_version" not in data or args.set_latest:
        data["latest_version"] = version

    if version not in data["versions"]:
        data["versions"][version] = {}

    v_node = data["versions"][version]

    project = args.project or DEFAULT_PROJECT
    base_url = f"{DEFAULT_BASE_URL}/{project}"

    # 2. Ensure all combinations of base (arch, debian) and bootloader (grub, refind) exist
    for base in ALL_BASES:
        if base not in v_node:
            v_node[base] = {}
        for boot in ALL_BOOTLOADERS:
            if boot not in v_node[base]:
                v_node[base][boot] = {
                    "squashfs": f"{base_url}/pulsaros-{version}-{base}-{boot}-{version}.squashfs",
                    "iso": f"{base_url}/pulsaros-{version}-{base}-{boot}-{version}.iso",
                    "sha256": "",
                    "size_bytes": 3145728000 if base == "arch" else 2800000000
                }

    # 3. If a dist directory was provided, scan all files to update hashes, sizes and URLs
    if args.dist_dir and os.path.exists(args.dist_dir):
        print(f"🔍 Scanning build artifacts in dist directory: {args.dist_dir}")
        for entry in os.scandir(args.dist_dir):
            if not entry.is_file():
                continue
            fname = entry.name.lower()
            if not (fname.endswith(".iso") or fname.endswith(".squashfs")):
                continue

            # Detect base
            detected_base = None
            if "debian" in fname:
                detected_base = "debian"
            elif "arch" in fname:
                detected_base = "arch"

            # Detect bootloader
            detected_boot = None
            if "refind" in fname:
                detected_boot = "refind"
            elif "grub" in fname:
                detected_boot = "grub"

            if not detected_base or not detected_boot:
                print(f"  ⏭️ Skipping unclassified artifact: {entry.name}")
                continue

            target = v_node[detected_base][detected_boot]
            fsize = get_file_size(entry.path)
            fhash = sha256_file(entry.path)

            if fname.endswith(".squashfs"):
                target["squashfs"] = f"{base_url}/{entry.name}"
                target["sha256"] = fhash
                target["size_bytes"] = fsize
                print(f"  ✅ Updated {detected_base}/{detected_boot} SquashFS: {entry.name} ({fsize} bytes)")
            elif fname.endswith(".iso"):
                target["iso"] = f"{base_url}/{entry.name}"
                if not target.get("sha256"):
                    target["sha256"] = fhash
                print(f"  ✅ Updated {detected_base}/{detected_boot} ISO: {entry.name} ({fsize} bytes)")

    # 4. Write updated JSON
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"✅ Successfully wrote manifest JSON to: {manifest_path}")

    # 5. Generate static HTML site
    if args.html_dir:
        html_out = Path(args.html_dir) / "index.html"
        html_out.parent.mkdir(parents=True, exist_ok=True)
        generate_html_site(data, html_out)
        print(f"✅ Generated static GitHub/Cloudflare Pages HTML site to: {html_out}")

def generate_html_site(data: dict, out_file: Path):
    versions_count = len(data.get("versions", {}))
    html = f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Pulsar OS - Releases & Internet Recovery</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css">
  <style>
    body {{ background: #121214; color: #f4f4f5; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }}
    main {{ max-width: 900px; margin: 40px auto; padding: 20px; }}
    .card {{ background: #1c1c1f; border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 20px; margin-bottom: 20px; }}
    .badge {{ background: #0071e3; color: white; border-radius: 6px; padding: 3px 8px; font-size: 12px; font-weight: 600; }}
    pre {{ background: #09090b; padding: 12px; border-radius: 8px; font-size: 13px; max-height: 480px; overflow-y: auto; }}
    a {{ color: #0a84ff; text-decoration: none; }}
    a:hover {{ text-decoration: underline; }}
  </style>
</head>
<body>
  <main>
    <header>
      <h1>🌌 Pulsar OS — Releases & Internet Recovery</h1>
      <p>Official manifest and direct cloud recovery endpoints for Pulsar OS.</p>
      <p><strong>Latest Release:</strong> <span class="badge">{data.get("latest_version", "N/A")}</span> &nbsp;|&nbsp; <strong>Total Recorded Releases:</strong> {versions_count}</p>
    </header>
    <section class="card">
      <h3>📡 Manifest API Endpoint</h3>
      <p>The Recovery Assistant fetches available versions, distributions, bootloaders, and CDN mirrors from this JSON endpoint:</p>
      <pre><code>GET <a href="releases.json">releases.json</a></code></pre>
    </section>
    <section class="card">
      <h3>📦 Available Branches & Recovery Images</h3>
      <pre><code>{json.dumps(data.get("versions", {}), indent=2)}</code></pre>
    </section>
  </main>
</body>
</html>
"""
    with open(out_file, "w", encoding="utf-8") as f:
        f.write(html)

def main():
    parser = argparse.ArgumentParser(description="Generate Pulsar OS releases.json manifest and pages")
    parser.add_argument("--version", default="0.3-beta-bittenfruit", help="Release version tag")
    parser.add_argument("--dist-dir", help="Directory containing built ISO and SquashFS files to scan (e.g. dist/)")
    parser.add_argument("--project", default=DEFAULT_PROJECT, help="SourceForge project name")
    parser.add_argument("--output-json", default="ISO/configs/releases.json", help="Path to output releases.json")
    parser.add_argument("--html-dir", help="Directory to output static Cloudflare/GitHub Pages HTML")
    parser.add_argument("--set-latest", action="store_true", help="Set this version as latest_version")

    args = parser.parse_args()
    generate_manifest(args)

if __name__ == "__main__":
    main()
