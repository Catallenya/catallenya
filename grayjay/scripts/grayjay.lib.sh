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
NTFY_SUBJECTS=(Backup ArchiveBox Guitar AddisonCore HowFarAwayIsIt AbsolutelyUnderstandGuitar)

NTFY_TOPIC="grayjay"

# THE ALLOW-LIST. By UUID, never by name: the owner renames playlists (the AddisonCore
# emoji is going) and a rename must change nothing. Deleting a playlist and making a new
# one with the same name DOES change the UUID, and the job then says `<Tag>: Missing`
# rather than guessing — put the new UUID here. The tag is what ArchiveBox shows.
PLAYLISTS=(
    "a359d200-8781-409e-b76a-ba0b6c3e58d5=Guitar"
    "e46f4674-39b9-4d51-aee0-3b38758ac332=AddisonCore"
    # Added 2026-10-31, IDs read from that day's backup and confirmed by the owner.
    "442d205f-a3e0-458d-b835-58ac3d4284fc=HowFarAwayIsIt"
    "c3d3a827-ffae-496f-b3b7-ce2a71cf2dd0=AbsolutelyUnderstandGuitar"
)

# Overridable ONLY so the suite can run against a scratch tree and a fake ArchiveBox.
# Never set in production — the defaults are the only values systemd runs with.
GRAYJAY_BACKUP="${GRAYJAY_BACKUP:-/zpool/catallenya/syncthing/data/master/config/GrayjayBackup.ezip}"
GRAYJAY_STATE="${GRAYJAY_STATE:-/zpool/catallenya/grayjay/state}"
GRAYJAY_DOCKER="${GRAYJAY_DOCKER:-docker}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="${SCRIPT_DIR}/grayjay.archive.py"

# Stable sequence ids, so a fault that recurs daily REPLACES yesterday's instead of
# stacking (ntfy/MESSAGES.md § 4). Unreadable and stale are two states of one subject,
# so they share an id: the newest word on the backup is the only one worth keeping.
BACKUP_NTFY_ID="grayjay-backup"
ARCHIVEBOX_NTFY_ID="grayjay-archivebox"
MISSING_NTFY_PREFIX="grayjay-missing-"

export PYTHONDONTWRITEBYTECODE=1   # scripts/ is read-only under the sandbox; never litter it

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
