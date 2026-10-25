#!/usr/bin/env python3
"""Builds the files the app downloads from the arena-data branch, from Artificial Analysis's API:

- media-arena.json: arena Elo for image, video and voice models, keyed by OpenRouter model id, in
  place of the app's bundled snapshot. AA names its models its own way ("FLUX.2 [max]", "Kling 3.0
  1080p (Pro)"), so each row is matched to an OpenRouter model, in order of trust: overrides.json,
  then the same name, then the same name without its parenthesised qualifiers, then the AA →
  OpenRouter mapping in OpenRouter's own benchmark feed. Rows that match nothing are listed under
  "unmatched"; add them to overrides.json when OpenRouter does carry the model.
- llm-stats.json: measured speed for chat models, keyed by OpenRouter's canonical slug (the one
  its benchmark feed uses), which AA's API doesn't offer elsewhere for free.

Usage: AA_API_KEY=… build.py --dir published
Each file in --dir is read as the last published version and rewritten only when its data changed.
Needs only the standard library. Exits 1 when a whole file failed to build; a media board that
fails to load keeps its previous scores.
"""

import argparse
import datetime
import json
import os
import re
import sys
import unicodedata
import urllib.request

AA_BASE = "https://artificialanalysis.ai/api/v2/data/media/"
AA_LLMS = "https://artificialanalysis.ai/api/v2/data/llms/models"
OR_BASE = "https://openrouter.ai/api/v1/"
OR_FEED = "https://openrouter.ai/api/frontend/v1/private/artificial-analysis-benchmarks/all"

# AA board → the OpenRouter list its models come from.
BOARDS = {
    "text-to-image": "images",
    "image-editing": "images",
    "text-to-video": "videos",
    "image-to-video": "videos",
    "text-to-speech": "speech",
}
OR_LISTS = {
    "images": "images/models",
    "videos": "videos/models",
    "speech": "models?output_modalities=speech",
}
# Match levels, best first; when two rows land on one model, the better level wins, then the higher Elo.
VIA = ["override", "name", "base name", "openrouter feed"]


def warn(message):
    print(f"::warning::{message}" if os.environ.get("GITHUB_ACTIONS") else f"warning: {message}", file=sys.stderr)


def get_json(url, headers=None):
    req = urllib.request.Request(url, headers={"User-Agent": "halo-media-arena", **(headers or {})})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def norm(text):
    """Lowercase letters and digits only: "FLUX.2 [max]" → "flux2max"."""
    text = unicodedata.normalize("NFKD", text).lower()
    return "".join(c for c in text if c.isalnum())


def base(text):
    """The name without parenthesised parts or resolutions: "Kling 3.0 1080p (Pro)" → "kling30"."""
    text = re.sub(r"\([^)]*\)", " ", text)
    text = re.sub(r"\b\d{3,4}p\b", " ", text, flags=re.IGNORECASE)
    return norm(text)


def short_name(name):
    """OpenRouter prefixes the lab: "Google: Nano Banana 2.1" → "Nano Banana 2.1"."""
    return name.split(": ", 1)[1] if ": " in name else name


class Matcher:
    def __init__(self, models, overrides, feed_rows):
        """`models`: OpenRouter models ({id, name}) of one kind. `feed_rows`: OpenRouter's AA feed."""
        self.ids = {m["id"] for m in models}
        self.overrides = {k: v for k, v in overrides.items() if not k.startswith("_")}
        self.by_name, self.by_base = {}, {}
        for m in models:
            name = short_name(m["name"])
            slug = m["id"].split("/", 1)[-1]
            for key in {norm(m["name"]), norm(name), norm(slug)}:
                self.by_name.setdefault(key, set()).add(m["id"])
            # "Nano Banana 2 (Gemini 3.1 Flash Image)" also goes by what's in the parentheses.
            aliases = {base(name)} | {norm(p) for p in re.findall(r"\(([^)]*)\)", name)}
            for key in aliases - {""}:
                self.by_base.setdefault(key, set()).add(m["id"])
        self.feed = {}
        for r in feed_rows:
            target = r.get("openrouter_slug") or r.get("heuristic_openrouter_slug")
            if not target:
                continue
            for key in (r.get("aa_id"), r.get("aa_slug"), r.get("aa_name")):
                if key:
                    self.feed.setdefault(key, target)

    def match(self, row):
        """(OpenRouter id, how) for one AA row; (None, reason) when it matches nothing."""
        keys = [row.get("id"), row.get("slug"), row.get("name")]
        for key in keys:
            if key and key in self.overrides:
                target = self.overrides[key]
                return (target, "override") if target else (None, "ignored")
        name = row.get("name") or ""
        for index, key, via in ((self.by_name, norm(name), "name"), (self.by_base, base(name), "base name")):
            found = index.get(key, set())
            if len(found) == 1:
                return next(iter(found)), via
        for key in keys:
            target = self.feed.get(key) if key else None
            if target in self.ids:
                return target, "openrouter feed"
        return None, "no match"


def build_board(rows, matcher):
    """{OpenRouter id: {elo, aa, via}}, and the rows that matched nothing."""
    board, unmatched = {}, []
    for row in rows:
        elo = row.get("elo")
        if not isinstance(elo, (int, float)):
            continue
        target, via = matcher.match(row)
        if target is None:
            if via != "ignored":
                unmatched.append({"name": row.get("name"), "id": row.get("id"), "elo": elo})
            continue
        entry = {"elo": elo, "aa": row.get("name"), "via": via}
        held = board.get(target)
        if held is None or (VIA.index(via), -elo) < (VIA.index(held["via"]), -held["elo"]):
            board[target] = entry
    unmatched.sort(key=lambda r: -r["elo"])
    return board, unmatched


def build_llm_stats(rows, feed_rows):
    """{canonical slug: {tps, ttft, ttfa, aa}}, and the names of AA models OpenRouter doesn't carry.
    AA lists each reasoning effort as its own model ("GPT-6 Astra (High)", "(Low)"…); OpenRouter's
    scores describe a model at its smartest effort, so its speed is taken there too."""
    slug_for = {}
    for r in feed_rows:
        if (r.get("benchmark_data") or {}).get("model_type") not in (None, "llm") or not r.get("permaslug"):
            continue
        for key in (r.get("aa_id"), r.get("aa_slug"), r.get("aa_name")):
            if key:
                slug_for.setdefault(key, r["permaslug"])
    best, unmatched = {}, []
    for row in rows:
        tps = row.get("median_output_tokens_per_second")
        if not isinstance(tps, (int, float)) or tps <= 0:
            continue
        slug = next((slug_for[k] for k in (row.get("id"), row.get("slug"), row.get("name")) if k in slug_for), None)
        if slug is None:
            unmatched.append(row.get("name") or row.get("id"))
            continue
        iq = (row.get("evaluations") or {}).get("artificial_analysis_intelligence_index") or 0
        if slug not in best or iq > best[slug][0]:
            best[slug] = (iq, row)

    def seconds(value):
        return round(value, 1) if isinstance(value, (int, float)) and value > 0 else None

    # Rounded, so day-to-day jitter doesn't make a commit.
    models = {}
    for slug, (_, row) in best.items():
        entry = {"tps": round(row["median_output_tokens_per_second"]), "aa": row.get("name"),
                 "ttft": seconds(row.get("median_time_to_first_token_seconds")),
                 "ttfa": seconds(row.get("median_time_to_first_answer_token"))}
        models[slug] = {k: v for k, v in entry.items() if v is not None}
    return models, sorted(n for n in unmatched if n)


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def content(doc):
    return {k: v for k, v in (doc or {}).items() if k != "updated_at"}


def publish(path, data, previous):
    """Writes `data` with the source and today's date, unless only the date would change (the date
    says when the data last changed). True when written."""
    doc = {
        "source": "Artificial Analysis",
        "source_url": "https://artificialanalysis.ai",
        "updated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        **data,
    }
    if content(doc) == content(previous):
        return False
    with open(path, "w") as f:
        json.dump(doc, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", required=True, help="holds the last published files, which are rewritten when they change")
    parser.add_argument("--overrides", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "overrides.json"))
    parser.add_argument("--fixtures", help="read every response from this folder instead (for testing)")
    args = parser.parse_args()

    def fetch(name, url, headers=None):
        if args.fixtures:
            return load(os.path.join(args.fixtures, name + ".json"))
        return get_json(url, headers)

    key = os.environ.get("AA_API_KEY")
    if not key and not args.fixtures:
        sys.exit("AA_API_KEY is not set")
    media_path = os.path.join(args.dir, "media-arena.json")
    llm_path = os.path.join(args.dir, "llm-stats.json")
    previous = load(media_path)
    overrides = load(args.overrides) or {}

    models = {kind: fetch(kind, OR_BASE + path)["data"] for kind, path in OR_LISTS.items()}
    try:
        feed = fetch("feed", OR_FEED)["data"]
    except Exception as e:
        warn(f"OpenRouter's benchmark feed didn't load ({e}); matching by name only")
        feed = []
    matchers = {kind: Matcher(models[kind], overrides, feed) for kind in models}

    boards, unmatched, failed = {}, {}, []
    for board, kind in BOARDS.items():
        try:
            rows = fetch(board, AA_BASE + board, {"x-api-key": key or ""})["data"]
            scores, missed = build_board(rows, matchers[kind])
            if not scores:
                raise ValueError(f"{len(rows)} rows, none matched an OpenRouter model")
        except Exception as e:
            failed.append(board)
            kept = (previous or {}).get("boards", {}).get(board)
            warn(f"{board} didn't load ({e}); " + ("keeping the previous scores" if kept else "leaving it out"))
            if kept:
                boards[board] = kept
                unmatched[board] = previous.get("unmatched", {}).get(board, [])
            continue
        boards[board] = scores
        unmatched[board] = missed
        print(f"{board}: {len(scores)} matched, {len(missed)} unmatched")

    media_ok = len(failed) < len(BOARDS)
    media_changed = media_ok and publish(media_path, {"boards": boards, "unmatched": unmatched}, previous)
    print(f"media-arena.json: {'changed' if media_changed else 'unchanged'}")

    speeds, llm_unmatched, llm_ok = {}, [], True
    try:
        speeds, llm_unmatched = build_llm_stats(fetch("llms", AA_LLMS, {"x-api-key": key or ""})["data"], feed)
        if not speeds:
            raise ValueError("no model matched an OpenRouter model")
    except Exception as e:
        llm_ok = False
        warn(f"chat model stats didn't load ({e}); keeping the previous file")
    llm_changed = llm_ok and publish(llm_path, {"models": speeds, "unmatched": llm_unmatched}, load(llm_path))
    print(f"llm-stats.json: {len(speeds)} matched, {len(llm_unmatched)} unmatched, {'changed' if llm_changed else 'unchanged'}")

    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as f:
            f.write(f"### Media arena ratings: {'updated' if media_changed else 'no change'}\n\n")
            for board in BOARDS:
                note = " (failed, kept previous)" if board in failed else ""
                f.write(f"**{board}**: {len(boards.get(board, {}))} matched{note}\n\n")
                for r in unmatched.get(board, [])[:15]:
                    f.write(f"- unmatched: {r['name']} (Elo {r['elo']:.0f})\n")
                f.write("\n")
            f.write(f"### Chat model speed: {'updated' if llm_changed else 'no change' if llm_ok else 'failed'}\n\n")
            f.write(f"{len(speeds)} models matched; {len(llm_unmatched)} AA models aren't on OpenRouter's feed.\n")

    if not media_ok or not llm_ok:
        sys.exit("media boards didn't load" if not media_ok else "chat model stats didn't load")


if __name__ == "__main__":
    main()
