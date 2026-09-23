import unittest

import ssm_push_env as p


class ParseTests(unittest.TestCase):
    def test_parse_quotes_comments_export(self):
        v = p.parse_env("# c\n\nA=1\nexport B='two words'\nC=\"x#y\"\nD=val # trailing\nE=a=b\nF=\n")
        self.assertEqual(v, {"A": "1", "B": "two words", "C": "x#y", "D": "val", "E": "a=b", "F": ""})

    def test_plan_skips_managed_empty_and_unsupported(self):
        w, s = p.plan({"JWT": "x", "BACKEND_TAG": "t", "ECR_REGISTRY": "r", "EMPTY": "", "Q": "it's"})
        self.assertEqual(w, {"JWT": "x"})
        self.assertEqual({n for n, _ in s}, {"BACKEND_TAG", "ECR_REGISTRY", "EMPTY", "Q"})


if __name__ == "__main__":
    unittest.main()
