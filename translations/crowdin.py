"""Import a Crowdin translations ZIP into the app's Dart translation map."""

import argparse
import json
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ARCHIVE_CANDIDATES = (
    ROOT / "translations" / "translations.zip",
    ROOT / "translations" / "Saturn (translations).zip",
)
DEFAULT_ARCHIVE = next(
    (candidate for candidate in ARCHIVE_CANDIDATES if candidate.exists()),
    ARCHIVE_CANDIDATES[0],
)
OUTPUT_DART = ROOT / "lib" / "languages" / "crowdin.dart"

# Crowdin ZIP folder names mapped to the locale IDs used by the app.
FOLDER_TO_CROWDIN_LOCALE = {
    "ar": "ar-ar",
    "ast": "ast-es",
    "bg": "bul-bg",
    "cs": "cs-cz",
    "de": "de-de",
    "el": "el-gr",
    "es-ES": "es-es",
    "fa": "fa-ir",
    "fil": "fil-ph",
    "fr": "fr-fr",
    "he": "he-il",
    "hi": "hi-in",
    "hr": "hr-hr",
    "hu": "hu-hu",
    "id": "id-id",
    "it": "it-it",
    "ko": "ko-ko",
    "nl": "nl-nl",
    "pl": "pl-pl",
    "pt-BR": "pt-br",
    "ro": "ro-ro",
    "ru": "ru-ru",
    "sk": "sk-sk",
    "sl": "sl-sl",
    "tr": "tr-tr",
    "uk": "uk-ua",
    "ur-PK": "ur-pk",
    "vi": "vi-vi",
    "zh-CN": "zh-cn",
}
CROWDIN_LOCALE_TO_FOLDER = {
    locale: folder for folder, locale in FOLDER_TO_CROWDIN_LOCALE.items()
}


def _locale_from_archive_path(name: str) -> str | None:
    parts = Path(name).parts
    for part in reversed(parts[:-1]):
        if part in FOLDER_TO_CROWDIN_LOCALE:
            return FOLDER_TO_CROWDIN_LOCALE[part]
        normalized = part.lower()
        for locale in CROWDIN_LOCALE_TO_FOLDER:
            if normalized == locale.lower():
                return locale
    return None


def generate_dart(
    archive_path: Path = DEFAULT_ARCHIVE,
    output_path: Path = OUTPUT_DART,
) -> None:
    translations = {}
    with zipfile.ZipFile(archive_path) as archive:
        for name in sorted(archive.namelist()):
            if Path(name).name != "saturn.json":
                continue
            locale = _locale_from_archive_path(name)
            if locale is None:
                print(f"Skipping unrecognized locale in archive: {name}")
                continue
            with archive.open(name) as source:
                data = json.load(source)
            if not isinstance(data, dict):
                raise ValueError(f"Expected a JSON object in {name}")
            translations[locale] = data

    serialized = json.dumps(translations, ensure_ascii=False, indent=2)
    serialized = serialized.replace("$", r"\$")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(f"const crowdin = {serialized};\n", encoding="utf-8")
    print(f"Imported {len(translations)} locales into {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "archive",
        nargs="?",
        type=Path,
        default=DEFAULT_ARCHIVE,
        help=f"Crowdin translation archive (default: {DEFAULT_ARCHIVE})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=OUTPUT_DART,
        help=f"Dart output file (default: {OUTPUT_DART})",
    )
    args = parser.parse_args()
    generate_dart(args.archive, args.output)


if __name__ == "__main__":
    main()
