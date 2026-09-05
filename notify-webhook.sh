#!/usr/bin/env bash
# ==============================================================================
# Script: notify-webhook.sh
# Purpose: Sends webhook notifications (Discord, Telegram, Slack, or Generic)
#          when an ISO/squashfs upload to SourceForge finishes.
# ==============================================================================

set -euo pipefail

WEBHOOK_URL="${WEBHOOK_URL:-${DISCORD_WEBHOOK_URL:-}}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

VERSION="${1:-0.3-beta-bittenfruit}"
BASE="${2:-arch}"
BOOTLOADER="${3:-grub}"
SQUASHFS_URL="${4:-}"
ISO_URL="${5:-}"
STATUS="${6:-SUCCESS}"

if [ -z "$WEBHOOK_URL" ] && [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    echo "ℹ️ No WEBHOOK_URL or TELEGRAM_BOT_TOKEN set. Skipping webhook notification."
    exit 0
fi

TITLE="🚀 Pulsar OS Build & Upload Finished!"
DESCRIPTION="**Versión:** \`$VERSION\`\n**Base:** \`$BASE\`\n**Bootloader:** \`$BOOTLOADER\`\n**Estado:** \`$STATUS\`\n\n📥 **SquashFS (Recovery):** [Descargar]($SQUASHFS_URL)\n💿 **ISO:** [Descargar]($ISO_URL)"

# 1. Discord Webhook
if [ -n "$WEBHOOK_URL" ]; then
    echo "📢 Sending Discord Webhook notification..."
    COLOR="65280" # Green
    if [ "$STATUS" != "SUCCESS" ]; then
        COLOR="16711680" # Red
    fi

    PAYLOAD=$(cat << JSON
{
  "embeds": [
    {
      "title": "$TITLE",
      "description": "$DESCRIPTION",
      "color": $COLOR,
      "footer": {
        "text": "Pulsar OS Automated CI/CD • SourceForge & GitHub Pages"
      },
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
  ]
}
JSON
    )

    curl -s -H "Content-Type: application/json" -X POST -d "$PAYLOAD" "$WEBHOOK_URL" > /dev/null || true
    echo "✅ Discord notification sent."
fi

# 2. Telegram Notification
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    echo "📢 Sending Telegram Bot notification..."
    TG_MSG="🚀 *Pulsar OS Build & Upload Finished\!*
*Versión:* \`$VERSION\`
*Base:* \`$BASE\`
*Bootloader:* \`$BOOTLOADER\`
*Estado:* \`$STATUS\`

📥 [Descargar SquashFS (Recovery)]($SQUASHFS_URL)
💿 [Descargar ISO]($ISO_URL)"

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=MarkdownV2" \
        -d "text=${TG_MSG}" > /dev/null || true
    echo "✅ Telegram notification sent."
fi
