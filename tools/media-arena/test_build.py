import unittest

from build import Matcher, base, build_board, build_llm_stats, norm

MODELS = [
    {"id": "openai/gpt-image-2", "name": "OpenAI: GPT Image 2"},
    {"id": "openai/gpt-5.4-image-2", "name": "OpenAI: GPT-5.4 Image 2"},
    {"id": "black-forest-labs/flux.2-max", "name": "Black Forest Labs: FLUX.2 Max"},
    {"id": "google/gemini-3.1-flash-image", "name": "Google: Nano Banana 2 (Gemini 3.1 Flash Image)"},
    {"id": "google/gemini-3.1-flash-image-preview", "name": "Google: Nano Banana 2 (Gemini 3.1 Flash Image Preview)"},
    {"id": "kwaivgi/kling-v3.0-pro", "name": "Kling: Video v3.0 Pro"},
]


def row(name, elo, id=None):
    return {"id": id or name, "slug": norm(name), "name": name, "elo": elo}


class MatchTests(unittest.TestCase):
    def test_keys(self):
        self.assertEqual(norm("FLUX.2 [max]"), "flux2max")
        self.assertEqual(base("Kling 3.0 1080p (Pro)"), "kling30")

    def test_names(self):
        m = Matcher(MODELS, {}, [])
        self.assertEqual(m.match(row("FLUX.2 [max]", 1)), ("black-forest-labs/flux.2-max", "name"))
        # The quality in parentheses is dropped, and "GPT-5.4 Image 2" stays apart.
        self.assertEqual(m.match(row("GPT Image 2 (high)", 1)), ("openai/gpt-image-2", "base name"))
        self.assertEqual(m.match(row("Nano Banana 2 (Gemini 3.1 Flash Image)", 1)), ("google/gemini-3.1-flash-image", "name"))
        # "Nano Banana 2" alone could be the final build or the preview: no guess.
        self.assertEqual(m.match(row("Nano Banana 2", 1)), (None, "no match"))

    def test_overrides_and_feed(self):
        overrides = {"_comment": "x", "Kling 3.0 Omni 1080p (Pro)": None, "aa-kling": "kwaivgi/kling-v3.0-pro"}
        feed = [{"aa_id": "aa-seedance", "aa_name": "Seedance", "heuristic_openrouter_slug": "bytedance/seedance-2.0"},
                {"aa_id": "aa-veo", "aa_name": "Veo", "openrouter_slug": "openai/gpt-5.4-image-2"}]
        m = Matcher(MODELS, overrides, feed)
        self.assertEqual(m.match(row("Kling 3.0 1080p (Pro)", 1, id="aa-kling")), ("kwaivgi/kling-v3.0-pro", "override"))
        self.assertEqual(m.match(row("Kling 3.0 Omni 1080p (Pro)", 1)), (None, "ignored"))
        # The feed's guess counts only when it names a model in this list.
        self.assertEqual(m.match(row("Seedance", 1, id="aa-seedance")), (None, "no match"))
        self.assertEqual(m.match(row("Veo", 1, id="aa-veo")), ("openai/gpt-5.4-image-2", "openrouter feed"))

    def test_board_keeps_the_best_match_per_model(self):
        feed = [{"aa_id": "omni", "heuristic_openrouter_slug": "kwaivgi/kling-v3.0-pro"}]
        rows = [row("Kling Omni", 1300, id="omni"), row("Kling Video v3.0 Pro", 1000), row("Midjourney v8", 1250)]
        board, unmatched = build_board(rows, Matcher(MODELS, {}, feed))
        # A name match beats the feed's guess even at a lower Elo.
        self.assertEqual(board["kwaivgi/kling-v3.0-pro"]["elo"], 1000)
        self.assertEqual([r["name"] for r in unmatched], ["Midjourney v8"])


class LLMStatsTests(unittest.TestCase):
    def test_speed_at_the_smartest_effort(self):
        slug = "openai/gpt-6-astra-20261001"
        feed = [{"aa_id": "low", "permaslug": slug, "benchmark_data": {"evaluations": {}}},
                {"aa_id": "max", "permaslug": slug, "benchmark_data": {"evaluations": {}}},
                {"aa_id": "img", "permaslug": "x/image", "benchmark_data": {"model_type": "text-to-image"}}]
        rows = [
            {"id": "low", "name": "GPT-6 Astra (Low)", "evaluations": {"artificial_analysis_intelligence_index": 40},
             "median_output_tokens_per_second": 120.4, "median_time_to_first_token_seconds": 0.53},
            {"id": "max", "name": "GPT-6 Astra (Max)", "evaluations": {"artificial_analysis_intelligence_index": 58},
             "median_output_tokens_per_second": 88.6, "median_time_to_first_token_seconds": 0.61,
             "median_time_to_first_answer_token": 21.27},
            {"id": "img", "name": "Not a chat model", "median_output_tokens_per_second": 50},
            {"id": "gone", "name": "Unlisted 2", "median_output_tokens_per_second": 50},
            {"id": "untimed", "name": "No speed", "median_output_tokens_per_second": 0},
        ]
        models, unmatched = build_llm_stats(rows, feed)
        self.assertEqual(models, {slug: {"tps": 89, "ttft": 0.6, "ttfa": 21.3, "aa": "GPT-6 Astra (Max)"}})
        self.assertEqual(unmatched, ["Not a chat model", "Unlisted 2"])


if __name__ == "__main__":
    unittest.main()
