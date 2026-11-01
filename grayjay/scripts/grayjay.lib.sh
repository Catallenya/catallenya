#!/bin/bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared settings for the grayjay pipeline. Sourced by grayjay.archive.sh — not
# executable on its own.
#
# WHAT THIS IS. Grayjay (the phone's YouTube client) writes an automatic backup into the
# synced `master/config` folder every couple of days. Once a day this job reads the two
# allow-listed playlists out of it and hands every video it has not seen before to the
# existing ArchiveBox, tagged with the playlist's name, so a copy survives the video
# disappearing from YouTube. Full design and the decisions behind it: grayjay/README.md.
#
# NO MODEL AND NO BUTTONS. Nothing here is a judgement, so nothing waits on a tap: the
# owner adding a video to a playlist IS the decision. Notifications are receipts and
# faults only, which is also why none of them is ever withdrawn (ntfy/MESSAGES.md § 4).

set -uo pipefail

# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

# Notification vocabulary, declared per feature (see ntfy/MESSAGES.md § 9).
# `Archived` is this pipeline's own; `Dropped` is liquidroom's word for a download that
# failed, reused because the situation is the same; `Abandoned` is the policy verb for
# the 7-day give-up. The subjects are the state-slot faults below.
# shellcheck disable=SC2034  # consumed by systemd/contract.sh
NTFY_VERBS=(Archived Dropped Abandoned)
# shellcheck disable=SC2034  # consumed by systemd/contract.sh
NTFY_NOUNS=(Video)
# shellcheck disable=SC2034  # consumed by systemd/contract.sh
NTFY_SUBJECTS=(Backup ArchiveBox Channel)

NTFY_TOPIC="grayjay"

# WHAT IS FOLLOWED IS DECIDED ON THE PHONE (owner, 2026-11-01), so nothing here names a
# playlist or a channel. A playlist is followed while its name starts with the marker; a
# channel while it sits in the subscription group named below. Its ArchiveBox tag is the
# name minus the marker, letters and digits only: "📦 How Far Away Is It" ->
# HowFarAwayIsIt. Until 2026-11-01 this was a list of playlist UUIDs edited by hand,
# which meant every new playlist needed a change to this repo.
GRAYJAY_MARKER="📦"
GRAYJAY_GROUP="Archive"
# The yt-dlp ArchiveBox downloads with, inside its container (0.9 keeps it in its own
# abxpkg venv and has no yt-dlp on PATH). Used only to LIST a channel's videos.
GRAYJAY_YTDLP="/opt/archivebox/lib/uv/packages/yt-dlp/venv/bin/yt-dlp"

# Overridable ONLY so the suite can run against a scratch tree and a fake ArchiveBox.
# Never set in production — the defaults are the only values systemd runs with.
GRAYJAY_BACKUP="${GRAYJAY_BACKUP:-/zpool/catallenya/syncthing/data/master/config/GrayjayBackup.ezip}"
GRAYJAY_STATE="${GRAYJAY_STATE:-/zpool/catallenya/grayjay/state}"
GRAYJAY_DOCKER="${GRAYJAY_DOCKER:-docker}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="${SCRIPT_DIR}/grayjay.archive.py"

# Stable sequence ids, so a fault that recurs daily REPLACES yesterday's instead of
# stacking (ntfy/MESSAGES.md § 4). One per channel, keyed by its channel id. Unreadable and stale are two states of one subject,
# so they share an id: the newest word on the backup is the only one worth keeping.
BACKUP_NTFY_ID="grayjay-backup"
ARCHIVEBOX_NTFY_ID="grayjay-archivebox"
CHANNEL_NTFY_PREFIX="grayjay-channel-"

export PYTHONDONTWRITEBYTECODE=1   # scripts/ is read-only under the sandbox; never litter it

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
