import collections
import re
import zipfile
import json

lang_crowdin = {
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


def convert_to_single_quotes(json_str):
    def replace_quotes(match):
        key, value = match.groups()
        if "'" in key:
            key = f'"{key}"'
        else:
            key = f"'{key}'"
        if "'" in value:
            value = f'"{value}"'
        else:
            value = f"'{value}'"
        return f"{key}: {value}"

    def replace_locale_quotes(match):
        locale = match.group(1)
        return f"'{locale}': {{"

    pattern = r'"((?:[^"\\]|\\.)*)":\s*"((?:[^"\\]|\\.)*)"'
    single_quote_json = re.sub(pattern, replace_quotes, json_str)

    locale_pattern = r'"(\w+_\w+)":\s*{'
    single_quote_json = re.sub(locale_pattern, replace_locale_quotes, single_quote_json)

    return single_quote_json


# Run `dart fix --apply --code=prefer_single_quotes` in `saturn\lib\languages\` afterwards
def generate_dart():
    out = {}
    with zipfile.ZipFile("Saturn (translations).zip") as zip:
        files = sorted(zip.namelist())
        for file in files:
            if "saturn.json" in file:
                data = zip.open(file).read().decode("utf-8")
                lang = file.split("/")[0]
                if lang in lang_crowdin:
                    out[lang_crowdin[lang]] = json.loads(
                        data, object_pairs_hook=collections.OrderedDict
                    )

    with open("../lib/languages/crowdin_new.dart", "w", encoding="utf-8") as f:
        data = json.dumps(out, ensure_ascii=False, indent=2).replace("$", r"\$")
        single_quote_data = convert_to_single_quotes(data)
        out = f"const crowdin = {single_quote_data};"
        f.write(out)


if __name__ == "__main__":
    generate_dart()
