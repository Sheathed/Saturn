import zipfile
import json

lang_crowdin = {
    "ar": "ar-ar",
    "bg": "bul-bg",
    "ast": "ast-es",
    "de": "de-de",
    "el": "el-gr",
    "es-ES": "es-es",
    "fa": "fa-ir",
    "fil": "fil-ph",
    "fr": "fr-fr",
    "he": "he-il",
    "hr": "hr-hr",
    "id": "id-id",
    "it": "it-it",
    "ko": "ko-ko",
    "pt-BR": "pt-br",
    "ro": "ro-ro",
    "ru": "ru-ru",
    "tr": "tr-tr",
    "pl": "pl-pl",
    "uk": "uk-ua",
    "hu": "hu-hu",
    "ur-PK": "ur-pk",
    "hi": "hi-in",
    "sk": "sk-sk",
    "cs": "cs-cz",
    "vi": "vi-vi",
    "nl": "nl-NL",
    "sl": "sl-SL",
    "zh-CN": "zh-CN",
}


def generate_dart():
    out = {}
    with zipfile.ZipFile("translations.zip") as zip:
        for file in zip.namelist():
            if "saturn.json" in file:
                data = zip.open(file).read()
                lang = file.split("/")[0]
                out[lang_crowdin[lang]] = json.loads(data)

    with open("../lib/languages/crowdin.dart", "w") as f:
        data = json.dumps(out, ensure_ascii=False).replace("$", "\\$")
        out = f"const crowdin = {data};"
        f.write(out)


if __name__ == "__main__":
    generate_dart()
