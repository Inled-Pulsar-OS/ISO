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

    # 1. Load existing releases.json
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                releases_data = json.load(f)
        except Exception as e:
            print(f"Warning: Could not read local releases.json: {e}")

    if not releases_data or "versions" not in releases_data:
        template_configs = Path("ISO/configs/releases.json")
        if not template_configs.exists():
            template_configs = Path("configs/releases.json")
        if template_configs.exists():
            try:
                with open(template_configs, "r", encoding="utf-8") as f:
                    releases_data = json.load(f)
            except Exception:
                pass

    if not releases_data or "versions" not in releases_data:
        remote_data = fetch_remote_manifest("releases.json")
        if remote_data and "versions" in remote_data:
            releases_data = remote_data

    # 2. Load existing isos.json
    if isos_json_path.exists():
        try:
            with open(isos_json_path, "r", encoding="utf-8") as f:
                isos_data = json.load(f)
        except Exception:
            pass

    if not isos_data or "versions" not in isos_data:
        template_isos = Path("ISO/configs/isos.json")
        if not template_isos.exists():
            template_isos = Path("configs/isos.json")
        if template_isos.exists():
            try:
                with open(template_isos, "r", encoding="utf-8") as f:
                    isos_data = json.load(f)
            except Exception:
                pass

    if not isos_data or "versions" not in isos_data:
        remote_isos = fetch_remote_manifest("isos.json")
        if remote_isos and "versions" in remote_isos:
            isos_data = remote_isos

    # Initialize mirrors and base structures
    mirrors = releases_data.get("mirrors") or DEFAULT_MIRRORS
    version = args.version
    latest_version = version if args.set_latest else releases_data.get("latest_version", version)

    # Clean up releases_data to ensure STRICT schema (no extra top-level keys like 'isos')
    releases_clean = {
        "latest_version": latest_version,
        "mirrors": mirrors,
        "versions": {}
    }

    isos_clean = {
        "latest_version": latest_version,
        "mirrors": mirrors,
        "versions": {}
    }

    # Copy / sanitize previous versions
    for v_key, v_val in releases_data.get("versions", {}).items():
        releases_clean["versions"][v_key] = {}
        for base in ALL_BASES:
            if base in v_val:
                releases_clean["versions"][v_key][base] = {}
                for boot in ALL_BOOTLOADERS:
                    if boot in v_val[base]:
                        old_item = v_val[base][boot]
                        releases_clean["versions"][v_key][base][boot] = {
                            "squashfs": old_item.get("squashfs", ""),
                            "iso": old_item.get("iso", ""),
                            "sha256": old_item.get("sha256", ""),
                            "size_bytes": old_item.get("size_bytes", 3145728000 if base == "arch" else 2800000000)
                        }

    # Copy / sanitize isos_data versions
    for v_key, v_val in isos_data.get("versions", {}).items():
        isos_clean["versions"][v_key] = {}
        for base in ALL_BASES:
            if base in v_val:
                isos_clean["versions"][v_key][base] = {}
                for boot in ALL_BOOTLOADERS:
                    if boot in v_val[base]:
                        old_item = v_val[base][boot]
                        isos_clean["versions"][v_key][base][boot] = {
                            "iso": old_item.get("iso", ""),
                            "sha256": old_item.get("sha256", ""),
                            "size_bytes": old_item.get("size_bytes", 4800000000 if base == "arch" else 4500000000)
                        }

    project = args.project or DEFAULT_PROJECT
    base_url = f"{DEFAULT_BASE_URL}/{project}"

    # Ensure current version node exists in both
    if version not in releases_clean["versions"]:
        releases_clean["versions"][version] = {}
    if version not in isos_clean["versions"]:
        isos_clean["versions"][version] = {}

    for base in ALL_BASES:
        if base not in releases_clean["versions"][version]:
            releases_clean["versions"][version][base] = {}
        if base not in isos_clean["versions"][version]:
            isos_clean["versions"][version][base] = {}

        for boot in ALL_BOOTLOADERS:
            if boot not in releases_clean["versions"][version][base]:
                releases_clean["versions"][version][base][boot] = {
                    "squashfs": f"{base_url}/pulsaros-{version}-{base}-{boot}-{version}.squashfs",
                    "iso": f"{base_url}/pulsaros-{version}-{base}-{boot}-{version}.iso",
                    "sha256": "",
                    "size_bytes": 3145728000 if base == "arch" else 2800000000
                }
            if boot not in isos_clean["versions"][version][base]:
                # Pull iso url from releases if already available
                existing_iso_url = releases_clean["versions"][version][base][boot].get("iso") or f"{base_url}/pulsaros-{version}-{base}-{boot}-{version}.iso"
                isos_clean["versions"][version][base][boot] = {
                    "iso": existing_iso_url,
                    "sha256": "",
                    "size_bytes": 4800000000 if base == "arch" else 4500000000
                }

    # 3. Scan dist-dir artifacts to populate exact sizes and SHA-256 sums
    scanned_hashes = {}
    if args.dist_dir and os.path.exists(args.dist_dir):
        print(f"🔍 Scanning build artifacts in dist directory: {args.dist_dir}")
        for entry in os.scandir(args.dist_dir):
            if not entry.is_file():
                continue
            fname = entry.name.lower()
            if not (fname.endswith(".iso") or fname.endswith(".squashfs")):
                continue

            detected_base = None
            if "debian" in fname:
                detected_base = "debian"
            elif "arch" in fname:
                detected_base = "arch"

            detected_boot = None
            if "refind" in fname:
                detected_boot = "refind"
            elif "grub" in fname:
                detected_boot = "grub"
            elif fname.endswith(".iso") and detected_base == "arch":
                detected_boot = "grub"

            if not detected_base or not detected_boot:
                print(f"  ⏭️ Skipping unclassified artifact: {entry.name}")
                continue

            rel_target = releases_clean["versions"][version][detected_base][detected_boot]
            iso_target = isos_clean["versions"][version][detected_base][detected_boot]

            fsize = get_file_size(entry.path)
            fhash = sha256_file(entry.path)
            scanned_hashes[entry.name] = fhash

            if fname.endswith(".squashfs"):
                rel_target["squashfs"] = f"{base_url}/{entry.name}"
                rel_target["sha256"] = fhash
                rel_target["size_bytes"] = fsize
                print(f"  ✅ [SquashFS] {detected_base}/{detected_boot}: {entry.name} ({format_size(fsize)}) [SHA256: {fhash[:12]}...]")
            elif fname.endswith(".iso"):
                rel_target["iso"] = f"{base_url}/{entry.name}"
                iso_target["iso"] = f"{base_url}/{entry.name}"
                iso_target["sha256"] = fhash
                iso_target["size_bytes"] = fsize
                print(f"  ✅ [ISO] {detected_base}/{detected_boot}: {entry.name} ({format_size(fsize)}) [SHA256: {fhash[:12]}...]")

    # 4. Write releases.json (STRICT original schema)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(releases_clean, f, indent=2, ensure_ascii=False)
    print(f"✅ Successfully wrote releases.json to: {manifest_path}")

    # Synchronize default config copy of releases.json
    default_config_releases = Path("ISO/configs/releases.json")
    if manifest_path.resolve() != default_config_releases.resolve():
        default_config_releases.parent.mkdir(parents=True, exist_ok=True)
        with open(default_config_releases, "w", encoding="utf-8") as f:
            json.dump(releases_clean, f, indent=2, ensure_ascii=False)
        print(f"✅ Synced config copy to: {default_config_releases}")

    # 5. Write isos.json (Dedicated ISO manifest with identical schema)
    with open(isos_json_path, "w", encoding="utf-8") as f:
        json.dump(isos_clean, f, indent=2, ensure_ascii=False)
    print(f"✅ Successfully wrote isos.json to: {isos_json_path}")

    # Synchronize default config copy of isos.json
    default_config_isos = Path("ISO/configs/isos.json")
    if isos_json_path.resolve() != default_config_isos.resolve():
        default_config_isos.parent.mkdir(parents=True, exist_ok=True)
        with open(default_config_isos, "w", encoding="utf-8") as f:
            json.dump(isos_clean, f, indent=2, ensure_ascii=False)
        print(f"✅ Synced ISO config copy to: {default_config_isos}")

    # 6. Generate SHA256SUMS file
    if scanned_hashes:
        sha_path = manifest_path.parent / "SHA256SUMS"
        with open(sha_path, "w", encoding="utf-8") as f:
            for fname, fhash in sorted(scanned_hashes.items()):
                f.write(f"{fhash}  {fname}\n")
        print(f"✅ Generated SHA256SUMS to: {sha_path}")

        default_sha = Path("ISO/configs/SHA256SUMS")
        if sha_path.resolve() != default_sha.resolve():
            default_sha.parent.mkdir(parents=True, exist_ok=True)
            with open(default_sha, "w", encoding="utf-8") as f:
                for fname, fhash in sorted(scanned_hashes.items()):
                    f.write(f"{fhash}  {fname}\n")

    # 7. Generate static HTML site and dedicated /isos page
    if args.html_dir:
        html_dir = Path(args.html_dir)
        html_dir.mkdir(parents=True, exist_ok=True)
        
        # Main index.html
        html_out = html_dir / "index.html"
        generate_main_html(releases_clean, isos_clean, html_out)
        print(f"✅ Generated static main HTML site to: {html_out}")

        # Dedicated /isos/index.html & isos.html
        isos_dir = html_dir / "isos"
        isos_dir.mkdir(parents=True, exist_ok=True)
        generate_isos_html(isos_clean, isos_dir / "index.html")
        generate_isos_html(isos_clean, html_dir / "isos.html")
        print(f"✅ Generated dedicated ISO download page to: {isos_dir / 'index.html'} and {html_dir / 'isos.html'}")

        # Cloudflare Pages _redirects and _headers
        redirects_path = html_dir / "_redirects"
        with open(redirects_path, "w", encoding="utf-8") as f:
            f.write("/isos /isos/index.html 200\n/releases /index.html 200\n")

        headers_path = html_dir / "_headers"
        with open(headers_path, "w", encoding="utf-8") as f:
            f.write("/*\n  Access-Control-Allow-Origin: *\n")

def get_nav_html(active: str = "home") -> str:
    home_active = "active-nav" if active == "home" else ""
    isos_active = "active-nav" if active == "isos" else ""
    return f"""
    <nav class="nav-bar">
      <div class="nav-brand">🌌 <strong>Pulsar OS</strong> Releases</div>
      <div class="nav-links">
        <a href="/" class="{home_active}">Recovery & Manifest</a>
        <a href="/isos" class="{isos_active}">Descargas ISOs</a>
        <a href="/releases.json" target="_blank">releases.json</a>
        <a href="/isos.json" target="_blank">isos.json</a>
        <a href="/SHA256SUMS" target="_blank">SHA256SUMS</a>
      </div>
    </nav>
    """

def get_common_styles() -> str:
    return """
    body { background: #0c0c0e; color: #f4f4f5; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 0; }
    .nav-bar { display: flex; justify-content: space-between; align-items: center; padding: 14px 28px; background: rgba(24, 24, 27, 0.85); backdrop-filter: blur(12px); border-bottom: 1px solid rgba(255,255,255,0.1); position: sticky; top: 0; z-index: 100; }
    .nav-brand { font-size: 16px; font-weight: 600; color: #fff; }
    .nav-links { display: flex; gap: 16px; align-items: center; }
    .nav-links a { color: #a1a1aa; text-decoration: none; font-size: 14px; font-weight: 500; transition: color 0.2s; padding: 4px 10px; border-radius: 6px; }
    .nav-links a:hover { color: #fff; background: rgba(255,255,255,0.06); }
    .nav-links a.active-nav { color: #fff; background: #0071e3; }
    main { max-width: 1020px; margin: 30px auto; padding: 20px; }
    .card { background: #18181b; border: 1px solid rgba(255,255,255,0.1); border-radius: 14px; padding: 24px; margin-bottom: 24px; box-shadow: 0 4px 20px rgba(0,0,0,0.3); }
    .badge { background: #0071e3; color: white; border-radius: 6px; padding: 3px 8px; font-size: 12px; font-weight: 600; }
    .badge-arch { background: #1793d1; color: white; border-radius: 6px; padding: 3px 8px; font-size: 11px; font-weight: 700; }
    .badge-debian { background: #d70a53; color: white; border-radius: 6px; padding: 3px 8px; font-size: 11px; font-weight: 700; }
    pre { background: #09090b; padding: 14px; border-radius: 10px; font-size: 13px; max-height: 380px; overflow-y: auto; border: 1px solid rgba(255,255,255,0.06); }
    a { color: #0a84ff; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .btn-dl { display: inline-flex; align-items: center; gap: 6px; background: #0071e3; color: #fff !important; padding: 7px 16px; border-radius: 8px; font-size: 13px; font-weight: 500; text-decoration: none !important; transition: background 0.2s; }
    .btn-dl:hover { background: #0077ed; }
    table { width: 100%; border-collapse: collapse; margin-top: 12px; font-size: 13.5px; }
    th, td { padding: 12px 14px; text-align: left; border-bottom: 1px solid rgba(255,255,255,0.08); vertical-align: middle; }
    th { color: #a1a1aa; font-weight: 600; background: rgba(255,255,255,0.02); }
    .hash-code { font-size: 11.5px; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; background: #09090b; padding: 3px 6px; border-radius: 4px; word-break: break-all; color: #34d399; }
    """

def generate_main_html(releases_data: dict, isos_data: dict, out_file: Path):
    latest_ver = isos_data.get("latest_version", "N/A")
    latest_isos = isos_data.get("versions", {}).get(latest_ver, {})
    versions_count = len(isos_data.get("versions", {}))

    iso_rows = []
    for base, boots in latest_isos.items():
        base_badge = f'<span class="badge-arch">ARCH</span>' if base == "arch" else f'<span class="badge-debian">DEBIAN</span>'
        for boot, info in boots.items():
            iso_url = info.get("iso", "#")
            fname = Path(iso_url).name if iso_url else f"pulsaros-{latest_ver}-{base}-{boot}.iso"
            size_fmt = format_size(info.get("size_bytes", 0))
            hash_str = info.get("sha256", "Pending build")
            iso_rows.append(f"""
            <tr>
              <td>{base_badge} <strong>{boot.upper()}</strong></td>
              <td><code>{fname}</code></td>
              <td>{size_fmt}</td>
              <td><span class="hash-code">{hash_str}</span></td>
              <td><a href="{iso_url}" class="btn-dl" target="_blank" rel="noopener">Descargar ISO</a></td>
            </tr>
            """)

    iso_table_html = "\n".join(iso_rows) if iso_rows else "<tr><td colspan='5'>No ISOs indexed yet.</td></tr>"

    html = f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Pulsar OS — Releases, ISOs & Internet Recovery</title>
  <style>{get_common_styles()}</style>
</head>
<body>
  {get_nav_html("home")}
  <main>
    <header style="margin-bottom: 24px;">
      <h1 style="margin: 0 0 8px 0; font-size: 28px;">🌌 Pulsar OS — Releases & Internet Recovery</h1>
      <p style="color: #a1a1aa; margin: 0 0 12px 0;">Repositorio oficial de descargas, sumas de verificación y endpoints de recuperación en la nube.</p>
      <p style="margin: 0;"><strong>Última Versión:</strong> <span class="badge">{latest_ver}</span> &nbsp;|&nbsp; <strong>Versiones Indexadas:</strong> {versions_count}</p>
    </header>

    <section class="card">
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px;">
        <h2 style="margin: 0; font-size: 20px;">💿 Imágenes ISO Oficiales ({latest_ver})</h2>
        <a href="/isos" class="btn-dl" style="font-size: 12px; padding: 5px 12px;">Ver Portal /isos &rarr;</a>
      </div>
      <p style="color: #a1a1aa; font-size: 14px; margin: 0 0 14px 0;">Descarga directa de imágenes ISO de instalación con verificación de integridad SHA-256:</p>
      <div style="overflow-x: auto;">
        <table>
          <thead>
            <tr>
              <th>Edición</th>
              <th>Archivo</th>
              <th>Tamaño</th>
              <th>Firma SHA-256</th>
              <th>Acción</th>
            </tr>
          </thead>
          <tbody>
            {iso_table_html}
          </tbody>
        </table>
      </div>
    </section>

    <section class="card">
      <h2 style="margin: 0 0 10px 0; font-size: 20px;">📡 Endpoints API & Manifiestos JSON</h2>
      <p style="color: #a1a1aa; font-size: 14px; margin: 0 0 14px 0;">Los sistemas de instalación, actualización e Internet Recovery consumen los siguientes endpoints:</p>
      <ul style="line-height: 1.8; font-size: 14.5px;">
        <li><strong>Manifiesto de ISOs (Pesos y Checksums):</strong> <a href="/isos.json"><code>/isos.json</code></a></li>
        <li><strong>Manifiesto de Recuperación (SquashFS + ISO):</strong> <a href="/releases.json"><code>/releases.json</code></a></li>
        <li><strong>Sumas de Verificación:</strong> <a href="/SHA256SUMS"><code>/SHA256SUMS</code></a></li>
      </ul>
    </section>

    <section class="card">
      <h2 style="margin: 0 0 10px 0; font-size: 20px;">📦 Manifiesto de ISOs (<code>isos.json</code>)</h2>
      <pre><code>{json.dumps(isos_data, indent=2)}</code></pre>
    </section>

    <section class="card">
      <h2 style="margin: 0 0 10px 0; font-size: 20px;">📦 Manifiesto de Recuperación SquashFS (<code>releases.json</code>)</h2>
      <pre><code>{json.dumps(releases_data, indent=2)}</code></pre>
    </section>
  </main>
</body>
</html>
"""
    with open(out_file, "w", encoding="utf-8") as f:
        f.write(html)

def generate_isos_html(isos_data: dict, out_file: Path):
    latest_ver = isos_data.get("latest_version", "N/A")
    latest_isos = isos_data.get("versions", {}).get(latest_ver, {})
    mirrors = isos_data.get("mirrors", DEFAULT_MIRRORS)

    iso_cards = []
    for base, boots in latest_isos.items():
        for boot, info in boots.items():
            iso_url = info.get("iso", "#")
            fname = Path(iso_url).name if iso_url else f"pulsaros-{latest_ver}-{base}-{boot}.iso"
            size_fmt = format_size(info.get("size_bytes", 0))
            hash_str = info.get("sha256", "Pending build")
            base_title = "Arch Linux Base" if base == "arch" else "Debian Base"
            boot_desc = "Cargador GRUB (Compatible con BIOS y UEFI)" if boot == "grub" else "Cargador rEFInd (Optimizado para Apple Mac & UEFI)"
            badge_cls = "badge-arch" if base == "arch" else "badge-debian"

            iso_cards.append(f"""
            <div class="card" style="margin-bottom: 20px;">
              <div style="display: flex; justify-content: space-between; align-items: flex-start; flex-wrap: wrap; gap: 12px;">
                <div>
                  <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 6px;">
                    <span class="{badge_cls}">{base.upper()}</span>
                    <h3 style="margin: 0; font-size: 19px;">Pulsar OS {latest_ver} ({boot.upper()})</h3>
                  </div>
                  <p style="color: #a1a1aa; font-size: 13.5px; margin: 0 0 8px 0;">{base_title} &bull; {boot_desc}</p>
                </div>
                <div style="text-align: right;">
                  <span class="badge" style="font-size: 14px; padding: 4px 10px;">{size_fmt}</span>
                </div>
              </div>

              <div style="background: #09090b; border-radius: 8px; padding: 12px; margin: 14px 0; border: 1px solid rgba(255,255,255,0.06);">
                <div style="font-size: 12px; color: #a1a1aa; margin-bottom: 4px;">Archivo & Checksum SHA-256:</div>
                <div style="font-size: 13px; font-weight: 600; color: #fff; margin-bottom: 4px;">{fname}</div>
                <span class="hash-code">{hash_str}</span>
              </div>

              <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px;">
                <a href="{iso_url}" class="btn-dl" target="_blank" rel="noopener">⬇️ Descargar Imagen ISO ({size_fmt})</a>
                <span style="font-size: 12px; color: #71717a;">Direct Fast Anycast Mirror</span>
              </div>
            </div>
            """)

    cards_html = "\n".join(iso_cards) if iso_cards else "<p>No hay imágenes ISO disponibles en este momento.</p>"

    html = f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Descargas ISO — Pulsar OS</title>
  <style>{get_common_styles()}</style>
</head>
<body>
  {get_nav_html("isos")}
  <main>
    <header style="margin-bottom: 24px;">
      <h1 style="margin: 0 0 8px 0; font-size: 28px;">💿 Descargas de Imágenes ISO Oficiales</h1>
      <p style="color: #a1a1aa; margin: 0 0 12px 0;">Descarga las imágenes ISO oficiales de Pulsar OS con verificación de integridad.</p>
      <p style="margin: 0;"><strong>Versión Actual:</strong> <span class="badge">{latest_ver}</span></p>
    </header>

    {cards_html}

    <section class="card">
      <h3 style="margin: 0 0 10px 0;">🔍 Cómo verificar la integridad de tu ISO</h3>
      <p style="color: #a1a1aa; font-size: 14px;">En Linux o macOS, abre un terminal y ejecuta el siguiente comando en la carpeta de descarga:</p>
      <pre><code>sha256sum -c &lt;(grep "pulsaros-stable-arch-grub.iso" &lt;(curl -sSL https://releases.pulsaros.inled.es/SHA256SUMS))</code></pre>
      <p style="color: #a1a1aa; font-size: 13px; margin-top: 10px;">O descarga el archivo completo de sumas de verificación: <a href="/SHA256SUMS">SHA256SUMS</a>.</p>
    </section>
  </main>
</body>
</html>
"""
    with open(out_file, "w", encoding="utf-8") as f:
        f.write(html)

def main():
    parser = argparse.ArgumentParser(description="Generate Pulsar OS releases.json & isos.json manifest and pages")
    parser.add_argument("--version", default="0.4-beta-bittenfruit", help="Release version tag")
    parser.add_argument("--dist-dir", help="Directory containing built ISO and SquashFS files to scan (e.g. dist/)")
    parser.add_argument("--project", default=DEFAULT_PROJECT, help="SourceForge project name")
    parser.add_argument("--output-json", default="ISO/configs/releases.json", help="Path to output releases.json")
    parser.add_argument("--html-dir", help="Directory to output static Cloudflare/GitHub Pages HTML")
    parser.add_argument("--set-latest", action="store_true", help="Set this version as latest_version")

    args = parser.parse_args()
    generate_manifest(args)

if __name__ == "__main__":
    main()
