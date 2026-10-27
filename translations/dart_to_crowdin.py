"""Export the app's English source and translated strings for Crowdin."""

import ast
import json
import re
import tempfile
import zipfile
from pathlib import Path

from crowdin import CROWDIN_LOCALE_TO_FOLDER


ROOT = Path(__file__).resolve().parent.parent
ENGLISH_DART = ROOT / "lib" / "languages" / "en_us.dart"
TRANSLATIONS_DART = ROOT / "lib" / "languages" / "crowdin.dart"
SOURCE_JSON = ROOT / "translations" / "saturn.json"
EXPORT_ZIP = ROOT / "translations" / "saturn.zip"


def _read_dart_map(path: Path, declaration: str) -> dict:
    content = path.read_text(encoding="utf-8")
    content = re.sub(r"(?m)^\s*//.*$", "", content)
    start = content.index(declaration) + len(declaration)
    end = content.rindex(";")
    dart_map = content[start:end].strip()
    dart_map = dart_map.replace(r"\$", "$")
    value = ast.literal_eval(dart_map)
    if not isinstance(value, dict):
        raise ValueError(f"Expected a Dart map in {path}")
    return value


def update_source_json() -> None:
    english = _read_dart_map(ENGLISH_DART, "const language_en_US = ")
    strings = english.get("en-US")
    if not isinstance(strings, dict):
        raise ValueError("language_en_US.dart does not contain an en-US map")
    SOURCE_JSON.write_text(
        json.dumps(strings, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def export_translations() -> None:
    translations = _read_dart_map(TRANSLATIONS_DART, "const crowdin = ")
    with tempfile.TemporaryDirectory(prefix="saturn-crowdin-") as temp_dir:
        staging = Path(temp_dir)
        with zipfile.ZipFile(EXPORT_ZIP, "w", zipfile.ZIP_DEFLATED) as archive:
            for crowdin_locale, strings in translations.items():
                folder = CROWDIN_LOCALE_TO_FOLDER.get(crowdin_locale.lower())
                if folder is None:
                    print(f"Skipping unsupported Crowdin locale: {crowdin_locale}")
                    continue
                if not isinstance(strings, dict):
                    raise ValueError(f"Expected translations for {crowdin_locale}")
                relative_path = Path(folder) / "saturn.json"
                staged_file = staging / relative_path
                staged_file.parent.mkdir(parents=True, exist_ok=True)
                staged_file.write_text(
                    json.dumps(strings, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8",
                )
                archive.write(staged_file, relative_path.as_posix())


def main() -> None:
    update_source_json()
    export_translations()
    print(f"Updated {SOURCE_JSON}")
    print(f"Wrote {EXPORT_ZIP}")


if __name__ == "__main__":
    main()
