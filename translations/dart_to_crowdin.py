import json
import ast
import os
import shutil


def process_dart_file(input_file):
    with open(input_file, "r", encoding="utf-8") as file:
        content = file.read()

    start = content.index("const crowdin = ")
    end = content.rindex("};")
    crowdin_json = content[start + len("const crowdin = ") : end + 1]
    crowdin_json = crowdin_json.replace("\\$", "$")

    crowdin_dict = ast.literal_eval(crowdin_json)

    for locale, translations in crowdin_dict.items():
        json_content = json.dumps(translations, ensure_ascii=False, indent=2)

        output_dir = os.path.join("./saturn", locale)
        os.makedirs(output_dir, exist_ok=True)
        output_file = os.path.join(output_dir, "saturn.json")

        with open(output_file, "w", encoding="utf-8") as file:
            file.write(json_content)

    # Zip the saturn folder
    shutil.make_archive("saturn", "zip", "./saturn")

    # Remove the saturn folder
    shutil.rmtree("./saturn")


# Usage
input_file = "../lib/languages/crowdin.dart"
process_dart_file(input_file)
