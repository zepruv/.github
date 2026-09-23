import unittest

import ssm_to_env as s


def payload(**kv):
    return {"Parameters": [{"Name": f"/zepruv/staging/{k}", "Value": v} for k, v in kv.items()]}


class ConvertTests(unittest.TestCase):
    def test_sorted_and_single_quoted(self):
        out = s.convert(payload(B="2", A="p$ss w#rd"), "/zepruv/staging")
        self.assertEqual(out, ["A='p$ss w#rd'", "B='2'"])

    def test_rejects_single_quote_without_leaking_value(self):
        with self.assertRaises(s.EnvError) as cm:
            s.convert(payload(A="sec'ret"), "/zepruv/staging/")
        self.assertIn("/zepruv/staging/A", str(cm.exception))
        self.assertNotIn("sec", str(cm.exception))

    def test_rejects_newline(self):
        with self.assertRaises(s.EnvError):
            s.convert(payload(A="a\nb"), "/zepruv/staging/")

    def test_rejects_deploy_managed_names(self):
        for name in ("BACKEND_TAG", "ECR_REGISTRY", "APP_RELEASE", "IMAGE_TAG"):
            with self.assertRaises(s.EnvError, msg=name):
                s.convert(payload(**{name: "x"}), "/zepruv/staging/")

    def test_rejects_bad_names_and_nested(self):
        with self.assertRaises(s.EnvError):
            s.convert(payload(**{"bad-name": "x"}), "/zepruv/staging/")
        with self.assertRaises(s.EnvError):
            s.convert({"Parameters": [{"Name": "/zepruv/staging/a/b", "Value": "x"}]}, "/zepruv/staging/")

    def test_rejects_other_environment(self):
        with self.assertRaises(s.EnvError):
            s.convert({"Parameters": [{"Name": "/zepruv/prod/A", "Value": "x"}]}, "/zepruv/staging/")

    def test_min_keys_guard(self):
        with self.assertRaises(s.EnvError):
            s.convert(payload(A="1"), "/zepruv/staging/", min_keys=5)
        with self.assertRaises(s.EnvError):
            s.convert({"Parameters": []}, "/zepruv/staging/", min_keys=1)


if __name__ == "__main__":
    unittest.main()
