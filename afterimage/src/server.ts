// capture — the "dumb" HTTP surface of the screenshot -> calendar pipeline.
//
// It does exactly three things: accept an uploaded screenshot, and on the ntfy
// button callbacks either PUT the already-rendered event to Radicale (Add) or
// drop the record (Discard). No AI, no .ics rendering, no secrets beyond the
// Radicale app password — all the intelligence lives in the host triage
// (afterimage/scripts/), which talks to this container only through the shared
// afterimage/data/ spool.
//
// The <id> in the callback URLs is an unguessable UUID, so the callbacks are
// capability URLs: on the tailnet, "whoever knows the id" is effectively just
// the owner. That's the same trust model as every other service here.

import { mkdir, rename, rm, readFile, stat } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";

const DATA = process.env.CAPTURE_DATA ?? "/data";
const PORT = Number(process.env.CAPTURE_PORT ?? 8080);
const RADICALE = process.env.RADICALE_URL ?? "http://radicale:5232";
const DAV_USER = process.env.CAPTURE_DAV_USER ?? "carrein";
// base64(carrein:<app pw>). Read from a docker secret rather than the environment:
// `docker inspect` and /proc/1/environ both expose env, and this credential is good
// for read/write/delete across the whole /carrein/ tree. Env is kept as a fallback
// so the container still starts if the secret is not mounted.
const DAV_B64 = (() => {
  try { return readFileSync("/run/secrets/afterimage-dav-secret", "utf8").trim(); }
  catch { return process.env.HITOME_DAV_B64 ?? ""; }
})();
// The ntfy web UI fires the action buttons with browser fetch(), so the custom
// X-Afterimage header triggers a CORS preflight. Refusing every preflight — which is
// what shipped this morning — blocks the web client entirely: the tap surfaces as
// "TypeError: NetworkError". Allowing exactly this one origin keeps the control
// intact, because browsers set Origin and a page cannot forge it, so an arbitrary
// tab still cannot reach these callbacks. The phone app is unaffected either way.
const NTFY_ORIGIN = process.env.NTFY_ORIGIN ?? "";
// Withdrawing the notification on a tap is the ONE thing this container does that
// is not "accept an upload" or "write to Radicale", and it is here rather than in
// the nightly sweep because the owner wanted the notification gone the instant the
// button is pressed, not by morning.
//
// Container-to-container over plain HTTP, exactly like RADICALE above: no TLS, no
// tailnet round trip, and nothing new in the trust model — ntfy is unauthenticated
// on this network already. Empty NTFY_URL disables it, which is what the tests use
// and what keeps this optional rather than load-bearing.
const NTFY_URL = process.env.NTFY_URL ?? "";
const NTFY_TOPIC = process.env.NTFY_TOPIC ?? "afterimage";
// How long to wait before the SECOND retract on a tap. See retractResolved().
const REDRAW_GRACE_MS = Number(process.env.REDRAW_GRACE_MS ?? 5000);
const CAL: Record<string, string> = {
  general: process.env.CAL_GENERAL ?? "",
  birthday: process.env.CAL_BIRTHDAY ?? "",
};

const spool = (...p: string[]) => [DATA, ...p].join("/");

// Resolve a capture: stamp the verdict into decision.json and move the whole
// record (screenshot + proposal + .ics) to the archive. The record IS the
// history — there is no ledger beside it, and no recording mode (both retired
// 2026-08-01): state is locations only. Mirrors archive_record() in
// afterimage.lib.sh; the two halves are kept in step by hand, so change both.
async function archive(id: string, outcome: string, note = ""): Promise<void> {
  const src = spool("pending", id);
  if (!existsSync(src)) return;

  const dest = spool("archive", id);
  const decidedAt = new Date().toISOString();
  let proposedAt = decidedAt;
  let latency = 0;
  try {
    const st = await stat(`${src}/proposal.json`);
    proposedAt = st.mtime.toISOString();
    latency = Math.round((Date.now() - st.mtimeMs) / 1000);
  } catch { /* record may predate proposal.json; fall back to now */ }

  const decision = { id, outcome, note, proposed_at: proposedAt, decided_at: decidedAt, latency_s: latency };
  await Bun.write(`${src}/decision.json`, JSON.stringify(decision));
  await mkdir(spool("archive"), { recursive: true });
  await rm(dest, { recursive: true, force: true });
  try {
    await rename(src, dest);
  } catch (e: any) {
    // Add and Discard tapped together: both passed the existsSync gate above, and
    // the loser finds the record already moved. That is a resolved capture, not an
    // error — rethrowing surfaced a 500 to a caller whose event had in fact landed.
    if (e?.code === "ENOENT") {
      console.log(`[already resolved] ${id} — concurrent callback won the race`);
      return;
    }
    throw e;
  }
  await retractResolved(id);
}

// Take this record's notification off the phone. ntfy has no message expiry and no
// scheduled delete: a DELETE addressed to the sequence id (which the host triage
// set with X-Sequence-ID when it published) is the only thing that removes one.
//
// Called only AFTER the record has moved to archive/ — the notification outliving a
// failed archive is strictly better than the reverse, where the buttons vanish while
// the record is still pending and the capture becomes unreachable.
//
// Never throws and never blocks the outcome: the tap's real work is the Radicale PUT
// and the archive, both already done by here. A failed retract leaves clutter, which
// the nightly sweep's archive pass then clears — that pass is the backstop for this
// call, not a duplicate of it.
async function retract(id: string): Promise<void> {
  if (!NTFY_URL) return;
  try {
    await fetch(`${NTFY_URL}/${NTFY_TOPIC}/${encodeURIComponent(id)}`, {
      method: "DELETE",
      signal: AbortSignal.timeout(5000),
    });
  } catch (e: any) {
    console.log(`[retract failed] ${id} — ${e?.message ?? e} (sweep will clear it)`);
  }
}

// Withdraw a RESOLVED record's notification: once now, and once after the tapping
// app has had time to redraw. Both calls are needed, and this is why.
//
// A DELETE issued before this handler answers is raced by the ntfy Android app's own
// redraw. The app fires the button's HTTP request, receives our 200, and then re-posts
// the notification to stamp the action done (the tick). That re-post lands AFTER our
// message_delete, so the notification the delete removed comes straight back — and
// re-tapping cannot clear it, because the record is resolved and the callback now
// answers 409/404. Only the nightly sweep does, up to ten hours later.
//
// Measured on the live topic 2026-08-22, three probes: a delete with no tap cleared
// the notification; a delete sent 52s after a tap cleared it; the real Discard, which
// deletes inside the request, did not. Every one of the 80 tap-resolved records in
// archive/ took the losing path and was cleaned up the next morning by the sweep.
//
// The immediate call is KEPT rather than replaced by the delayed one. A second
// subscribed device never tapped, so it never redraws — the immediate delete clears
// it at once, and waiting REDRAW_GRACE_MS on every device to fix the one that tapped
// would be the wrong trade. Deletes are idempotent and unvalidated (200 for an id the
// server has never seen), so the duplicate costs one no-op request.
//
// The delayed call is deliberately NOT awaited: it must land after we answer, which
// is the whole point, so it cannot be part of the response path.
async function retractResolved(id: string): Promise<void> {
  await retract(id);
  setTimeout(() => { void retract(id); }, REDRAW_GRACE_MS);
}

// A tap is decided, not final: for CORRECT_WINDOW_S after an Add the owner can still
// change their mind. The other variant swaps the event for its twin, and Discard takes
// it back out of the calendar. Before this a second tap found no pending record and was
// answered 404 — a tap that did nothing, on a notification that was still on screen
// because the ntfy app repaints it after a tap (see retractResolved). The owner tapped
// 18:00 for a 19:00 meeting and the correction was silently thrown away.
//
// This partly reverses the 2026-08-09 removal of undo, deliberately and only inside
// the window: past it a resolved record answers exactly as it did, so the old rule
// ("deleting the event in the calendar app") still holds for everything older.
// The clock is decision.json's decided_at, which a swap restamps, so a swap can itself
// be swapped back.
const CORRECT_WINDOW_S = Number(process.env.CORRECT_WINDOW_S ?? 120);

type Recent = { outcome: "add" | "add_alt"; dir: string; calendar?: string };

async function recentAdd(id: string): Promise<Recent | null> {
  const dir = spool("archive", id);
  try {
    const d = JSON.parse(await readFile(`${dir}/decision.json`, "utf8"));
    if (d.outcome !== "add" && d.outcome !== "add_alt") return null;
    if (Date.now() - Date.parse(d.decided_at) > CORRECT_WINDOW_S * 1000) return null;
    const p = JSON.parse(await readFile(`${dir}/proposal.json`, "utf8"));
    return { outcome: d.outcome, dir, calendar: p.calendar };
  } catch {
    return null; // not archived, no decision, or unreadable: nothing to correct
  }
}

async function restamp(dir: string, outcome: string, note: string): Promise<void> {
  const f = `${dir}/decision.json`;
  const d = JSON.parse(await readFile(f, "utf8"));
  await Bun.write(f, JSON.stringify({ ...d, outcome, note, decided_at: new Date().toISOString() }));
}

const itemUrl = (calendar: string | undefined, id: string) =>
  `${RADICALE}/${DAV_USER}/${calendar === "birthday" ? CAL.birthday : CAL.general}/${id}.ics`;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
// Full 8-byte signature, not just the first four: the trailing \r\n\x1a\n is what
// makes it a PNG rather than any file that happens to start with those bytes.
const PNG_SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]; // the macOS client
// SOI + marker only: the fourth byte varies by variant (e0 = JFIF, e1 = Exif,
// which is what ColorOS emits), so matching four would reject real screenshots.
const JPEG_SIG = [0xff, 0xd8, 0xff];      // Android screenshots are JPEG, not PNG
// Camera photos: an ISO-BMFF `ftyp` box at offset 4 with a HEIF image brand at 8.
// The bytes are spooled as-is; the host triage converts them to JPEG, because the
// API refuses HEIC and this container has no decoder (and should not grow one).
const HEIC_BRANDS = new Set(["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"]);
const isHeic = (b: Uint8Array) =>
  b.length >= 12 && new TextDecoder().decode(b.subarray(4, 8)) === "ftyp" &&
  HEIC_BRANDS.has(new TextDecoder().decode(b.subarray(8, 12)));
const MAX_BYTES = 15 * 1024 * 1024;

for (const d of ["incoming", "pending", "archive"]) {
  await mkdir(spool(d), { recursive: true });
}

// Clear partial uploads from a previous life. `.part-<uuid>` is deliberately named
// so neither afterimage.triage.path's *.png glob nor the triage's own scan can see it,
// which also means nothing else would ever clean it up.
try {
  const { readdir, unlink } = await import("node:fs/promises");
  for (const f of await readdir(spool("incoming"))) {
    if (f.startsWith(".part-")) {
      await unlink(spool("incoming", f));
      console.log(`removed stale partial upload ${f}`);
    }
  }
} catch { /* best effort at startup; never block serving */ }

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

// POST /afterimage — receive a screenshot, drop it in the spool, return its id.
// The host triage's .path unit fires on the new file; this container does no
// more work until an Add/Discard callback arrives.
async function handleUpload(req: Request): Promise<Response> {
  // Reject on the declared length FIRST. arrayBuffer() pulls the whole body into
  // memory at ~2.3x its size in RSS, so checking afterwards means a large POST is
  // fully buffered purely to be refused — which is how a single ~48MB request used
  // to OOM-kill this container. A lying Content-Length is still bounded by the
  // check below and by the container memory limit.
  const declared = Number(req.headers.get("content-length") ?? 0);
  if (declared > MAX_BYTES) return json({ error: "bad size" }, 413);
  const buf = new Uint8Array(await req.arrayBuffer());
  if (buf.length === 0 || buf.length > MAX_BYTES) return json({ error: "bad size" }, 413);
  const sigOk = (sig: number[]) => sig.every((b, i) => buf[i] === b);
  if (!sigOk(PNG_SIG) && !sigOk(JPEG_SIG) && !isHeic(buf)) {
    return json({ error: "not a png, jpeg or heic" }, 415);
  }
  const id = crypto.randomUUID();
  // Write under a name the .path unit's glob (*.png) does NOT match, then rename.
  // rename(2) is atomic within a filesystem, so systemd only ever sees a complete
  // file — otherwise PathExistsGlob can fire mid-write and the triage reads a
  // truncated image, burning an API call on a corrupt one.
  //
  // The `.png` here is a QUEUE TOKEN, not a claim about the bytes: a JPEG or HEIC
  // upload also lands as <id>.png. afterimage.triage.path lives in /etc/systemd/system and
  // globs *.png, and changing a root-owned unit needs a password this service
  // does not have — so the spool name stays fixed and the triage sniffs the
  // actual format, naming the archived copy honestly.
  const tmp = spool("incoming", `.part-${id}`);
  await Bun.write(tmp, buf);
  await rename(tmp, spool("incoming", `${id}.png`));
  return json({ id });
}

// POST /afterimage/:id/add[?alt=1] — the Add button. Read the rendered event + its
// calendar routing from pending/<id>/, PUT it to the mapped Radicale collection,
// and on success move the record to done/.
//
// `alt=1` selects the disambiguation variant (event.alt.ics), which the triage
// renders when the screenshot supported a second plausible reading — that's the
// second button on the notification. Both variants are pre-rendered, so either
// tap is a straight file read plus one PUT.
async function handleAdd(id: string, alt: boolean): Promise<Response> {
  const rec = spool("pending", id);
  if (!existsSync(rec)) {
    // The record is resolved, so this notification is a leftover — withdraw it
    // rather than answering 404 into a message that stays on screen. See
    // retractResolved(): before this, a tap that lost the redraw race left buttons
    // that could not clear themselves, and only the sweep took them down.
    //
    // Only THIS branch may retract. The 409s below are pending records missing a
    // file, and the 502 leaves the record pending for a retry — in both the buttons
    // are still the way to act, and taking them away would strand the capture.
    const prior = await recentAdd(id);
    if (prior) {
      const want = alt ? "add_alt" : "add";
      if (prior.outcome === want) {
        // Same button again: the event is already in the calendar as asked.
        await retractResolved(id);
        return json({ ok: true, status: "already" });
      }
      try {
        const ics = await readFile(`${prior.dir}/${alt ? "event.alt.ics" : "event.ics"}`, "utf8");
        // No If-None-Match: replacing the item is the point. Same href as the first
        // Add, so this overwrites it rather than creating a second event.
        const res = await fetch(itemUrl(prior.calendar, id), {
          method: "PUT",
          headers: { authorization: `Basic ${DAV_B64}`, "content-type": "text/calendar" },
          body: ics,
        });
        if (res.status !== 201 && res.status !== 204) return json({ error: "caldav put failed", status: res.status }, 502);
        await restamp(prior.dir, want, `swapped, caldav ${res.status}`);
        await retractResolved(id);
        return json({ ok: true, status: res.status, swapped: true });
      } catch {
        return json({ error: "no alternative on this record" }, 409);
      }
    }
    await retractResolved(id);
    return json({ error: "no pending record" }, 404);
  }

  const icsFile = alt ? "event.alt.ics" : "event.ics";
  const propFile = alt ? "proposal.alt.json" : "proposal.json";

  let proposal: { calendar?: string };
  let ics: string;
  try {
    proposal = JSON.parse(await readFile(`${rec}/${propFile}`, "utf8"));
    ics = await readFile(`${rec}/${icsFile}`, "utf8");
  } catch {
    return json({ error: alt ? "no alternative on this record" : "record incomplete" }, 409);
  }

  const collection = proposal.calendar === "birthday" ? CAL.birthday : CAL.general;
  if (!collection) return json({ error: "collection not configured" }, 500);

  // If-None-Match: * makes this create-only; a duplicate Add tap gets 412, which
  // we treat as already-done (idempotent). The record <id> is the item href.
  const res = await fetch(`${RADICALE}/${DAV_USER}/${collection}/${id}.ics`, {
    method: "PUT",
    headers: {
      authorization: `Basic ${DAV_B64}`,
      "content-type": "text/calendar",
      "if-none-match": "*",
    },
    body: ics,
  });

  if (res.status === 201 || res.status === 204 || res.status === 412) {
    // 412 = If-None-Match tripped: the item already exists, so this PUT wrote
    // nothing. Idempotent from the caller's point of view, but recording it as an
    // "add" would claim an acceptance that wrote nothing. Its own outcome keeps
    // decision.json honest.
    const outcome = res.status === 412
      ? "add_duplicate"
      : (alt ? "add_alt" : "add");
    await archive(id, outcome, `caldav ${res.status}`);
    return json({ ok: true, status: res.status });
  }
  // Non-2xx: leave the record in pending/ so a retry is possible; the host
  // triage's ntfy already carries the buttons for another attempt.
  return json({ error: "caldav put failed", status: res.status }, 502);
}

// POST /afterimage/:id/drop — the Discard button. A rejection is as much a labelled
// example as an acceptance ("the model proposed this and I said no"), so the
// record is archived with the verdict rather than deleted.
//
// Discard doubles as UNDO again, but only inside CORRECT_WINDOW_S of an Add (see
// recentAdd): it deletes the event back out of Radicale and restamps the outcome as
// `undone`. Outside the window the 2026-08-09 rule stands — the ordinary undo for a
// wrong Add is deleting the event in the calendar app.
//
// A drop on a record that is no longer pending answers 409, NOT {ok:true}. The
// difference matters: answering ok while doing nothing is precisely the bug fixed
// on 2026-07-27, where a tap reported success and the event stayed in the calendar.
// Removing undoAdd must not quietly reintroduce it.
async function handleDrop(id: string): Promise<Response> {
  if (!existsSync(spool("pending", id))) {
    const prior = await recentAdd(id);
    if (prior) {
      // Discard inside the correction window: take the event back out. A 404 from
      // Radicale means it is already gone, which is the state the owner asked for.
      const res = await fetch(itemUrl(prior.calendar, id), {
        method: "DELETE",
        headers: { authorization: `Basic ${DAV_B64}` },
      });
      if (res.status !== 200 && res.status !== 204 && res.status !== 404) {
        return json({ error: "caldav delete failed", status: res.status }, 502);
      }
      await restamp(prior.dir, "undone", `caldav ${res.status}`);
      await retractResolved(id);
      return json({ ok: true, undone: true });
    }
    // Resolved already, so the notification is a leftover: withdraw it. The 409 is
    // unchanged and still means "this tap did nothing" — answering ok here is the
    // 2026-07-27 bug, and clearing the message is not the same claim.
    await retractResolved(id);
    return json({ error: "already resolved", id }, 409);
  }
  await archive(id, "discard");
  await rm(spool("incoming", `${id}.png`), { force: true });
  return json({ ok: true });
}

Bun.serve({
  port: PORT,
  // A throw inside a handler would otherwise surface as an opaque 500 with the
  // stack on stdout and no record of which request caused it.
  error(e: Error) {
    console.error(`unhandled: ${e?.message}`);
    return json({ error: "internal" }, 500);
  },
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/healthz") return new Response("ok");

    // Answer the preflight for the ntfy web UI, and only for it.
    const origin = req.headers.get("origin") ?? "";
    const originOk = NTFY_ORIGIN !== "" && origin === NTFY_ORIGIN;
    if (req.method === "OPTIONS") {
      if (!originOk) return json({ error: "origin not allowed" }, 403);
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": origin,
          "access-control-allow-methods": "POST",
          "access-control-allow-headers": "X-Afterimage, Content-Type",
          "access-control-max-age": "86400",
        },
      });
    }

    const m = url.pathname.match(/^\/afterimage(?:\/([^/]+)\/(add|drop))?\/?$/);
    if (!m) return json({ error: "not found" }, 404);

    // Require a custom header on EVERY /afterimage route — the upload included.
    // This is NOT authentication: anyone who can read the ntfy topic still has the
    // callback ids, and ntfy is currently unauthenticated (accepted risk).
    //
    // What it kills is the no-preflight vector. A bare POST with no custom header
    // is a CORS "simple request", so any web page open on any tailnet device could
    // fire one cross-origin — and the .ts.net hostname is in Certificate
    // Transparency logs, not a secret. Requiring a custom header forces a preflight
    // this server never answers, so the browser refuses to send it. ntfy action
    // buttons set headers natively, so real taps are unaffected.
    //
    // The upload branch needs this MORE than the callbacks do: it is the endpoint
    // that spends money (one opus-5 vision call per accepted PNG) and it is
    // reachable container-to-container on the flat compose network, where Caddy is
    // bypassed entirely — changedetection-browser renders attacker-chosen pages and
    // archivebox fetches attacker-chosen URLs, and both can resolve capture:8080.
    if (req.headers.get("x-afterimage") !== "1") {
      return json({ error: "missing x-afterimage header" }, 403);
    }

    const [, id, action] = m;
    if (!id) {
      return req.method === "POST" ? handleUpload(req) : json({ error: "method not allowed" }, 405);
    }
    if (!UUID.test(id)) return json({ error: "bad id" }, 400); // reject path traversal
    if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

    const res = action === "add"
      ? await handleAdd(id, url.searchParams.get("alt") === "1")
      : await handleDrop(id);
    // Without this the browser blocks the caller from reading its own response, so
    // a tap that actually worked still reports a network error.
    if (originOk) res.headers.set("access-control-allow-origin", origin);
    return res;
  },
});

console.log(`capture listening on :${PORT}`);
