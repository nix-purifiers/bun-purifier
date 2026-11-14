# SPDX-License-Identifier: MIT
#
# Reads bun.lock. bun writes it as JSON with trailing commas, which
# builtins.fromJSON refuses, so the text is split into its strings and the
# rest, every comma that only whitespace separates from a closing bracket
# or brace is dropped from the rest, and the result is parsed as JSON.
# Commas inside strings are never touched.
file:
let
  text = builtins.readFile file;

  # builtins.split alternates the text between matches with a list per
  # match. A JSON string is a quote, then characters that are neither a
  # quote nor a backslash or are escaped by a backslash, then a quote.
  parts = builtins.split "(\"([^\"\\\\]|\\\\.)*\")" text;

  withoutTrailingCommas =
    segment:
    builtins.concatStringsSep "" (
      map (part: if builtins.isList part then builtins.concatStringsSep "" part else part) (
        builtins.split ",([[:space:]]*[]}])" segment
      )
    );

  json = builtins.concatStringsSep "" (
    map (part: if builtins.isList part then builtins.head part else withoutTrailingCommas part) parts
  );
in
builtins.addErrorContext "bun-purifier: reading ${toString file}, which bun writes as JSON with trailing commas" (
  builtins.fromJSON json
)
