#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Pulsar OS - Release Manifest & Cloudflare Pages Generator
Generates and updates:
1. releases.json - Original format for SquashFS & Internet Recovery (strictly preserves schema).
2. isos.json     - Dedicated ISO manifest with identical schema listing ISO files, sizes, and SHA-256 hashes.
3. SHA256SUMS    - Checksum file for distribution verification.
4. index.html    - Static web portal.
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

def format_size(bytes_val: int) -> str:
    if bytes_val <= 0:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB"]
    i = 0
    val = float(bytes_val)
    while val >= 1024.0 and i < len(units) - 1:
        val /= 1024.0
        i += 1
    return f"{val:.2f} {units[i]}"

def fetch_remote_manifest(filename: str = "releases.json") -> dict:
    urls = [
        f"https://pulsaros-releases.pages.dev/{filename}",
        f"https://releases.pulsaros.inled.es/{filename}",
        f"https://raw.githubusercontent.com/Inled-Pulsar-OS/ISO/main/configs/{filename}"
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
    isos_json_path = manifest_path.parent / "isos.json"

    releases_data = {}
    isos_data = {}

    # 1. Load existing manifests (may contain multiple editions)
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                releases_data = json.load(f)
        except Exception:
            pass

    if not releases_data or "editions" not in releases_data:
        for src in (Path("ISO/configs/releases.json"), Path("configs/releases.json")):
            if src.exists():
                try:
                    with open(src, "r", encoding="utf-8") as f:
                        releases_data = json.load(f)
                except Exception:
                    pass
                if "editions" in releases_data:
                    break

    if not releases_data or "editions" not in releases_data:
        releases_data = {"latest_edition": "", "mirrors": DEFAULT_MIRRORS, "editions": {}}

    if isos_json_path.exists():
        try:
            with open(isos_json_path, "r", encoding="utf-8") as f:
                isos_data = json.load(f)
        except Exception:
            pass

    if not isos_data or "editions" not in isos_data:
        for src in (Path("ISO/configs/isos.json"), Path("configs/isos.json")):
            if src.exists():
                try:
                    with open(src, "r", encoding="utf-8") as f:
                        isos_data = json.load(f)
                except Exception:
                    pass
                if "editions" in isos_data:
                    break

    if not isos_data or "editions" not in isos_data:
        isos_data = {"latest_edition": "", "mirrors": DEFAULT_MIRRORS, "editions": {}}

    # Edition we are building/updating
    edition = args.edition
    ver = args.version
    full_tag = f"{ver}-{edition}"  # e.g. 0.4-beta-bittenfruit (matches SourceForge filenames)
    project = args.project or DEFAULT_PROJECT
    base_url = f"{DEFAULT_BASE_URL}/{project}"

    # Build the node for the current (edition, version)
    def build_version_node():
        node = {}
        for base in ALL_BASES:
            node[base] = {}
            for boot in ALL_BOOTLOADERS:
                node[base][boot] = {
                    "iso": f"{base_url}/pulsaros-{full_tag}-{base}-{boot}-{full_tag}.iso",
                    "squashfs": f"{base_url}/pulsaros-{full_tag}-{base}-{boot}-{full_tag}.squashfs",
                    "sha256": "",
                    "size_bytes": 3145728000 if base == "arch" else 2800000000
                }
        return node

    # Merge a version node into releases editions
    rel_ed = releases_data["editions"].setdefault(edition, {
        "id": edition,
        "name": args.edition_name or edition.title(),
        "latest_version": "",
        "versions": {}
    })
    rel_ed["versions"].setdefault(ver, build_version_node())

    # Merge into isos editions (same tree but ISO-focused)
    isos_ed = isos_data["editions"].setdefault(edition, {
        "id": edition,
        "name": args.edition_name or edition.title(),
        "latest_version": "",
        "versions": {}
    })
    isos_ed.setdefault("versions", {})
    iso_node = isos_ed["versions"].setdefault(ver, {})
    for base in ALL_BASES:
        iso_node.setdefault(base, {})
        for boot in ALL_BOOTLOADERS:
            rel_item = rel_ed["versions"][ver][base][boot]
            iso_node[base].setdefault(boot, {
                "iso": rel_item["iso"],
                "sha256": rel_item.get("sha256", ""),
                "size_bytes": rel_item.get("size_bytes", 4800000000 if base == "arch" else 4500000000)
            })

    # 2. Scan dist-dir artifacts to populate exact sizes and SHA-256 sums
    scanned_hashes = {}
    if args.dist_dir and os.path.exists(args.dist_dir):
        print(f"Scanning build artifacts in dist directory: {args.dist_dir}")
        for entry in os.scandir(args.dist_dir):
            if not entry.is_file():
                continue
            fname = entry.name.lower()
            if not (fname.endswith(".iso") or fname.endswith(".squashfs")):
                continue

            detected_base = "debian" if "debian" in fname else ("arch" if "arch" in fname else None)
            detected_boot = "refind" if "refind" in fname else ("grub" if "grub" in fname else None)
            if not detected_base or not detected_boot:
                print(f"  Skipping unclassified artifact: {entry.name}")
                continue

            fsize = get_file_size(entry.path)
            fhash = sha256_file(entry.path)
            scanned_hashes[entry.name] = fhash

            rel_item = rel_ed["versions"][ver][detected_base][detected_boot]
            iso_item = iso_node[detected_base][detected_boot]

            if fname.endswith(".squashfs"):
                rel_item["squashfs"] = f"{base_url}/{entry.name}"
                rel_item["sha256"] = fhash
                rel_item["size_bytes"] = fsize
                print(f"  [SquashFS] {detected_base}/{detected_boot}: {entry.name} ({format_size(fsize)})")
            elif fname.endswith(".iso"):
                rel_item["iso"] = f"{base_url}/{entry.name}"
                iso_item["iso"] = f"{base_url}/{entry.name}"
                iso_item["sha256"] = fhash
                iso_item["size_bytes"] = fsize
                print(f"  [ISO] {detected_base}/{detected_boot}: {entry.name} ({format_size(fsize)})")

    # 3. Set latest edition / latest version
    if args.set_latest or not releases_data.get("latest_edition"):
        releases_data["latest_edition"] = edition
        isos_data["latest_edition"] = edition
    if args.set_latest or not rel_ed.get("latest_version"):
        rel_ed["latest_version"] = ver
        isos_ed["latest_version"] = ver

    # 4. Write manifests (merge, preserving all editions)
    def write_json(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)

    write_json(manifest_path, releases_data)
    write_json(isos_json_path, isos_data)
    print(f"Successfully wrote releases.json: {manifest_path}")
    print(f"Successfully wrote isos.json: {isos_json_path}")

    # Synchronize committed config copies
    for cfg in (Path("configs"), Path("ISO/configs")):
        write_json(cfg / "releases.json", releases_data)
        write_json(cfg / "isos.json", isos_data)
    print("Synced config copies to configs/ and ISO/configs/")

    # 5. SHA256SUMS file (only regenerate from an actual dist-dir scan,
    #    which emits both .iso and .squashfs entries with the correct hashes).
    #    When just regenerating the site, the committed configs/SHA256SUMS is preserved.
    if args.dist_dir and scanned_hashes:
        sha_path = manifest_path.parent / "SHA256SUMS"
        sha_path.parent.mkdir(parents=True, exist_ok=True)
        with open(sha_path, "w", encoding="utf-8") as f:
            for fname, fhash in sorted(scanned_hashes.items()):
                f.write(f"{fhash}  {fname}\n")
        for cfg in (Path("configs"), Path("ISO/configs")):
            with open(cfg / "SHA256SUMS", "w", encoding="utf-8") as f:
                for fname, fhash in sorted(scanned_hashes.items()):
                    f.write(f"{fhash}  {fname}\n")
        print(f"Generated SHA256SUMS to: {sha_path}")

    # 6. Generate static HTML site and dedicated /isos page
    if args.html_dir:
        html_dir = Path(args.html_dir)
        html_dir.mkdir(parents=True, exist_ok=True)

        html_out = html_dir / "index.html"
        generate_main_html(releases_data, isos_data, html_out)
        print(f"Generated static main HTML site to: {html_out}")

        isos_dir = html_dir / "isos"
        isos_dir.mkdir(parents=True, exist_ok=True)
        generate_isos_html(releases_data, isos_data, isos_dir / "index.html")
        generate_isos_html(releases_data, isos_data, html_dir / "isos.html")
        print(f"Generated dedicated ISO download page to: {isos_dir / 'index.html'} and {html_dir / 'isos.html'}")

        flash_dir = html_dir / "flash"
        flash_dir.mkdir(parents=True, exist_ok=True)
        generate_flash_html(flash_dir / "index.html")
        generate_flash_html(html_dir / "flash.html")
        print(f"Generated flash guide page to: {flash_dir / 'index.html'} and {html_dir / 'flash.html'}")

        # Copy committed JSON + checksums + dino game for static hosting
        for name in ("releases.json", "isos.json", "SHA256SUMS"):
            src = Path("configs") / name
            if src.exists():
                dst = html_dir / name
                import shutil
                shutil.copyfile(src, dst)
                print(f"Copied {name} -> {html_dir / name}")

        dino_src = Path("assets/dino.html")
        if dino_src.exists():
            shutil.copyfile(dino_src, html_dir / "dino.html")
            print(f"Copied dino.html -> {html_dir / 'dino.html'}")

        # Cloudflare Pages _redirects and _headers
        with open(html_dir / "_redirects", "w", encoding="utf-8") as f:
            f.write("/isos /isos/index.html 200\n/flash /flash/index.html 200\n/releases /index.html 200\n")
        with open(html_dir / "_headers", "w", encoding="utf-8") as f:
            f.write("/*\n  Access-Control-Allow-Origin: *\n")

def get_nav_html(active: str = "home") -> str:
    home_active = "active-nav" if active == "home" else ""
    isos_active = "active-nav" if active == "isos" else ""
    return f"""
    <nav class="nav-bar">
      <div class="nav-brand"><img class="brand-logo" src="https://hosted.inled.es/cdn/pulsar-logo-simple-sf.png" alt="Pulsar OS logo"><strong>Pulsar OS</strong></div>
      <div class="nav-links">
        <a href="/" class="{home_active}">Downloads</a>
        <a href="/isos" class="{isos_active}">Recovery</a>
        <a class="nav-mono" href="/releases.json" target="_blank" rel="noopener">releases.json</a>
        <a class="nav-mono" href="/isos.json" target="_blank" rel="noopener">isos.json</a>
        <a class="nav-mono" href="/SHA256SUMS" target="_blank" rel="noopener">SHA256SUMS</a>
      </div>
    </nav>
    """

def get_common_styles() -> str:
    return """
    :root {
      --accent: #0071e3;
      --accent-hover: #0077ed;
      --text: #1d1d1f;
      --text-secondary: #6e6e73;
      --bg: #ffffff;
      --bg-secondary: #f5f5f7;
      --border: rgba(0,0,0,0.1);
      --radius: 16px;
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text); font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; -webkit-font-smoothing: antialiased; line-height: 1.5; font-feature-settings: 'liga' 1, 'calt' 1; }
    .nav-bar { display: flex; justify-content: space-between; align-items: center; padding: 12px clamp(16px, 4vw, 40px); background: rgba(251,251,253,0.82); backdrop-filter: saturate(180%) blur(20px); -webkit-backdrop-filter: saturate(180%) blur(20px); border-bottom: 1px solid var(--border); position: sticky; top: 0; z-index: 100; }
    .nav-brand { display: flex; align-items: center; gap: 9px; font-size: 16px; font-weight: 600; color: var(--text); }
    .brand-logo { width: 26px; height: 26px; object-fit: contain; }
    .nav-links { display: flex; gap: 4px; align-items: center; flex-wrap: wrap; }
    .nav-links a { color: var(--text-secondary); text-decoration: none; font-size: 14px; padding: 7px 12px; border-radius: 8px; transition: color 0.2s, background 0.2s; }
    .nav-links a:hover { color: var(--text); background: rgba(0,0,0,0.04); }
    .nav-links a.active-nav { color: var(--text); font-weight: 600; }
    .nav-links a.nav-mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; }
    main { max-width: 960px; margin: 0 auto; padding: 40px clamp(16px, 4vw, 24px) 80px; }
    .hero { text-align: center; padding: clamp(32px, 6vw, 64px) 0 40px; }
    .hero h1 { font-size: clamp(34px, 6vw, 52px); font-weight: 700; letter-spacing: -0.025em; margin: 0 0 12px; }
    .hero p { font-size: clamp(17px, 2.4vw, 21px); color: var(--text-secondary); margin: 0 auto; max-width: 620px; }
    .hero .eyebrow { display: inline-block; background: var(--bg-secondary); color: var(--text-secondary); border: 1px solid var(--border); border-radius: 999px; padding: 6px 14px; font-size: 13px; font-weight: 500; margin-bottom: 22px; }
    .section-header { display: flex; justify-content: space-between; align-items: baseline; margin: 48px 0 16px; }
    .section-header h2 { font-size: 26px; font-weight: 650; letter-spacing: -0.01em; margin: 0; }
    .section-header .sub { color: var(--text-secondary); font-size: 14px; }
    .card { background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius); padding: 26px; margin-bottom: 22px; box-shadow: 0 1px 2px rgba(0,0,0,0.05), 0 8px 24px rgba(0,0,0,0.04); }
    .edition-card { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; flex-wrap: wrap; }
    .edition-card h3 { font-size: 20px; font-weight: 650; margin: 0 0 4px; }
    .edition-card .meta { color: var(--text-secondary); font-size: 14px; }
    .dl-group { display: flex; flex-direction: column; align-items: flex-end; gap: 6px; }
    .dl-group .btn { align-self: flex-end; }
    .instructions-link { font-size: 13px; color: var(--text-secondary); text-decoration: none; transition: color 0.2s; }
    .instructions-link:hover { color: var(--accent); text-decoration: underline; }
    .chip { display: inline-block; border-radius: 999px; padding: 3px 11px; font-size: 12px; font-weight: 600; }
    .chip-arch { background: rgba(0,113,227,0.12); color: #005bbb; }
    .chip-debian { background: rgba(215,10,83,0.12); color: #b30045; }
    .chip-ver { background: var(--bg-secondary); color: var(--text-secondary); border: 1px solid var(--border); }
    .file-block { background: var(--bg-secondary); border-radius: 12px; padding: 14px 16px; margin: 16px 0; font-size: 13.5px; }
    .file-block .fname { font-weight: 600; margin-bottom: 6px; word-break: break-all; }
    .hash { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; color: var(--text-secondary); word-break: break-all; }
    .btn { display: inline-flex; align-items: center; gap: 7px; background: var(--accent); color: #fff !important; text-decoration: none !important; padding: 9px 18px; border-radius: 980px; font-size: 14px; font-weight: 500; transition: background 0.2s, transform 0.1s; }
    .btn:hover { background: var(--accent-hover); }
    .btn:active { transform: scale(0.98); }
    .dino-wrap { width: 100%; margin: 24px auto 0; border: 1px solid var(--border); border-radius: 14px; overflow: hidden; background: #fff; }
    .dino-wrap .dino-label { padding: 14px 22px 0; font-size: 13px; font-weight: 500; color: var(--text-secondary); text-transform: uppercase; letter-spacing: 0.04em; }
    .dino-wrap iframe { display: block; width: 100%; height: 260px; border: 0; }
    pre { background: var(--bg-secondary); border: 1px solid var(--border); border-radius: 12px; padding: 16px; font-size: 13px; overflow-x: auto; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .footer { text-align: center; color: var(--text-secondary); font-size: 13px; padding: 32px 0 16px; border-top: 1px solid var(--border); margin-top: 48px; }
    .verify-steps { font-size: 14px; color: var(--text-secondary); }
    ul.endpoint-list { margin: 0; list-style: none; padding: 0; font-size: 15px; display: grid; gap: 12px; }
    ul.endpoint-list .hash { font-size: 13px; }
    .verifier { display: grid; gap: 22px; }
    .v-field label { display: block; font-size: 13px; font-weight: 600; color: var(--text-secondary); margin-bottom: 8px; }
    .v-field select { width: 100%; padding: 12px 14px; border: 1px solid var(--border); border-radius: 12px; font-family: inherit; font-size: 14px; background: var(--bg); color: var(--text); appearance: none; -webkit-appearance: none; background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath fill='%236e6e73' d='M6 8.5 1.5 4h9z'/%3E%3C/svg%3E"); background-repeat: no-repeat; background-position: right 14px center; }
    .dropzone { border: 1.5px dashed var(--border); border-radius: 14px; padding: 34px 20px; text-align: center; cursor: pointer; transition: border-color 0.2s, background 0.2s; background: var(--bg-secondary); }
    .dropzone:hover, .dropzone.drag { border-color: var(--accent); background: rgba(0,113,227,0.05); }
    .dropzone .dz-title { font-size: 15px; font-weight: 600; color: var(--text); }
    .dropzone .dz-sub { font-size: 13px; color: var(--text-secondary); margin-top: 4px; }
    .dropzone input[type="file"] { display: none; }
    .v-fileinfo { display: none; align-items: center; gap: 10px; padding: 12px 16px; background: var(--bg); border: 1px solid var(--border); border-radius: 12px; font-size: 14px; }
    .v-fileinfo .fname { font-weight: 600; word-break: break-all; }
    .v-fileinfo .fsize { color: var(--text-secondary); font-size: 13px; }
    .v-fileinfo .change { margin-left: auto; color: var(--accent); background: none; border: none; cursor: pointer; font-size: 13px; font-weight: 500; }
    .v-fileinfo .change:hover { text-decoration: underline; }
    .v-progress { height: 6px; background: var(--bg-secondary); border-radius: 999px; overflow: hidden; display: none; }
    .v-progress .bar { height: 100%; width: 0; background: var(--accent); transition: width 0.2s; }
    .v-result { display: none; align-items: center; gap: 12px; padding: 16px 18px; border-radius: 12px; font-size: 15px; font-weight: 600; }
    .v-result .badge-v { font-size: 26px; line-height: 1; }
    .v-result.match { display: flex; background: rgba(52,199,89,0.12); color: #146e35; }
    .v-result.mismatch { display: flex; background: rgba(255,59,48,0.12); color: #b3002f; }
    .v-result .detail { font-weight: 400; font-size: 13.5px; color: var(--text-secondary); word-break: break-all; }
    .step-num { display: inline-flex; align-items: center; justify-content: center; width: 22px; height: 22px; border-radius: 50%; background: var(--accent); color: #fff; font-size: 12px; font-weight: 700; margin-right: 8px; vertical-align: middle; }
    .edition-switch { display: flex; flex-wrap: wrap; gap: 10px; }
    .edition-tab { padding: 10px 18px; border: 1px solid var(--border); border-radius: 999px; background: var(--bg); color: var(--text-secondary); font-family: inherit; font-size: 14px; font-weight: 500; cursor: pointer; transition: background 0.2s, color 0.2s, border-color 0.2s; }
    .edition-tab:hover { border-color: var(--text-secondary); color: var(--text); }
    .edition-tab.active-tab { background: var(--bg-secondary); border-color: var(--text-secondary); color: var(--text); }
    .edition-panel[hidden] { display: none; }
    #v-reset { background: none; border: none; color: var(--accent); font: inherit; font-size: 13px; cursor: pointer; padding: 0; }
    @media (max-width: 640px) { .nav-links .nav-mono { display: none; } }
    """

def _edition_meta(editions_root: dict) -> list:
    """Return ordered list of (id, name, version) for all editions."""
    eds = editions_root.get("editions", {})
    latest = editions_root.get("latest_edition", "")
    order = sorted(eds.keys())
    if latest in order:
        order.remove(latest)
        order.insert(0, latest)
    out = []
    for eid in order:
        ed = eds[eid]
        out.append((eid, ed.get("name") or eid.title(), ed.get("latest_version", "")))
    return out


def _render_verifier_options(editions_root: dict) -> str:
    """Render all editions' ISOs as <option> carrying data-edition for filtering."""
    opts = []
    for eid, name, ver in _edition_meta(editions_root):
        node = editions_root.get("editions", {}).get(eid, {}).get("versions", {}).get(ver, {})
        for base, boots in node.items():
            base_label = "Arch Linux" if base == "arch" else "Debian"
            for boot, info in boots.items():
                sha = info.get("sha256", "") or ""
                if not sha:
                    continue
                iso = info.get("iso", "")
                fname = Path(iso).name if iso else f"pulsaros-{ver}-{eid}-{base}-{boot}-{ver}-{eid}.iso"
                boot_label = "GRUB" if boot == "grub" else "rEFInd"
                opts.append(
                    f'<option value="{sha}" data-edition="{eid}" data-name="{fname}">{name} · {base_label} · {boot_label}</option>'
                )
    return "\n          ".join(opts)


def _render_cards(editions_root: dict, latest_edition: str) -> str:
    """Render one panel of ISO cards per edition."""
    panels = []
    for eid, name, ver in _edition_meta(editions_root):
        node = editions_root.get("editions", {}).get(eid, {}).get("versions", {}).get(ver, {})
        cards = []
        for base, boots in node.items():
            chip_cls = "chip-arch" if base == "arch" else "chip-debian"
            base_label = "Arch Linux" if base == "arch" else "Debian"
            for boot, info in boots.items():
                iso_url = info.get("iso", "#")
                fname = Path(iso_url).name if iso_url else ""
                size_fmt = format_size(info.get("size_bytes", 0))
                hash_str = info.get("sha256", "—")
                boot_label = "GRUB" if boot == "grub" else "rEFInd"
                cards.append(f"""
            <div class="card">
              <div class="edition-card">
                <div>
                  <div style="display:flex; align-items:center; gap:8px; margin-bottom:6px;">
                    <span class="chip {chip_cls}">{base_label}</span>
                    <span class="chip chip-ver">{boot_label}</span>
                  </div>
                  <h3>{name} · {ver}</h3>
                  <div class="meta">{base_label} &middot; {boot_label} boot &middot; {size_fmt}</div>
                </div>
                <div class="dl-group">
                  <a class="btn" href="{iso_url}" target="_blank" rel="noopener">Download ISO</a>
                  <a class="instructions-link" href="/flash" target="_blank" rel="noopener">How to flash this &rarr;</a>
                </div>
              </div>
              <div class="file-block">
                <div class="fname">{fname}</div>
                <div class="hash">SHA-256 &nbsp;{hash_str}</div>
              </div>
            </div>""")
        panels.append(f"""
      <div class="edition-panel" data-edition="{eid}"{'' if eid == latest_edition else ' hidden'}>
        {''.join(cards) if cards else '<p class="verify-steps" style="margin:0;">No ISO images available for this edition yet.</p>'}
      </div>""")
    return "\n".join(panels)


def _render_recovery_cards(editions_root: dict, latest_edition: str) -> str:
    """Render one panel of SquashFS recovery cards per edition."""
    panels = []
    for eid, name, ver in _edition_meta(editions_root):
        node = editions_root.get("editions", {}).get(eid, {}).get("versions", {}).get(ver, {})
        cards = []
        for base, boots in node.items():
            chip_cls = "chip-arch" if base == "arch" else "chip-debian"
            base_label = "Arch Linux" if base == "arch" else "Debian"
            for boot, info in boots.items():
                squashfs_url = info.get("squashfs", "")
                if not squashfs_url:
                    continue
                fname = Path(squashfs_url).name if squashfs_url else ""
                size_fmt = format_size(info.get("size_bytes", 0))
                hash_str = info.get("sha256", "—")
                boot_label = "GRUB" if boot == "grub" else "rEFInd"
                cards.append(f"""
            <div class="card">
              <div class="edition-card">
                <div>
                  <div style="display:flex; align-items:center; gap:8px; margin-bottom:6px;">
                    <span class="chip {chip_cls}">{base_label}</span>
                    <span class="chip chip-ver">{boot_label}</span>
                  </div>
                  <h3>{name} · {ver}</h3>
                  <div class="meta">{base_label} &middot; {boot_label} boot &middot; {size_fmt}</div>
                </div>
                <div class="dl-group">
                  <a class="btn" href="{squashfs_url}" target="_blank" rel="noopener">Download Recovery</a>
                  <a class="instructions-link" href="/flash" target="_blank" rel="noopener">How to flash this &rarr;</a>
                </div>
              </div>
              <div class="file-block">
                <div class="fname">{fname}</div>
                <div class="hash">SHA-256 &nbsp;{hash_str}</div>
              </div>
            </div>""")
        panels.append(f"""
      <div class="edition-panel" data-edition="{eid}"{'' if eid == latest_edition else ' hidden'}>
        {''.join(cards) if cards else '<p class="verify-steps" style="margin:0;">No recovery images available for this edition yet.</p>'}
      </div>""")
    return "\n".join(panels)


def _edition_tabs(editions_root: dict, latest_edition: str) -> str:
    tabs = []
    for eid, name, ver in _edition_meta(editions_root):
        active = " active-tab" if eid == latest_edition else ""
        tabs.append(f'<button type="button" class="edition-tab{active}" data-edition="{eid}">{name}</button>')
    return "\n          ".join(tabs)


def _edition_json(editions_root: dict) -> str:
    """Emit a tiny JSON with latest_edition + edition ids for JS."""
    data = {
        "latest": editions_root.get("latest_edition", ""),
        "editions": [{"id": eid, "name": name, "version": ver} for eid, name, ver in _edition_meta(editions_root)],
    }
    return json.dumps(data, ensure_ascii=False)


def _render_recovery_verifier_options(editions_root: dict) -> str:
    """Render all editions' SquashFS images as <option> for the recovery verifier."""
    opts = []
    for eid, name, ver in _edition_meta(editions_root):
        node = editions_root.get("editions", {}).get(eid, {}).get("versions", {}).get(ver, {})
        for base, boots in node.items():
            base_label = "Arch Linux" if base == "arch" else "Debian"
            for boot, info in boots.items():
                sha = info.get("sha256", "") or ""
                squashfs = info.get("squashfs", "")
                if not sha or not squashfs:
                    continue
                fname = Path(squashfs).name if squashfs else f"pulsaros-{ver}-{eid}-{base}-{boot}-{ver}-{eid}.squashfs"
                boot_label = "GRUB" if boot == "grub" else "rEFInd"
                opts.append(
                    f'<option value="{sha}" data-edition="{eid}" data-name="{fname}">{name} · {base_label} · {boot_label} · Recovery</option>'
                )
    return "\n          ".join(opts)


def _render_merged_verifier_options(editions_root: dict, releases_root: dict) -> str:
    """Render both ISO and SquashFS hashes in one <select> for the unified verifier."""
    seen = set()
    opts = []
    for eid, name, ver in _edition_meta(editions_root):
        # ISO options from isos_data
        iso_node = editions_root.get("editions", {}).get(eid, {}).get("versions", {}).get(ver, {})
        for base, boots in iso_node.items():
            base_label = "Arch Linux" if base == "arch" else "Debian"
            for boot, info in boots.items():
                sha = info.get("sha256", "") or ""
                iso = info.get("iso", "")
                if not sha or not iso:
                    continue
                fname = Path(iso).name if iso else ""
                boot_label = "GRUB" if boot == "grub" else "rEFInd"
                key = f"{eid}-{base}-{boot}-iso"
                if key not in seen:
                    seen.add(key)
                    opts.append(
                        f'<option value="{sha}" data-edition="{eid}" data-name="{fname}">{name} · {base_label} · {boot_label} · ISO</option>'
                    )
        # SquashFS options from releases_data
        rel_node = releases_root.get("editions", {}).get(eid, {}).get("versions", {}).get(ver, {})
        for base, boots in rel_node.items():
            base_label = "Arch Linux" if base == "arch" else "Debian"
            for boot, info in boots.items():
                sha = info.get("sha256", "") or ""
                squashfs = info.get("squashfs", "")
                if not sha or not squashfs:
                    continue
                fname = Path(squashfs).name if squashfs else ""
                boot_label = "GRUB" if boot == "grub" else "rEFInd"
                key = f"{eid}-{base}-{boot}-squashfs"
                if key not in seen:
                    seen.add(key)
                    opts.append(
                        f'<option value="{sha}" data-edition="{eid}" data-name="{fname}">{name} · {base_label} · {boot_label} · Recovery</option>'
                    )
    return "\n          ".join(opts)


def get_verifier_html(editions_root: dict, latest_edition: str, releases_root: dict = None) -> str:
    heading = "Check that your file isn't corrupted"
    lead = "This only takes a moment and it all happens in your browser — your file is never uploaded anywhere."
    step1 = "Choose the edition and image you downloaded"
    step2 = "Select the file from your downloads"
    tabs = _edition_tabs(editions_root, latest_edition)
    if releases_root:
        options = _render_merged_verifier_options(editions_root, releases_root)
    else:
        options = _render_verifier_options(editions_root)
    options_meta = _edition_json(editions_root)

    return f"""
    <div class="card">
      <h2 style="font-size:22px; margin:0 0 4px;">{heading}</h2>
      <p class="verify-steps" style="margin:0 0 16px; color:var(--text-secondary);">{lead}</p>
      <div class="edition-switch" id="v-editions">
        {tabs}
      </div>
      <div class="verifier">
        <div class="v-field">
          <label for="v-select"><span class="step-num">1</span> {step1}</label>
          <select id="v-select" data-editions='{options_meta}'>
            {options}
          </select>
        </div>
        <div>
          <div class="v-field"><label><span class="step-num">2</span> {step2}</label></div>
          <div class="dropzone" id="v-drop">
            <div class="dz-title">Click here and choose your downloaded file</div>
            <div class="dz-sub">You can also drag and drop the file onto this box.</div>
            <input type="file" id="v-file">
          </div>
          <div class="v-fileinfo" id="v-fileinfo" style="margin-top:10px;">
            <div>
              <div class="fname" id="v-fname"></div>
              <div class="fsize" id="v-fsize"></div>
            </div>
            <button class="change" id="v-change" type="button">Change</button>
          </div>
        </div>
        <div class="v-progress" id="v-progress"><div class="bar" id="v-bar"></div></div>
        <div class="v-result" id="v-result">
          <span class="badge-v" id="v-icon"></span>
          <div>
            <div class="v-result-title" id="v-title"></div>
            <div class="detail" id="v-detail"></div>
          </div>
        </div>
      </div>
    </div>
    """


def get_page_script() -> str:
    """Shared JS: edition switching + incremental SHA-256 verification."""
    return """
    (function () {
      // Edition tabs (outside the verifier)
      var tabs = document.querySelectorAll('.edition-tab');
      var panels = document.querySelectorAll('.edition-panel');
      function setEdition(eid, fromVerifier) {
        tabs.forEach(function (t) { t.classList.toggle('active-tab', t.dataset.edition === eid); });
        panels.forEach(function (p) { p.hidden = p.dataset.edition !== eid; });
        if (fromVerifier !== true) syncVerifier(eid);
      }
      tabs.forEach(function (t) {
        t.addEventListener('click', function () { setEdition(t.dataset.edition, false); });
      });

      // Verifier
      var drop = document.getElementById('v-drop');
      var fileInput = document.getElementById('v-file');
      var sel = document.getElementById('v-select');
      var prog = document.getElementById('v-progress');
      var bar = document.getElementById('v-bar');
      var res = document.getElementById('v-result');
      var icon = document.getElementById('v-icon');
      var title = document.getElementById('v-title');
      var detail = document.getElementById('v-detail');
      var fileinfo = document.getElementById('v-fileinfo');
      var fname = document.getElementById('v-fname');
      var fsize = document.getElementById('v-fsize');
      var changeBtn = document.getElementById('v-change');
      var verifierTabs = document.getElementById('v-editions');

      function activeEdition() {
        var activeTab = document.querySelector('.edition-tab.active-tab');
        return activeTab ? activeTab.dataset.edition : (sel.dataset.editions ? JSON.parse(sel.dataset.editions).latest : '');
      }
      function syncVerifier(eid) {
        var opts = sel.querySelectorAll('option[data-edition]');
        var firstFor = null;
        opts.forEach(function (o) {
          var match = o.dataset.edition === eid;
          o.hidden = !match;
          if (match && !firstFor) firstFor = o;
        });
        if (firstFor) { sel.value = firstFor.value; }
        expected = buildExpected();
      }
      function buildExpected() {
        var m = {};
        sel.querySelectorAll('option[data-edition]:not([hidden])').forEach(function (o) {
          m[o.value] = o.getAttribute('data-name');
        });
        return m;
      }
      var expected = buildExpected();
      if (verifierTabs) {
        verifierTabs.querySelectorAll('.edition-tab').forEach(function (t) {
          t.addEventListener('click', function () {
            setEdition(t.dataset.edition, true);
            var p = sel.closest('.card');
            if (p) p.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
          });
        });
      }

      var busy = false;
      function pick() {
        if (busy) return;
        prog.style.display = 'none';
        fileinfo.style.display = 'none';
        res.className = 'v-result';
        fileInput.value = '';
        fileInput.click();
      }
      drop.addEventListener('click', function () { pick(); });
      changeBtn.addEventListener('click', function () { pick(); });
      drop.addEventListener('dragover', function (e) { e.preventDefault(); drop.classList.add('drag'); });
      drop.addEventListener('dragleave', function () { drop.classList.remove('drag'); });
      drop.addEventListener('drop', function (e) {
        e.preventDefault();
        drop.classList.remove('drag');
        if (!busy && e.dataTransfer.files.length) handleFile(e.dataTransfer.files[0]);
      });
      fileInput.addEventListener('change', function () {
        if (fileInput.files.length) handleFile(fileInput.files[0]);
      });

      function fmtSize(n) {
        if (n < 1024) return n + ' B';
        var u = ['KB', 'MB', 'GB', 'TB'], i = -1;
        do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
        return n.toFixed(2) + ' ' + u[i];
      }

      var K = new Uint32Array([
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
      ]);
      function Sha256() {
        this.h = new Uint32Array([0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]);
        this.buf = new Uint8Array(64);
        this.buflen = 0;
        this.len = 0;
      }
      function rotr(x, n) { return (x >>> n) | (x << (32 - n)); }
      Sha256.prototype.process = function (block) {
        var w = new Uint32Array(64), i;
        for (i = 0; i < 16; i++) w[i] = (block[i*4]<<24) | (block[i*4+1]<<16) | (block[i*4+2]<<8) | block[i*4+3];
        for (i = 16; i < 64; i++) {
          var s0 = rotr(w[i-15],7) ^ rotr(w[i-15],18) ^ (w[i-15]>>>3);
          var s1 = rotr(w[i-2],17) ^ rotr(w[i-2],19) ^ (w[i-2]>>>10);
          w[i] = (w[i-16] + s0 + w[i-7] + s1) | 0;
        }
        var a=this.h[0],b=this.h[1],c=this.h[2],d=this.h[3],e=this.h[4],f=this.h[5],g=this.h[6],h=this.h[7];
        for (i = 0; i < 64; i++) {
          var S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25);
          var ch = (e & f) ^ (~e & g);
          var t1 = (h + S1 + ch + K[i] + w[i]) | 0;
          var S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22);
          var maj = (a & b) ^ (a & c) ^ (b & c);
          var t2 = (S0 + maj) | 0;
          h=g; g=f; f=e; e=(d+t1)|0; d=c; c=b; b=a; a=(t1+t2)|0;
        }
        this.h[0]=(this.h[0]+a)|0; this.h[1]=(this.h[1]+b)|0; this.h[2]=(this.h[2]+c)|0; this.h[3]=(this.h[3]+d)|0;
        this.h[4]=(this.h[4]+e)|0; this.h[5]=(this.h[5]+f)|0; this.h[6]=(this.h[6]+g)|0; this.h[7]=(this.h[7]+h)|0;
      };
      Sha256.prototype.update = function (data) {
        this.len += data.length;
        var i = 0;
        if (this.buflen) {
          var need = 64 - this.buflen;
          var take = Math.min(need, data.length);
          this.buf.set(data.subarray(0, take), this.buflen);
          this.buflen += take;
          i = take;
          if (this.buflen === 64) { this.process(this.buf); this.buflen = 0; }
        }
        while (i + 64 <= data.length) { this.process(data.subarray(i, i + 64)); i += 64; }
        if (i < data.length) { this.buf.set(data.subarray(i), 0); this.buflen = data.length - i; }
      };
      Sha256.prototype.digest = function () {
        var bitLenHi = Math.floor(this.len / 0x20000000);
        var bitLenLo = (this.len << 3) >>> 0;
        var k = 55 - this.buflen; if (k < 0) k += 64;
        var out = new Uint8Array(this.buflen + 1 + k + 8);
        out.set(this.buf.subarray(0, this.buflen), 0);
        out[this.buflen] = 0x80;
        var dv = new DataView(out.buffer);
        dv.setUint32(out.length - 8, bitLenHi);
        dv.setUint32(out.length - 4, bitLenLo);
        for (var pos = 0; pos < out.length; pos += 64) this.process(out.subarray(pos, pos + 64));
        var hex = '';
        for (var j = 0; j < 8; j++) hex += ('00000000' + this.h[j].toString(16)).slice(-8);
        return hex;
      };

      function handleFile(file) {
        if (busy) return;
        busy = true;
        res.className = 'v-result';
        bar.style.width = '0%';
        prog.style.display = 'block';
        fileinfo.style.display = 'flex';
        fname.textContent = file.name;
        fsize.textContent = fmtSize(file.size);

        var chunkSize = 16 * 1024 * 1024;
        var offset = 0;
        var total = file.size;
        var h = new Sha256();

        function readNext() {
          if (offset >= total) {
            prog.style.display = 'none';
            busy = false;
            finish(h.digest(), file);
            return;
          }
          var next = Math.min(offset + chunkSize, total);
          var fr = new FileReader();
          fr.onload = function () {
            try { h.update(new Uint8Array(fr.result)); }
            catch (err) { fail(err); return; }
            offset = next;
            bar.style.width = Math.round(offset / total * 100) + '%';
            setTimeout(readNext, 0);
          };
          fr.onerror = function () { fail(fr.error); };
          fr.readAsArrayBuffer(file.slice(offset, next));
        }
        readNext();
      }

      function fail(err) {
        busy = false;
        prog.style.display = 'none';
        res.className = 'v-result mismatch';
        icon.textContent = '✕';
        title.textContent = 'Could not verify file';
        detail.textContent = String(err && err.message ? err.message : err);
      }

      function finish(computed, file) {
        prog.style.display = 'none';
        var want = sel.value;
        var wantName = expected[want] || file.name;
        if (computed === want) {
          res.className = 'v-result match';
          icon.textContent = '✓';
          title.textContent = 'Checksum matched';
          detail.textContent = file.name + ' is authentic and matches the official checksum (' + wantName + ').';
        } else {
          res.className = 'v-result mismatch';
          icon.textContent = '✕';
          title.textContent = 'Checksum mismatch';
          detail.textContent = 'The file differs from what we publish. Try downloading it again — it may have been corrupted during transfer.';
        }
        res.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      }

      syncVerifier(activeEdition() || (sel.dataset.editions ? JSON.parse(sel.dataset.editions).latest : ''));

    })();
    """


def _page_head(title: str, active: str, editions_root: dict, latest_edition: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{title}</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>{get_common_styles()}</style>
</head>
<body>
  {get_nav_html(active)}
  <main>
"""


def generate_main_html(releases_data: dict, isos_data: dict, out_file: Path):
    latest_edition = isos_data.get("latest_edition", "")
    latest_isos = isos_data.get("editions", {}).get(latest_edition, {})
    latest_ver = latest_isos.get("latest_version", "N/A")

    cards_html = _render_cards(isos_data, latest_edition)
    tabs_html = _edition_tabs(isos_data, latest_edition)
    editions_count = len(isos_data.get("editions", {}))

    html = _page_head("Pulsar OS — Downloads", "home", isos_data, latest_edition)
    html += f"""
    <div class="hero">
      <div class="eyebrow">Pulsar OS · {latest_ver}</div>
      <h1>Pulsar OS, ready to download.</h1>
      <p>Pick an edition and the image that fits your computer, hit Download, and verify the file once it arrives.</p>
    </div>

    <div class="section-header">
      <h2>Choose an edition</h2>
      <span class="sub">{editions_count} editions available</span>
    </div>
    <div class="edition-switch">{tabs_html}</div>

    <div class="section-header" style="margin-top:28px;">
      <h2>Choose and download</h2>
    </div>
    {cards_html}

    <div class="dino-wrap">
      <div class="dino-label">Play while you wait</div>
      <iframe src="/dino.html" title="Chrome Dino game — press space to start" loading="lazy"></iframe>
    </div>

    <div class="section-header" style="margin-top:24px;">
      <h2>Always check your download</h2>
    </div>
    <p class="verify-steps" style="margin-top:0;">Once your download finishes, use the check below to make sure the file is intact — it's quick and private, right here in your browser.</p>
    {get_verifier_html(isos_data, latest_edition, releases_root=releases_data)}
  </main>
  <div class="footer">Pulsar OS &middot; Downloads and recovery</div>
"""
    html += f"""
  <script>{get_page_script()}</script>
</body>
</html>
"""
    with open(out_file, "w", encoding="utf-8") as f:
        f.write(html)


def generate_isos_html(releases_data: dict, isos_data: dict, out_file: Path):
    latest_edition = releases_data.get("latest_edition", "")
    latest_releases = releases_data.get("editions", {}).get(latest_edition, {})
    latest_ver = latest_releases.get("latest_version", "N/A")

    cards_html = _render_recovery_cards(releases_data, latest_edition)
    tabs_html = _edition_tabs(releases_data, latest_edition)

    html = _page_head("Recovery — Pulsar OS", "isos", releases_data, latest_edition)
    html += f"""
    <div class="hero">
      <div class="eyebrow">Internet Recovery</div>
      <h1>Recover your system.</h1>
      <p>Recovery images you can boot over the network to restore Pulsar OS. Download one and verify it once it arrives.</p>
    </div>

    <div class="section-header">
      <h2>Choose an edition</h2>
    </div>
    <div class="edition-switch">{tabs_html}</div>

    <div class="section-header" style="margin-top:28px;">
      <h2>Recovery images</h2>
    </div>
    {cards_html}

    <div class="dino-wrap">
      <div class="dino-label">Play while you wait</div>
      <iframe src="/dino.html" title="Chrome Dino game — press space to start" loading="lazy"></iframe>
    </div>

    <div class="section-header" style="margin-top:24px;"><h2>Always check your download</h2></div>
    {get_verifier_html(releases_data, latest_edition, releases_root=releases_data)}
  </main>
  <div class="footer">Pulsar OS &middot; Downloads and recovery</div>
"""
    html += f"""
  <script>{get_page_script()}</script>
</body>
</html>
"""
    with open(out_file, "w", encoding="utf-8") as f:
        f.write(html)


def generate_flash_html(out_file: Path):
    html = _page_head("How to Flash — Pulsar OS", "flash", {}, "")
    html += """
    <style>
      .flash-step { display: flex; gap: 16px; margin-bottom: 18px; align-items: flex-start; }
      .flash-step .step-circle { flex-shrink: 0; width: 32px; height: 32px; border-radius: 50%; background: var(--accent); color: #fff; display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 15px; }
      .flash-step .step-body { flex: 1; }
      .flash-step .step-body h4 { margin: 0 0 4px; font-size: 16px; font-weight: 600; }
      .flash-step .step-body p { margin: 0; color: var(--text-secondary); font-size: 14px; line-height: 1.6; }
      .os-card { background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius); padding: 28px; margin-bottom: 20px; }
      .os-card h3 { font-size: 20px; font-weight: 650; margin: 0 0 4px; display: flex; align-items: center; gap: 10px; }
      .os-card .os-tag { font-size: 12px; font-weight: 600; border-radius: 999px; padding: 3px 10px; }
      .os-card .os-tag.win { background: rgba(0,120,212,0.12); color: #0078d4; }
      .os-card .os-tag.linux { background: rgba(255,152,0,0.12); color: #e65100; }
      .os-card .os-tag.mac { background: rgba(0,0,0,0.08); color: var(--text); }
      .os-card .os-desc { color: var(--text-secondary); font-size: 14px; margin: 0 0 16px; }
      .os-card .app-name { font-weight: 600; color: var(--text); }
      .tip-box { background: var(--bg-secondary); border: 1px solid var(--border); border-radius: 12px; padding: 18px 20px; margin: 20px 0; }
      .tip-box .tip-title { font-weight: 600; font-size: 14px; margin-bottom: 6px; }
      .tip-box p { margin: 0; font-size: 14px; color: var(--text-secondary); line-height: 1.6; }
      .ai-box { background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius); padding: 28px; margin-top: 32px; }
      .ai-box h3 { font-size: 20px; font-weight: 650; margin: 0 0 6px; }
      .ai-box .ai-desc { color: var(--text-secondary); font-size: 14px; margin: 0 0 16px; }
      .ai-input-wrap { display: flex; gap: 10px; }
      .ai-input-wrap input { flex: 1; padding: 12px 16px; border: 1px solid var(--border); border-radius: 12px; font-family: inherit; font-size: 14px; background: var(--bg); color: var(--text); outline: none; transition: border-color 0.2s; }
      .ai-input-wrap input:focus { border-color: var(--accent); }
      .ai-input-wrap .ai-btn { background: var(--accent); color: #fff; border: none; border-radius: 12px; padding: 12px 22px; font-family: inherit; font-size: 14px; font-weight: 600; cursor: pointer; white-space: nowrap; transition: background 0.2s; }
      .ai-input-wrap .ai-btn:hover { background: var(--accent-hover); }
      .ai-hint { font-size: 12px; color: var(--text-secondary); margin-top: 8px; }
    </style>

    <div class="hero">
      <div class="eyebrow">Getting started</div>
      <h1>How to flash and boot Pulsar OS.</h1>
      <p>Everything you need to put Pulsar OS on a USB drive and start using it — no technical knowledge required.</p>
    </div>

    <div class="section-header">
      <h2>What you need</h2>
    </div>
    <div class="tip-box">
      <div class="tip-title">Before you begin</div>
      <p>A USB drive of <strong>at least 8 GB</strong> (the contents will be erased), the Pulsar OS file you downloaded, and one of the apps below depending on your operating system.</p>
    </div>

    <div class="section-header" style="margin-top:32px;">
      <h2>Pick your operating system</h2>
    </div>

    <div class="os-card">
      <h3><span class="os-tag win">Windows</span> Rufus</h3>
      <p class="os-desc"><span class="app-name">Rufus</span> is a free, lightweight app for Windows that creates bootable USB drives in a few clicks.</p>
      <div class="flash-step">
        <div class="step-circle">1</div>
        <div class="step-body">
          <h4>Download and open Rufus</h4>
          <p>Get it from <a href="https://rufus.ie" target="_blank" rel="noopener">rufus.ie</a> — no installation needed, just run the file.</p>
        </div>
      </div>
      <div class="flash-step">
        <div class="step-circle">2</div>
        <div class="step-body">
          <h4>Plug in your USB drive</h4>
          <p>Rufus will detect it automatically. Make sure the right device is selected under "Device".</p>
        </div>
      </div>
      <div class="flash-step">
        <div class="step-circle">3</div>
        <div class="step-body">
          <h4>Select your Pulsar OS file</h4>
          <p>Click "SELECT" and find the ISO or recovery file you downloaded.</p>
        </div>
      </div>
      <div class="flash-step">
        <div class="step-circle">4</div>
        <div class="step-body">
          <h4>Start flashing</h4>
          <p>Leave all other settings as they are and click "START". Wait for it to finish — this may take a few minutes.</p>
        </div>
      </div>
    </div>

    <div class="os-card">
      <h3><span class="os-tag linux">Linux</span> GNOME Disks</h3>
      <p class="os-desc"><span class="app-name">GNOME Disks</span> comes pre-installed on most Linux distributions with a graphical desktop.</p>
      <div class="flash-step">
        <div class="step-circle">1</div>
        <div class="step-body">
          <h4>Open GNOME Disks</h4>
          <p>Search for "Disks" in your app launcher, or type <code>gnome-disks</code> in a terminal.</p>
        </div>
      </div>
      <div class="flash-step">
        <div class="step-circle">2</div>
        <div class="step-body">
          <h4>Select your USB drive</h4>
          <p>Click on the USB drive in the left sidebar. Be careful to pick the right one.</p>
        </div>
      </div>
      <div class="flash-step">
        <div class="step-circle">3</div>
        <div class="step-body">
          <h4>Restore the image</h4>
          <p>Click the menu button (three dots) in the top-right corner and choose "Restore Disk Image…". Select your Pulsar OS file and confirm.</p>
        </div>
      </div>
      <div class="flash-step">
        <div class="step-circle">4</div>
        <div class="step-body">
          <h4>Wait for it to finish</h4>
          <p>The process takes a few minutes. Once done, safely eject the USB drive.</p>
        </div>
      </div>
    </div>

    <div class="os-card">
      <h3><span class="os-tag mac">macOS</span> balenaEtcher</h3>
      <p class="os-desc"><span class="app-name">balenaEtcher</span> is a free app for macOS that makes flashing USB drives simple and safe.</p>
      <div class="flash-step">
        <div class="step-circle">1</div>
        <div class="step-body">
          <h4>Download and open balenaEtcher</h4>
          <p>Get it from <a href="https://etcher.balena.io" target="_blank" rel="noopener">etcher.balena.io</a>. On macOS you may need to right-click → Open the first time to bypass Gatekeeper.</p>
        </div>
      </div>
      <div class="flash-step">
        <div class="step-circle">2</div>
        <div class="step-body">
          <h4>Select your Pulsar OS file</h4>
          <p>Click "Flash from file" and choose the ISO or recovery file you downloaded.</p>
        </div>
      </div>
      <div class="flash-step">
        <div class="step-circle">3</div>
        <div class="step-body">
          <h4>Pick your USB drive</h4>
          <p>Click "Select target" and choose your USB drive. Confirm the selection.</p>
        </div>
      </div>
      <div class="flash-step">
        <div class="step-circle">4</div>
        <div class="step-body">
          <h4>Flash!</h4>
          <p>Click "Flash!" and wait. You may be asked for your Mac password. Once done, close the app and eject the USB.</p>
        </div>
      </div>
    </div>

    <div class="section-header" style="margin-top:40px;">
      <h2>Boot from the USB</h2>
    </div>
    <p style="color:var(--text-secondary); font-size:15px; margin-top:0;">Now that your USB is ready, here's how to start your computer from it.</p>

    <div class="flash-step">
      <div class="step-circle">1</div>
      <div class="step-body">
        <h4>Plug in the USB drive</h4>
        <p>Keep it plugged in and restart your computer.</p>
      </div>
    </div>
    <div class="flash-step">
      <div class="step-circle">2</div>
      <div class="step-body">
        <h4>Open the boot menu</h4>
        <p>As soon as your computer starts (before the operating system loads), press the key that opens the boot menu. This is usually <strong>F12</strong>, <strong>F2</strong>, <strong>Esc</strong>, or <strong>F10</strong> — it depends on your computer brand. See the section below to find the right key for your model.</p>
      </div>
    </div>
    <div class="flash-step">
      <div class="step-circle">3</div>
      <div class="step-body">
        <h4>Select your USB drive</h4>
        <p>In the boot menu, use the arrow keys to highlight your USB drive and press Enter. It may appear as the brand name of your USB (like "SanDisk" or "Kingston") or as "USB HDD".</p>
      </div>
    </div>
    <div class="flash-step">
      <div class="step-circle">4</div>
      <div class="step-body">
        <h4>Start Pulsar OS in live mode</h4>
        <p>Pulsar OS will load from the USB. You'll see a welcome screen — choose "Try Pulsar OS" or "Live mode" to explore without changing anything on your computer. If you like it, you can install it later from within the live session.</p>
      </div>
    </div>

    <div class="tip-box">
      <div class="tip-title">What is live mode?</div>
      <p>Live mode lets you run Pulsar OS directly from the USB drive without installing anything. Your files and settings stay on the USB, and your computer's hard drive is not touched. It's a safe way to try Pulsar OS before deciding.</p>
    </div>

    <div class="ai-box">
      <h3>Find your boot menu key</h3>
      <p class="ai-desc">Not sure which key to press? Type your computer model below and we'll look it up for you.</p>
      <div class="ai-input-wrap">
        <input type="text" id="boot-model-input" placeholder="e.g. Dell Inspiron 15, Lenovo ThinkPad X1, HP Pavilion...">
        <button class="ai-btn" id="boot-lookup-btn" type="button">Look it up</button>
      </div>
      <p class="ai-hint">Opens a Google search with the answer for your specific model.</p>
    </div>

  </main>
  <div class="footer">Pulsar OS &middot; Downloads and recovery</div>
"""
    html += """
  <script>
    (function () {
      var input = document.getElementById('boot-model-input');
      var btn = document.getElementById('boot-lookup-btn');
      function lookup() {
        var model = (input.value || '').trim();
        if (!model) { input.focus(); return; }
        var q = encodeURIComponent('how to access boot menu on ' + model + ' step by step');
        window.open('https://www.google.com/search?q=' + q, '_blank');
      }
      btn.addEventListener('click', lookup);
      input.addEventListener('keydown', function (e) { if (e.key === 'Enter') lookup(); });
    })();
  </script>
</body>
</html>
"""
    with open(out_file, "w", encoding="utf-8") as f:
        f.write(html)


def main():
    parser = argparse.ArgumentParser(description="Generate Pulsar OS releases.json & isos.json manifest and pages")
    parser.add_argument("--version", default="0.4-beta", help="Release version tag (short, without edition suffix)")
    parser.add_argument("--edition", default="bittenfruit", help="Edition id (e.g. bittenfruit, tube-os, wintux)")
    parser.add_argument("--edition-name", default="", help="Display name for the edition (defaults to title-cased id)")
    parser.add_argument("--dist-dir", help="Directory containing built ISO and SquashFS files to scan (e.g. dist/)")
    parser.add_argument("--project", default=DEFAULT_PROJECT, help="SourceForge project name")
    parser.add_argument("--output-json", default="ISO/configs/releases.json", help="Path to output releases.json")
    parser.add_argument("--html-dir", help="Directory to output static Cloudflare/GitHub Pages HTML")
    parser.add_argument("--set-latest", action="store_true", help="Set this edition and version as latest")

    args = parser.parse_args()
    generate_manifest(args)

if __name__ == "__main__":
    main()
