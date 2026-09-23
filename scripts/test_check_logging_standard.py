import os
import subprocess
import tempfile
import unittest

import check_logging_standard as cls


def ids(profile, line):
    rules, _ = cls.PROFILES[profile]
    return [r.id for r in cls.check_line(rules, line)]


class JavaRules(unittest.TestCase):
    def test_flags_system_out_and_print_stack_trace(self):
        self.assertIn("JAVA001", ids("java", 'System.out.println("x");'))
        self.assertIn("JAVA002", ids("java", "} catch (Exception e) { e.printStackTrace(); }"))

    def test_error_or_warn_with_only_message_is_flagged_but_not_when_exception_is_passed(self):
        self.assertIn("JAVA003", ids("java", 'log.error("Failed: {}", e.getMessage());'))
        self.assertNotIn("JAVA003", ids("java", 'log.error("Failed: {}", e.getMessage(), e);'))
        self.assertNotIn("JAVA003", ids("java", 'log.info("Failed: {}", e.getMessage());'))  # only warn/error matter

    def test_secrets_in_log_calls(self):
        self.assertIn("JAVA004", ids("java", 'log.info("token={}", refreshToken);'))
        self.assertIn("JAVA004", ids("java", 'log.debug("login " + password);'.replace('+ password', ', password')))
        self.assertNotIn("JAVA004", ids("java", 'log.info("token present={}", token != null);'.replace("token != null", "isTokenPresent")))
        self.assertNotIn("JAVA004", ids("java", 'log.warn("password hash={}", hash(password));'))
        self.assertNotIn("JAVA004", ids("java", 'String x = password;'))  # not a log call

    def test_raw_email_in_log_calls(self):
        self.assertIn("JAVA005", ids("java", 'log.info("Sent to {}", email);'))
        self.assertIn("JAVA005", ids("java", 'log.warn("Failed for {}: {}", user.getEmail(), e.getMessage(), e);'))
        self.assertNotIn("JAVA005", ids("java", 'log.info("Sent to userHash={}", MaskingUtils.hashIdentifier(email));'))
        self.assertNotIn("JAVA005", ids("java", 'log.info("Sent to studentId={}", student.getId());'))

    def test_string_concat_is_only_a_warning(self):
        hits = cls.check_line(cls.PROFILES["java"][0], 'log.info("user " + id);')
        self.assertEqual([(r.id, r.severity) for r in hits], [("JAVA006", "warning")])

    def test_inline_ignore_requires_marker(self):
        self.assertEqual(ids("java", 'System.out.println("x"); // logging-standard:ignore CLI banner'), [])


class OtherProfiles(unittest.TestCase):
    def test_python(self):
        self.assertIn("PY001", ids("python", "    print('hi')"))
        self.assertNotIn("PY001", ids("python", "    pprint(x)"))
        self.assertIn("PY002", ids("python", "logging.basicConfig(level=logging.INFO)"))
        self.assertIn("PY003", ids("python", 'logger.error(f"boom {e}")'))
        self.assertNotIn("PY003", ids("python", 'logger.error(f"boom {e}", exc_info=True)'))
        self.assertIn("PY004", ids("python", 'logger.info(f"key {api_key}")'))
        self.assertNotIn("PY004", ids("python", 'logger.info(f"key {mask_secret(api_key)}")'))
        self.assertIn("PY005", ids("python", 'logger.info("mail %s", user_email)'))

    def test_node(self):
        self.assertIn("JS001", ids("node", "  console.log('x')"))
        self.assertNotIn("JS001", ids("node", "  logger.info('x')"))
        self.assertIn("JS002", ids("node", "logger.info('t', { token })"))
        self.assertIn("JS003", ids("node", "logger.warn('sent', email)"))

    def test_frontend(self):
        self.assertIn("FE001", ids("frontend", "console.log('jwt', token)"))
        self.assertEqual(ids("frontend", "console.log('hello')"), ["FE002"])


class DiffScanning(unittest.TestCase):
    def test_only_added_lines_are_checked_and_line_numbers_are_correct(self):
        diff = (
            "diff --git a/src/main/java/A.java b/src/main/java/A.java\n"
            "--- a/src/main/java/A.java\n+++ b/src/main/java/A.java\n"
            "@@ -10,0 +11,2 @@\n"
            '+    System.out.println("added");\n'
            "+    int ok = 1;\n"
            "@@ -30,1 +33,1 @@\n"
            '-    System.out.println("removed");\n'
            '+    log.error("x {}", e.getMessage());\n'
        )
        found = cls.scan_added(diff, "java")
        self.assertEqual([(v.line, v.rule.id) for v in found], [(11, "JAVA001"), (33, "JAVA003")])

    def test_tests_scripts_and_wrong_extensions_are_skipped(self):
        line = 'System.out.println("x");'
        for path in ("src/test/java/AT.java", "src/main/java/scripts/X.java", "README.md"):
            diff = f"--- a/{path}\n+++ b/{path}\n@@ -0,0 +1 @@\n+{line}\n"
            self.assertEqual(cls.scan_added(diff, "java"), [], path)

    def test_end_to_end_against_a_real_git_repo(self):
        with tempfile.TemporaryDirectory() as d:
            def git(*a):
                subprocess.run(["git", *a], cwd=d, check=True, capture_output=True,
                               env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})
            git("init", "-q", "-b", "main")
            os.makedirs(os.path.join(d, "src/main/java"))
            path = os.path.join(d, "src/main/java/S.java")
            open(path, "w").write('class S { void a() { System.out.println("legacy"); } }\n')
            git("add", "."); git("commit", "-qm", "legacy")
            base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=d, capture_output=True, text=True).stdout.strip()
            open(path, "a").write('class T { void b() { log.info("ok"); } }\n')
            git("commit", "-aqm", "clean change")
            self.assertEqual(cls.main(["--profile", "java", "--base", base, "--repo", d]), 0)   # legacy line is not re-flagged
            open(path, "a").write('class U { void c() { System.out.println("new"); } }\n')
            git("commit", "-aqm", "bad change")
            self.assertEqual(cls.main(["--profile", "java", "--base", base, "--repo", d]), 1)
            self.assertEqual(cls.main(["--profile", "java", "--base", base, "--repo", d, "--warn-only"]), 0)


if __name__ == "__main__":
    unittest.main()
