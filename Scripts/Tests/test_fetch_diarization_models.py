from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).parents[2]
SCRIPT = PROJECT / "Scripts" / "fetch-diarization-models.sh"
FETCHED = PROJECT / "ThirdParty" / "SpeakerDiarizationModels"
SERVICE = PROJECT / "Nook" / "Services" / "Speakers" / "SpeakerDiarizationService.swift"


def check(directory: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(SCRIPT), "--check", str(directory)],
        capture_output=True,
        text=True,
        check=False,
    )


def manifest_paths() -> list[str]:
    source = SCRIPT.read_text(encoding="utf-8")
    return re.findall(r'^\s+"[0-9a-f]{64} \d+ ([^"]+)"$', source, flags=re.MULTILINE)


class FetchDiarizationModelsTests(unittest.TestCase):
    """The check is what stops a build without speaker separation, so it has
    to reject anything but the exact pinned files, and never download."""

    def test_an_empty_folder_fails_the_check_and_says_how_to_fix_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = check(Path(directory))

        self.assertEqual(result.returncode, 1)
        self.assertIn("Run Scripts/fetch-diarization-models.sh", result.stderr)

    def test_a_missing_folder_fails_the_check(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = check(Path(directory) / "absent")

        self.assertEqual(result.returncode, 1)

    def test_unexpected_arguments_are_refused(self) -> None:
        for arguments in (["--fetch"], ["--check", "one", "two"]):
            result = subprocess.run(
                [str(SCRIPT), *arguments], capture_output=True, text=True, check=False
            )
            self.assertEqual(result.returncode, 64, arguments)

    def test_every_pinned_file_is_one_the_app_loads(self) -> None:
        paths = manifest_paths()
        top_level = {path.split("/")[0] for path in paths}
        service = SERVICE.read_text(encoding="utf-8")

        self.assertEqual(len(paths), len(set(paths)))
        self.assertEqual(
            top_level,
            {
                "Segmentation.mlmodelc",
                "FBank.mlmodelc",
                "Embedding.mlmodelc",
                "PldaRho.mlmodelc",
                "plda-parameters.json",
            },
        )
        for name in top_level:
            self.assertIn(f'"{name}"', service)

    @unittest.skipUnless(
        FETCHED.is_dir(), "Run Scripts/fetch-diarization-models.sh to test against the real files."
    )
    def test_the_fetched_models_pass_and_any_change_fails(self) -> None:
        self.assertEqual(check(FETCHED).returncode, 0)

        with tempfile.TemporaryDirectory() as directory:
            copy = Path(directory) / "Models"
            shutil.copytree(FETCHED, copy)
            self.assertEqual(check(copy).returncode, 0)

            (copy / ".DS_Store").write_bytes(b"extra")
            self.assertEqual(check(copy).returncode, 1)
            (copy / ".DS_Store").unlink()

            parameters = copy / "plda-parameters.json"
            original = parameters.read_bytes()
            parameters.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
            self.assertEqual(check(copy).returncode, 1)
            parameters.write_bytes(original)

            (copy / "FBank.mlmodelc" / "model.mil").unlink()
            self.assertEqual(check(copy).returncode, 1)


if __name__ == "__main__":
    unittest.main()
