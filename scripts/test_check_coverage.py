import tempfile
import unittest

import check_coverage as cc

JACOCO = '<report name="x"><package name="p"><counter type="LINE" missed="99" covered="1"/></package>' \
         '<counter type="INSTRUCTION" missed="1" covered="9"/><counter type="LINE" missed="30" covered="70"/></report>'
COBERTURA = '<coverage lines-valid="200" lines-covered="150"></coverage>'
LCOV = "SF:a.js\nLF:10\nLH:5\nend_of_record\nSF:b.js\nLF:10\nLH:10\nend_of_record\n"


def write(content):
    f = tempfile.NamedTemporaryFile("w", delete=False, suffix=".rep")
    f.write(content)
    f.close()
    return f.name


class Coverage(unittest.TestCase):
    def test_jacoco_uses_report_level_line_counter_not_package_level(self):
        ok, pct, covered, total = cc.evaluate("jacoco", write(JACOCO), 60)
        self.assertEqual((covered, total), (70, 100))
        self.assertTrue(ok)
        self.assertFalse(cc.evaluate("jacoco", write(JACOCO), 71)[0])

    def test_cobertura_and_lcov(self):
        self.assertEqual(cc.evaluate("cobertura", write(COBERTURA), 75)[:2], (True, 75.0))
        self.assertEqual(cc.evaluate("lcov", write(LCOV), 75)[2:], (15, 20))

    def test_missing_or_empty_report_fails_closed(self):
        self.assertEqual(cc.main(["--format", "jacoco", "--file", "/nonexistent.xml", "--min", "0"]), 1)
        self.assertEqual(cc.main(["--format", "lcov", "--file", write(""), "--min", "0"]), 1)

    def test_exit_codes(self):
        self.assertEqual(cc.main(["--format", "cobertura", "--file", write(COBERTURA), "--min", "75"]), 0)
        self.assertEqual(cc.main(["--format", "cobertura", "--file", write(COBERTURA), "--min", "76"]), 1)


if __name__ == "__main__":
    unittest.main()
