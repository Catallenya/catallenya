# grayjay

Keeps a copy of every video in four Grayjay playlists, so a video that disappears from
YouTube is still watchable.

Add a video to **GuitarCore**, **AddisonCore**, **How Far Away Is It** or **The ABSOLUTELY
UNDERSTAND GUITAR VIDEO HOME STUDY PROGRAM** in Grayjay on the phone. Within a day or
two it is in ArchiveBox, tagged with the playlist's name. Nothing tells you so: the
`grayjay` topic is **silent unless something fails** (see Decisions below).

## How it works

```
phone: Grayjay auto-backup (every ~2 days, only while the app runs)
   → master/config/GrayjayBackup.ezip  (+ .ezip.old), over Syncthing

grayjay.archive.timer, daily 07:55 SGT
   → read the allow-listed playlists out of the backup, by UUID
   → each video never seen before → archivebox add --bg --tag <Playlist> --plugins title,ytdlp
   → each video handed over earlier → did a complete video file land?
   → ntfy, problems only: Dropped / Abandoned / Backup / Missing / Unreachable,
     plus Archived for a video that had failed and was later saved
```

There is no model, no button and no drop zone. Putting a video in the playlist is the
whole decision, so everything sent is a receipt or a fault (`ntfy/MESSAGES.md` § 7).

## Decisions

Settled with the owner on 2026-10-31. Each one is enforced by a case in `tests/run.sh`.

| Situation | What happens |
|---|---|
| A video saves | **Nothing is sent.** The phone hears only about problems |
| A video fails to download | `Dropped` once, silent daily retries, `Abandoned` 7 days after the FIRST failure. Two messages per video, never more |
| A video that failed later saves | `Archived: <title>`, the one piece of good news, so a failure you were told about is always closed |
| A system problem lasts days (ArchiveBox down, backup over 7 days old, a playlist missing, backup unreadable) | ONE notification that refreshes itself each morning until fixed: at most one buzz a day, never a pile |
| How often it checks | once a day, 07:55 SGT |
| A video is taken out of the playlist while unfinished (failing, given up, or still downloading) | It stops being tracked, silently. Nothing in ArchiveBox is touched: a running download finishes on its own and keeps its copy |
| A saved video is taken out of the playlist | Nothing changes. The copy and its playlist tag stay |
| A video taken out is added back | A fresh start: a new 7-day clock, so it can be `Dropped` and `Abandoned` again; if it saves, `Archived` (it had failed before) |
| A given-up video is still in the playlist | It stays given up, silently. Take it out and put it back to retry |
| A whole playlist goes missing, or the backup cannot be read | Nothing counts as "taken out"; the `Missing` or `Unreadable` fault is sent instead |

## Files

| Path | What |
|---|---|
| `scripts/grayjay.lib.sh` | settings: the playlist allow-list, paths, vocabulary |
| `scripts/grayjay.archive.sh` | the entry point; turns the report into notifications |
| `scripts/grayjay.archive.py` | the work: parse the backup, keep the records, judge results |
| `scripts/grayjay.abx.py` | runs inside the ArchiveBox container: look up snapshots, add tags |
| `systemd/grayjay.archive.{service,timer}` | the job (`Class=scheduled`, `Family=intake`) |
| `tests/run.sh` | the offline suite |
| `state/videos/<id>.json` | one record per video (not in git) |

## State

One record per video in `state/videos/`, and nothing else. The record's `status` is the
whole truth about that video:

| status | meaning |
|---|---|
| `pending` | handed to ArchiveBox; the download has not finished |
| `archived` | a complete video file is in its snapshot |
| `adopted` | the snapshot existed before this job saw the video AND already holds the video; tagged, never re-downloaded. A snapshot without the video (a page-only bookmark) is not adopted: ytdlp is run on it silently and it becomes `pending` (2026-11-01) |
| `failed` | the last attempt failed; retried daily without a notification |
| `abandoned` | still failing 7 days after the FIRST failure; never retried again |
| `removed` | taken out of every playlist while unfinished; no longer tracked. Put it back for a fresh start |

To retry an abandoned video, take it out of the playlist and put it back (or delete its record). To start over completely, delete
`state/`: every video whose snapshot already holds the video is adopted again, nothing
is downloaded twice.

## Things worth knowing

- **Playlists are matched by UUID, not name.** Renaming one changes nothing. Deleting
  one and making a new one gives a new UUID and a `<Tag>: Missing` fault; put the new
  UUID in `scripts/grayjay.lib.sh`.
- **URLs are rewritten to `https://www.youtube.com/watch?v=<id>`** before ArchiveBox
  sees them. Shared links carry `?si=` tracking, and one in the live backup carried
  `&list=RD…&start_radio=1`; ArchiveBox runs yt-dlp with `--yes-playlist`, so that link
  as stored would have archived an endless radio mix.
- **A second tag is set through Django, not `add --tag`.** With `ONLY_NEW`, `add` skips
  a URL that already has a snapshot before tagging it, so a video in both playlists
  would never get its second tag. `grayjay.abx.py` adds missing tags on every run, so
  removing a playlist tag in the ArchiveBox UI is undone the next morning while the
  video is still in that playlist.
- **ArchiveBox's status is not trusted, in either direction; the files decide.** The
  ytdlp plugin reports success for any media file, including a `.fNNN.` stream left when
  a timeout falls between yt-dlp's separate video and audio downloads, and the first
  backfill also produced the reverse: a result marked failed, with no message, holding a
  complete hour-long merged `.webm`. A video counts as archived exactly when a merged,
  non-partial media file is present, whatever the status says.
- **`YTDLP_MAX_SIZE=5000m` is a preference, not a cap.** The plugin's format selector
  is `(bv*+ba/b)[filesize<=5000m]/(bv*+ba/b)`, which falls back to the best format with
  no size limit. A video over 5 GB downloads anyway, or hits the 2-hour
  `YTDLP_TIMEOUT` and is dropped.
- **Removing a video from a playlist never deletes the archived copy.**
- **If the job itself stops**, the alert comes from the daily watchdog on the `host`
  topic, not here.
