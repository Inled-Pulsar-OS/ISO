#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Pulsar OS - Release Manifest & GitHub Pages Generator
Generates and updates hierarchical releases.json and static HTML site for Internet Recovery.
"""

import sys
import os
import argparse
import hashlib
import json
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

def generate_manifest(args):
    manifest_path = Path(args.output_json)
    data = {}
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            print(f"Warning: Could not read existing manifest: {e}")

    if "latest_version" not in data or args.set_latest:
        data["latest_version"] = args.version

    if "mirrors" not in data or not data["mirrors"]:
        data["mirrors"] = DEFAULT_MIRRORS

    if "versions" not in data:
        data["versions"] = {}

    if args.version not in data["versions"]:
        data["versions"][args.version] = {}

    v_node = data["versions"][args.version]

    base = args.base.lower()
    bootloader = args.bootloader.lower()

    if base not in v_node:
        v_node[base] = {}

    if bootloader not in v_node[base]:
        v_node[base][bootloader] = {}

    target = v_node[base][bootloader]

    # Compute filenames and hashes
    project = args.project or DEFAULT_PROJECT
    base_url = f"{DEFAULT_BASE_URL}/{project}"

    if args.squashfs_file and os.path.exists(args.squashfs_file):
        s_name = os.path.basename(args.squashfs_file)
        target["squashfs"] = f"{base_url}/{s_name}"
        target["sha256"] = sha256_file(args.squashfs_file)
        target["size_bytes"] = get_file_size(args.squashfs_file)
    elif "squashfs" not in target:
        default_squashfs = f"pulsaros-{args.version}-{base}-{bootloader}-{args.version}.squashfs"
        target["squashfs"] = f"{base_url}/{default_squashfs}"

    if args.iso_file and os.path.exists(args.iso_file):
        i_name = os.path.basename(args.iso_file)
        target["iso"] = f"{base_url}/{i_name}"
        if not target.get("sha256"):
            target["sha256"] = sha256_file(args.iso_file)
    elif "iso" not in target:
        default_iso = f"pulsaros-{args.version}-{base}-{bootloader}-{args.version}.iso"
        target["iso"] = f"{base_url}/{default_iso}"

    # Write updated JSON
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"✅ Successfully wrote manifest JSON to: {manifest_path}")

    # Optionally generate static index.html for GitHub Pages
    if args.html_dir:
        html_out = Path(args.html_dir) / "index.html"
        html_out.parent.mkdir(parents=True, exist_ok=True)
        generate_html_site(data, html_out)
        print(f"✅ Generated static GitHub Pages HTML site to: {html_out}")

def generate_html_site(data: dict, out_file: Path):
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
    pre {{ background: #09090b; padding: 12px; border-radius: 8px; font-size: 13px; }}
    a {{ color: #0a84ff; text-decoration: none; }}
    a:hover {{ text-decoration: underline; }}
  </style>
</head>
<body>
  <main>
    <header>
      <h1>🌌 Pulsar OS — Releases & Internet Recovery</h1>
      <p>Official manifest and direct cloud recovery endpoints for Pulsar OS.</p>
      <p><strong>Latest Release:</strong> <span class="badge">{data.get('latest_version', 'N/A')}</span></p>
    </header>
    <section class="card">
      <h3>📡 Manifest API Endpoint</h3>
      <p>The Recovery Assistant fetches available versions and mirrors from this JSON endpoint:</p>
      <pre><code>GET <a href="releases.json">releases.json</a></code></pre>
    </section>
    <section class="card">
      <h3>📦 Available Branches & Recovery Images</h3>
      <pre><code>{json.dumps(data.get('versions', {}), indent=2)}</code></pre>
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
    parser.add_argument("--base", default="arch", choices=["arch", "debian"], help="Base distribution")
    parser.add_argument("--bootloader", default="grub", choices=["grub", "refind"], help="Bootloader")
    parser.add_argument("--squashfs-file", help="Path to compiled .squashfs file")
    parser.add_argument("--iso-file", help="Path to compiled .iso file")
    parser.add_argument("--project", default=DEFAULT_PROJECT, help="SourceForge project name")
    parser.add_argument("--output-json", default="ISO/configs/releases.json", help="Path to output releases.json")
    parser.add_argument("--html-dir", help="Directory to output static GitHub Pages HTML")
    parser.add_argument("--set-latest", action="store_true", help="Set this version as latest_version")

    args = parser.parse_args()
    generate_manifest(args)

if __name__ == "__main__":
    main()
