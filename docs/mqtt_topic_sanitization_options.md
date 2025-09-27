# MQTT Topic Sanitization – problem analysis and alternatives

## Background

ESPHome currently keeps MQTT topics readable by copying ASCII letters, digits, dashes, and underscores while falling back to `_` for the rest.  The updated helpers extend this behaviour so that any well‑formed multi-byte UTF-8 sequence is preserved in the output, ensuring Cyrillic and other non-Latin names survive unchanged.【F:esphome/core/helpers.cpp†L360-L386】【F:esphome/helpers.py†L363-L373】

The guard that filters malformed sequences is implemented in C++ because we have to walk raw bytes.  Python mirrors the policy by checking the code point value and replacing disallowed characters with underscores.  Both sides aim to avoid maintaining a massive Unicode lookup table or hand-written decoder logic.

## Problem statement

The previous revision used a bespoke `decode_utf8` routine that manually enumerated every legal sequence length, leading to hard-to-review code and frustration when future adjustments were needed.  The requirement is to keep UTF-8 friendly names intact without reintroducing that long, low-level helper or other "big hammer" workarounds.

## Alternatives without long hacks

### 1. Leverage the standard library's UTF-8 facilities

* Use `std::mbrtoc32` (C++17) to convert each sequence into a `char32_t`, allowing us to call `std::iswalnum` or compare ranges without hand-written bit twiddling.
* The per-character loop becomes a handful of lines: convert bytes -> validate -> classify.  Python can still keep its `ord(value)` based check, so both sides stay in sync.
* Downsides: depends on locale-aware classification; embedded targets must have a C locale with usable wide-character tables, otherwise `std::mbrtoc32` falls back to single-byte behaviour.

### 2. Adopt a tiny header-only UTF-8 iterator

* Pull in a minimal header such as `utf8cpp` (permissive licence, ~200 LOC) and iterate over code points using `utf8::unchecked::next`.
* The sanitizer body reduces to `for (uint32_t cp : Utf8Range(str))` and a short `if`/`else` classification.  Invalid sequences raise an iterator error that we can map to `_`.
* Pros: keeps our own code terse and battle-tested; no locale dependency.  Cons: adds a new third-party header (but still tiny and easy to audit).

### 3. Simplify policy: allow every validated non-ASCII code point

* Keep the existing ASCII whitelist, but skip classification altogether for multi-byte sequences—once validation succeeds, append the bytes as-is.【F:esphome/core/helpers.cpp†L372-L379】
* This is the absolute minimum code (no lookup tables, no dependency) and mirrors the Python implementation's simple `ord(c) >= 0xC0` check.【F:esphome/helpers.py†L366-L372】
* Trade-off: symbols such as `§` or currency signs remain in topics, which may or may not be acceptable for users expecting strict MQTT naming.  If that is tolerable, this option is the cleanest.

### 4. Share a compact allow list generated at build time

* Generate a short list of Unicode blocks we want to keep (e.g. Cyrillic, Latin Extended) in a Python script and emit a small header with range tuples.
* The sanitizer then loops over `std::array<std::pair<char32_t, char32_t>>`, which stays maintainable because the source of truth is a script, not hand-written code.
* Advantage: precise control over which scripts are allowed without hand-maintained tables.  Disadvantage: still introduces a build step, but the runtime code remains tiny and readable.

## Recommendation

Pick option 1 if the toolchains guarantee functional wide-character support; otherwise, option 2 strikes a balance between readability and portability.  Option 3 is viable when MQTT brokers and downstream consumers accept a broader symbol set, while option 4 keeps strict filtering with a maintainable amount of code.
