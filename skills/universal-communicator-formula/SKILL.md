---
name: universal-communicator-formula
description: Build, update, debug, and optimize formula-based validation engines used in widget-driven applications. Use when the user says "create X validation", "add visibility handling", "add error widget updates", "make widget IDs configurable", "add dependent validation", "add CTA merging", "debug widget updates", "create complex validation engine", "add text replacement logic", or any request to generate or modify a formula for widget validation, visibility, CTA generation, or dynamic widget configuration.
---

# /universal-communicator-formula — build widget-driven formula validation engines

## What this is

Formulas are JavaScript snippets executed by the INDmoney widget engine to:
- Validate user input
- Update widget visibility
- Push error messages to error widgets
- Generate and merge CTAs
- Drive dynamic text replacement and structure updates

This skill generates complete, production-ready formulas from a description of requirements.

---

## Core response contract

Every formula must return one of:

```javascript
return JSON.stringify({ "is_valid": true,  "ctas": [] });
return JSON.stringify({ "is_valid": false, "ctas": [] });
```

The final line of every formula must be `return JSON.stringify(response);`.

---

## Formula design principles

### 1. Configuration-driven — prefer config over hardcoded values

```javascript
// Good
var config = {
    error_widget_id: 5,
    error_path: "widget_properties/lumpsum_note"
};

// Bad
var errorWidgetId = 5;
```

Keep widget IDs and paths in a top-level `config` object so callers can change them without touching logic.

### 2. Defensive parsing — always use safeParseFlexible

```javascript
function safeParseFlexible(str, key) {
    try {
        var parsed = JSON.parse(str);
        var val = key ? parsed[key] : parsed;
        if (typeof val === "object") return val;
        if (typeof val === "string") {
            try { return JSON.parse(val); } catch (e) { return null; }
        }
        return null;
    } catch (e) { return null; }
}
```

### 3. Widget update contract

```javascript
{
    widgetId: widgetId,
    widget_updates: [{ data: value, path: path }]
}
```

#### Path conventions — array indices use `###{N}###`, NOT bare `/N/`

When a `path` addresses an element inside an array (e.g. a `title[]`, `list[]`,
`left[]` entry), the index segment **must** be written as a `###{N}###` token.
A bare numeric segment is not parsed as an array index by the client resolver.

```text
✅  widget_properties/title/###{0}###/text
✅  widget_properties/left/###{1}###/primary/imgUrl/png
❌  widget_properties/title/0/text          ← will NOT resolve
```

Object-key segments stay plain (`widget_properties/visibility`); only array
indices get the token. This applies to every path the formula emits.

### 4. CTA contract

```javascript
{
    primary: {
        type: "widgetUpdater",
        widget_updates: updates
    }
}
```

### 5. CTA merge pattern — use when multiple CTA sources exist

```javascript
function mergeCtas(ctas) {
    var allUpdates = [];
    for (var i = 0; i < ctas.length; i++) {
        var cta = ctas[i];
        if (cta && cta.primary && cta.primary.type === "widgetUpdater") {
            var updates = cta.primary.widget_updates || [];
            for (var j = 0; j < updates.length; j++) allUpdates.push(updates[j]);
        }
    }
    return [{ primary: { type: "widgetUpdater", widget_updates: allUpdates } }];
}
```

### 6. Externalized config — inject config JSON through `variablesMap`

The cleanest production pattern keeps config OUT of the formula body entirely.
Config objects live as stringified JSON in `universal_widget_communication.inputs`,
are referenced in `variablesMap` via a `#key`, and are passed into the function
through the invocation line using the `'{"key":#key}'` wrapper:

```javascript
// invocation (last line of the formula)
mainFn(
    '{"checked":"#checked"}',                              // a raw input value
    '{"show_more_visibility_json":#show_more_visibility_json}'  // a config object (no quotes around #key)
);
```

- A **value** ref is quoted: `'{"checked":"#checked"}'` → parsed as `{ checked: "yes" }`.
- A **config-object** ref is NOT quoted: `'{"k":#k}'` → the engine splices the raw
  JSON object in, then `safeParseFlexible(str, "k")` unwraps it.

This lets product change widget IDs, paths, and copy by editing `inputs` /
`variablesMap` — never the formula. Prefer this over an in-body `config` literal
whenever the values are page-data (widget IDs, paths, display strings).

### 7. Inputs only populate `variablesMap` if the widget exposes them

A `#key` resolves to `""` unless the source widget actually emits that key.
For an input/selection widget, that means a `selection` (or `api_key`) block:

```json
"selection": { "api_key": "checked", "api_value": "yes" }
```

When generating a formula that reads `#foo`, always confirm (or flag) that the
driving widget carries `selection.api_key: "foo"` — otherwise the formula runs
but the value is silently empty. This is the #1 cause of a "formula does nothing"
report.

### 8. Canonical delivery shape — `universal_widget_communication` block

This is the EXACT production wrapper a formula ships inside. Whenever the user
asks for "the full block", "the communication block", or "how do I wire this",
emit this structure — never a bare formula string or an invented `validators`
key. Copy this shape verbatim and fill in the parts.

```json
"universal_widget_communication": {
  "inputs": {
    "amount_input": "0",
    "empty_check_json": "{\"error_widget_id\":69223,\"visibility_path\":\"widget_properties/visibility\",\"error_state\":\"visible\",\"valid_state\":\"gone\"}"
  },
  "input_validators": {
    "amount": {
      "formula": {
        "formula": "function mainValidator(amountInputStr, configStr){ ... return JSON.stringify(final);}mainValidator('{\"amount_input\":\"#amount_input\"}','{\"empty_check_json\":#empty_check_json}');",
        "variablesMap": {
          "#amount_input": "0",
          "#empty_check_json": "{\"error_widget_id\":69223,\"visibility_path\":\"widget_properties/visibility\",\"error_state\":\"visible\",\"valid_state\":\"gone\"}"
        }
      }
    }
  }
}
```

**Structure rules (memorize — this is the format that actually runs):**

1. **`inputs`** — a FLAT string map. Holds both raw input values (`"amount_input": "0"`)
   AND every config object as a **stringified JSON** (`"empty_check_json": "{...}"`).
   All values are strings.
2. **`input_validators`** — keyed by the driving input's **trigger api_key**
   (e.g. `"amount"`). This is the validation group, NOT the value key.
3. **`input_validators.<key>.formula`** — is an **object**, not a string.
4. **`input_validators.<key>.formula.formula`** — the JS as a single escaped
   string. It is a NAMED function (`mainValidator(...)`) whose **last line is the
   invocation** calling that function with the `'{"key":#key}'` wrappers.
5. **`input_validators.<key>.formula.variablesMap`** — lives INSIDE the `formula`
   object (sibling of the JS string), NOT at the block root. Every `#key` the
   invocation references must appear here with a default value.
6. **Invocation wrapper conventions** (last line of the JS):
   - value ref → quoted: `'{"amount_input":"#amount_input"}'`
   - config-object ref → NOT quoted: `'{"empty_check_json":#empty_check_json}'`
   - inline array config → `'[{"widget_id":1003,"path":"...","data":"#amount_input"}]'`
   - **NO straight single quote `'` in any spliced config value.** The `#key` is
     spliced into a `'...'`-wrapped JS string; a `'` inside a display string
     (e.g. `11th Jul'2026`) terminates the wrapper early → syntax error → engine
     returns `undefined`. Use the typographic apostrophe `’` (U+2019), reword to
     drop the apostrophe, or pass it as a separate value. This is a top cause of
     a "formula returns undefined" report even though the JS logic is correct.
7. **Duplication is expected**: a config object appears in BOTH `inputs` (top level)
   and the `formula.variablesMap` — keep them identical.
8. **Driving widget wiring** (Principle 7 still applies): the input widget must
   emit its value under the matching api_key via `selection`, and fire the
   validator with `validate_by` / the `input_validators` key.

### 9. Cross-engine safety — must compile on BOTH Rhino (Android) and JSC (iOS)

The SAME formula string runs on iOS (JavaScriptCore) and Android (Rhino). JSC is
permissive; Rhino — especially the older embedded builds shipped on many Android
devices — is stricter and will throw a compile error on things JSC silently
accepts. Every formula must be ES5-only and Rhino-clean:

| Rule | Do | Don't | Why Rhino breaks |
|---|---|---|---|
| **No reserved words as identifiers** | `var response`, `var res`, `var item` | `var final`, `var char`, `var goto`, `var enum`, `var class`, `var import`, `var export`, `var new`, `var native`, `var package` | Rhino treats Java/ES-future reserved words as reserved → `var final = {}` is a syntax error. JSC allows most. **`final` is the one that bites most often.** |
| **No `.trim()`** | `String(s).replace(/^\s+/, "").replace(/\s+$/, "")` (or a `trimStr()` helper) | `str.trim()` | `String.prototype.trim` is absent in older embedded Rhino. |
| **No `Array.isArray`** | `Object.prototype.toString.call(x) === "[object Array]"` or `x instanceof Array` | `Array.isArray(x)` | Missing on old Rhino. (`instanceof Array` works on both.) |
| **Guard `typeof null`** | `val !== null && typeof val === "object"` | `typeof val === "object"` alone | `typeof null === "object"` on both engines — the guard is correctness, not engine-specific, but Rhino JSON edge cases surface it. |
| **ES5 syntax only** | `var`, `function`, string concat `"a" + b` | `let` / `const`, arrow `=>`, template literals `` `${x}` ``, default params, destructuring, `for...of` | Old Rhino is ES5; these are parse errors. (JSC accepts them, so bugs only appear on Android.) |
| **No trailing commas** | `[a, b]`, `{x: 1}` | `[a, b,]`, `{x: 1,}` | Older Rhino rejects trailing commas in literals. |

Rule of thumb: write like it's 2010 JavaScript. If a construct is newer than ES5,
don't use it. `JSON`, `isNaN`, `Number`, `String`, `Math`, regex, `.replace`,
`.slice`, `.push`, `.concat`, `.indexOf` are all safe on both.

---

## Standard utility functions

Include these as needed — only include what the formula uses.

### Indian number formatter
Formats an integer into the Indian number system (last 3 digits, then groups of 2).
```javascript
function formatIndian(n) {
    var s = String(n);
    var lastThree = s.slice(-3);
    var rest = s.slice(0, -3);
    if (rest) {
        lastThree = "," + lastThree;
        rest = rest.replace(/\B(?=(\d{2})+(?!\d))/g, ",");
    }
    return "₹" + rest + lastThree;
}
// formatIndian(87552) → "₹87,552"
// formatIndian(1234567) → "₹12,34,567"
```

### Integer sanitizer
```javascript
function sanitizeToIntegerString(value) {
    if (value === null || value === undefined) return "0";
    var num = Number(value);
    if (isNaN(num)) return "0";
    return String(Math.floor(num));
}
```

### Rhino-safe trim (use instead of `.trim()`)
Old embedded Rhino on Android lacks `String.prototype.trim`. Use this everywhere
you would otherwise call `.trim()` (see Principle 9).
```javascript
function trimStr(s) {
    return String(s).replace(/^\s+/, "").replace(/\s+$/, "");
}
```

### Empty-or-zero check (required-amount validation)
Treats `null` / `undefined` / `""` / `"0"` / `0` as invalid. Rhino-safe.
```javascript
function isEmptyOrZero(value) {
    if (value === null || value === undefined) return true;
    var v = trimStr(value);
    if (v === "") return true;
    var num = Number(v);
    if (!isNaN(num) && num === 0) return true;   // "0", "0.0", 0
    return false;
}
```

### Standard name validator (alpha + space, max 50)
```javascript
function validateName(value) {
    if (!value) return { valid: false, error: "" };
    if (value.length > 50) return { valid: false, error: "Max 50 characters allowed" };
    if (!/^[a-zA-Z ]+$/.test(value)) return { valid: false, error: "Please enter valid name" };
    return { valid: true, error: "" };
}
```

### Checked-state normalizer (checkbox / toggle inputs)
A checkbox can emit its "selected" state in many shapes depending on the
template. Normalize them all to a boolean instead of comparing to one literal.
```javascript
function isChecked(value) {
    if (value === null || value === undefined) return false;
    var v = String(value).toLowerCase();
    return (v === "yes" || v === "true" || v === "1" ||
            v === "on"  || v === "checked" || v === "selected");
}
```

---

## Supported patterns

### Pattern 1 — Simple required validation
```javascript
var value = variablesMap["#fund"];
var isValid = value !== null && value !== undefined && value !== "";
return JSON.stringify({ is_valid: isValid, ctas: [] });
```

### Pattern 2 — Regex + length validation
```javascript
var config = { regex: "^[a-zA-Z ]+$", maxLength: 50, minLength: 1 };
var value = variablesMap["#input"] || "";
var isValid = value.length >= config.minLength
    && value.length <= config.maxLength
    && new RegExp(config.regex).test(value);
return JSON.stringify({ is_valid: isValid, ctas: [] });
```

### Pattern 3 — Error widget updates
```javascript
var config = { error_widget_id: 5, error_path: "widget_properties/lumpsum_note" };
var updates = [];
if (!isValid) {
    updates.push({
        widgetId: config.error_widget_id,
        widget_updates: [{ data: errorMessage, path: config.error_path }]
    });
}
```

### Pattern 4 — Visibility (single widget)
```javascript
var config = { widget_id: 3, path: "widget_properties/visibility" };
var visibility = isValid ? "visible" : "gone";
updates.push({
    widgetId: config.widget_id,
    widget_updates: [{ data: visibility, path: config.path }]
});
```

### Pattern 5 — Visibility (multi-widget, same state)
```javascript
var visibilityWidgets = [
    { widget_id: 3, path: "widget_properties/visibility" },
    { widget_id: 5, path: "widget_properties/visibility" }
];
for (var i = 0; i < visibilityWidgets.length; i++) {
    updates.push({
        widgetId: visibilityWidgets[i].widget_id,
        widget_updates: [{ data: visibility, path: visibilityWidgets[i].path }]
    });
}
```

### Pattern 6 — Dynamic text replacement
```javascript
// Template: "now ###{}### continue"
// widgetUpdateMap: { "lnt": "Hello" }
var fund = variablesMap["#fund"];
var widgetUpdateMap = { "lnt": "Hello" };
var replacement = widgetUpdateMap[fund] || "";
var text = template.replace("##{}##", replacement);
```

### Pattern 7 — Validation + visibility + error updates (combined)
All three run in a single formula. Compute `isValid`, then build `updates[]` for error widget, visibility widgets, and any other state widgets. Pass all updates into one CTA at the end.

### Pattern 8 — At-least-one validation
```javascript
var isValid = fatherValid || spouseValid;
```

### Pattern 9 — Dependent validation
```javascript
var maritalStatus = variablesMap["#marital_status"];
var isValid;
if (maritalStatus === "married") {
    isValid = validateName(variablesMap["#spouse_name"]).valid;
} else {
    isValid = validateName(variablesMap["#father_name"]).valid;
}
```

### Pattern 11 — Checkbox-driven toggle (visibility + text swap, externalized config)
A boolean checkbox that, when selected, reveals a target widget AND swaps a
label; when deselected, reverses both. Config is injected via `variablesMap`
(Principle 6), state is normalized via `isChecked` — no literals in the body.

```javascript
function showMoreToggle(checkedStr, visibilityConfigStr, titleConfigStr) {
    function safeParseFlexible(str, key) {
        try {
            var parsed = JSON.parse(str);
            var val = key ? parsed[key] : parsed;
            if (typeof val === "object") return val;
            if (typeof val === "string") { try { return JSON.parse(val); } catch (e) { return null; } }
            return null;
        } catch (e) { return null; }
    }
    function isChecked(value) {
        if (value === null || value === undefined) return false;
        var v = String(value).toLowerCase();
        return (v === "yes" || v === "true" || v === "1" || v === "on" || v === "checked" || v === "selected");
    }
    function mergeCtas(ctas) {
        var allUpdates = [];
        for (var i = 0; i < ctas.length; i++) {
            var c = ctas[i];
            if (c && c.primary && c.primary.type === "widgetUpdater") {
                var u = c.primary.widget_updates || [];
                for (var j = 0; j < u.length; j++) allUpdates.push(u[j]);
            }
        }
        if (allUpdates.length === 0) return [];
        return [{ primary: { type: "widgetUpdater", widget_updates: allUpdates } }];
    }

    var checked = "";
    try { checked = JSON.parse(checkedStr).checked || ""; } catch (e) {}
    var checkedFlag = isChecked(checked);

    var visCfg   = safeParseFlexible(visibilityConfigStr, "show_more_visibility_json");
    var titleCfg = safeParseFlexible(titleConfigStr,      "show_more_title_json");

    function visibilityCTA(cfg, on) {
        if (!cfg || !cfg.widget_id || !cfg.path) return [];
        var state = on ? (cfg.enabled_state || "visible") : (cfg.disable_state || "gone");
        return [{ primary: { type: "widgetUpdater", widget_updates: [{ widgetId: cfg.widget_id, widget_updates: [{ data: state, path: cfg.path }] }] } }];
    }
    function titleCTA(cfg, on) {
        if (!cfg || !cfg.widget_id || !cfg.path) return [];
        var text = on ? (cfg.selected_text || "") : (cfg.unselected_text || "");
        return [{ primary: { type: "widgetUpdater", widget_updates: [{ widgetId: cfg.widget_id, widget_updates: [{ data: text, path: cfg.path }] }] } }];
    }

    var allCtas = visibilityCTA(visCfg, checkedFlag).concat(titleCTA(titleCfg, checkedFlag));
    return JSON.stringify({ is_valid: true, ctas: mergeCtas(allCtas) });
}

showMoreToggle(
    '{"checked":"#checked"}',
    '{"show_more_visibility_json":#show_more_visibility_json}',
    '{"show_more_title_json":#show_more_title_json}'
);
```

Config objects (in `inputs` + `variablesMap`) — note the `###{0}###` array token
on the title path:
```json
{
  "show_more_visibility_json": "{\"widget_id\": 69694, \"path\": \"widget_properties/visibility\", \"enabled_state\": \"visible\", \"disable_state\": \"gone\"}",
  "show_more_title_json":      "{\"widget_id\": 69693, \"path\": \"widget_properties/title/###{0}###/text\", \"selected_text\": \"Show Less\", \"unselected_text\": \"Show More\"}"
}
```
Driving checkbox must carry `"selection": { "api_key": "checked", "api_value": "yes" }`
(Principle 7) and a `validate_by: ["<validator_name>"]` CTA to fire the formula.

### Pattern 12 — Multi-select array input: validate, sum amounts, icon toggle, title update

Used when items are selected via `UniversalSelectionManager` (multi-select chips/checkboxes).
The formula receives the selected values as an **array** — not a variablesMap string. Each
element is a JSON-encoded string (e.g. `"{\"id\":\"10001\",\"amount\":6727}"`).

**Invocation pattern** (no quotes, no JSON wrapper — engine splices the raw array):
```
validateInput(#checked);
```
`variablesMap: { "#checked": "" }` — the engine populates it with the current selection array.

**Contract:** `api_value` on each selectable item is a JSON string encoding the item's data.
`select_all.values` in `selection_data` lists every selectable value in the same format.

```javascript
function validateInput(input) {
    var config = {
        total_items: 8,                          // must match select_all.values.length
        select_all_widget_id: 1001,
        select_all_icon_path: "widget_properties/checkmark_icon_url",
        title_path: "widget_properties/title_text",
        checked_icon_value: "checkmark_icon_url_check",    // resolved by the template
        unchecked_icon_value: "checkmark_icon_url_uncheck"
    };

    function formatIndian(n) {
        var s = String(n);
        var lastThree = s.slice(-3);
        var rest = s.slice(0, -3);
        if (rest) {
            lastThree = "," + lastThree;
            rest = rest.replace(/\B(?=(\d{2})+(?!\d))/g, ",");
        }
        return "₹" + rest + lastThree;
    }

    var isValid = false;
    var isAllSelected = false;
    var totalAmount = 0;

    if (input instanceof Array && input.length > 0) {
        isValid = true;
        isAllSelected = input.length === config.total_items;
        for (var i = 0; i < input.length; i++) {
            try {
                var item = JSON.parse(input[i]);
                if (item && typeof item.amount === "number") {
                    totalAmount += item.amount;
                }
            } catch (e) {}
        }
    }

    var iconValue = isAllSelected
        ? config.checked_icon_value
        : config.unchecked_icon_value;

    var titleText = totalAmount > 0
        ? "Eligible funds (" + formatIndian(totalAmount) + ")"
        : "Eligible funds";

    var updates = [{
        widgetId: config.select_all_widget_id,
        widget_updates: [
            { data: iconValue, path: config.select_all_icon_path },
            { data: titleText, path: config.title_path }
        ]
    }];

    return JSON.stringify({
        is_valid: isValid,
        ctas: [{ primary: { type: "widgetUpdater", widget_updates: updates } }]
    });
}

validateInput(#checked);
```

**Key points:**
- `input instanceof Array` — the multi-select engine passes an array, not a string; guard before accessing `.length`.
- `input.length === config.total_items` — detects all-selected state without needing a sentinel; `total_items` must equal `select_all.values.length` in the server contract.
- `JSON.parse(input[i])` — each element is a JSON string; wrap in try/catch.
- Icon path value is a **template alias** (`checkmark_icon_url_check`), not a URL — the template resolves it to the actual URL via `widget_properties/checkmark_icon_url_check`.
- `is_valid: false` when `input` is empty or not an array (nothing selected).

**Driving selection_data config:**
```json
"selection_data": {
  "checked": {
    "is_multi_select": true,
    "allow_unselect": true,
    "select_all": {
      "api_value": "select_all",
      "values": [
        "{\"id\":\"10001\",\"amount\":6727}",
        "{\"id\":\"10002\",\"amount\":834}"
      ]
    }
  }
}
```
Widget 1001 must carry `"selection": { "api_key": "checked", "api_value": "select_all" }` so
the client routes the tap through `selectAll(forApiKey:)` and the formula fires with the full
values array.

---

### Pattern 10 — Complex validation engine (full template)

```javascript
// ─── CONFIG ─────────────────────────────────────────────────────────────────
var config = {
    fields: {
        father_name:   { input: "#father_name",   error_widget_id: 101, error_path: "widget_properties/error_text" },
        spouse_name:   { input: "#spouse_name",   error_widget_id: 102, error_path: "widget_properties/error_text" },
        loan_purpose:  { input: "#loan_purpose",  error_widget_id: 103, error_path: "widget_properties/error_text" },
        marital_status:{ input: "#marital_status" }
    },
    visibility: [
        { widget_id: 201, path: "widget_properties/visibility", show_when: "married", field: "marital_status" }
    ]
};

// ─── UTILITIES ───────────────────────────────────────────────────────────────
function safeParseFlexible(str, key) {
    try {
        var parsed = JSON.parse(str);
        var val = key ? parsed[key] : parsed;
        if (typeof val === "object") return val;
        if (typeof val === "string") { try { return JSON.parse(val); } catch(e) { return null; } }
        return null;
    } catch(e) { return null; }
}

function validateName(value) {
    if (!value) return { valid: false, error: "" };
    if (value.length > 50) return { valid: false, error: "Max 50 characters allowed" };
    if (!/^[a-zA-Z ]+$/.test(value)) return { valid: false, error: "Please enter valid name" };
    return { valid: true, error: "" };
}

function mergeCtas(ctas) {
    var allUpdates = [];
    for (var i = 0; i < ctas.length; i++) {
        var cta = ctas[i];
        if (cta && cta.primary && cta.primary.type === "widgetUpdater") {
            var u = cta.primary.widget_updates || [];
            for (var j = 0; j < u.length; j++) allUpdates.push(u[j]);
        }
    }
    return [{ primary: { type: "widgetUpdater", widget_updates: allUpdates } }];
}

// ─── INPUTS ──────────────────────────────────────────────────────────────────
var maritalStatus  = variablesMap[config.fields.marital_status.input] || "";
var fatherName     = variablesMap[config.fields.father_name.input]    || "";
var spouseName     = variablesMap[config.fields.spouse_name.input]    || "";
var loanPurpose    = variablesMap[config.fields.loan_purpose.input]   || "";

// ─── VALIDATION ──────────────────────────────────────────────────────────────
var fatherResult  = validateName(fatherName);
var spouseResult  = validateName(spouseName);
var purposeValid  = loanPurpose.length > 0;

var nameValid = maritalStatus === "married" ? spouseResult.valid : fatherResult.valid;
var isValid   = nameValid && purposeValid;

// ─── WIDGET UPDATES ──────────────────────────────────────────────────────────
var updates = [];

// Error updates
var nameResult = maritalStatus === "married" ? spouseResult : fatherResult;
var nameField  = maritalStatus === "married" ? config.fields.spouse_name : config.fields.father_name;
updates.push({
    widgetId: nameField.error_widget_id,
    widget_updates: [{ data: nameResult.error, path: nameField.error_path }]
});

// Visibility updates
for (var i = 0; i < config.visibility.length; i++) {
    var v = config.visibility[i];
    var fieldVal = variablesMap[config.fields[v.field].input] || "";
    var vis = fieldVal === v.show_when ? "visible" : "gone";
    updates.push({ widgetId: v.widget_id, widget_updates: [{ data: vis, path: v.path }] });
}

// ─── RESPONSE ────────────────────────────────────────────────────────────────
var response = {
    is_valid: isValid,
    ctas: updates.length > 0
        ? [{ primary: { type: "widgetUpdater", widget_updates: updates } }]
        : []
};
return JSON.stringify(response);
```

---

## Visibility config contract (recommended)

```json
{
  "note_widget_id": 1006,
  "input_widget_id": 1007,
  "edit_widget_id": 1008,
  "note_path": "widget_properties/visibility",
  "input_path": "widget_properties/visibility",
  "edit_path": "widget_properties/visibility",
  "enabled_state": "visible",
  "disable_state": "gone"
}
```

## Dynamic widget update config contract (recommended)

```json
[
  { "widget_id": 1003, "path": "widget_properties/amount_value", "data": "#amount_input" },
  { "widget_id": 1006, "path": "widget_properties/amount_value", "data": "#sip_amount_input" }
]
```

## Text-swap config contract (recommended)

For toggling a display string by state. Array-element paths use `###{N}###`.

```json
{
  "widget_id": 69693,
  "path": "widget_properties/title/###{0}###/text",
  "selected_text": "Show Less",
  "unselected_text": "Show More"
}
```

---

## How to use this skill

### Step 1 — identify the request type
- "Create X validation" → Pattern 1/2 + optionally 3
- "Add visibility" → Pattern 4/5
- "Add error widget" → Pattern 3
- "Add dependent validation" → Pattern 9
- "Add CTA merging" → Pattern 5 (mergeCtas)
- "Checkbox/toggle shows/hides or swaps text" → Pattern 11 (isChecked + externalized config)
- "Multi-select chips / select-all / sum amounts / icon toggle" → Pattern 12 (array input, JSON-encoded api_values, formatIndian)
- "Complex engine" → Pattern 10 template
- "Debug" → read existing formula, trace widget updates, check variablesMap keys

### Step 2 — ask for missing inputs (if not provided)
- Which variablesMap keys are the inputs? (e.g. `#pan_number`)
- Widget IDs and paths for error widgets and visibility targets
- Validation rules (regex, min/max length, required, dependent conditions)
- Existing formula to extend (if updating)

### Step 3 — generate the formula

Always output:
1. **Complete formula** — production-ready, copy-paste ready
2. **Full `universal_widget_communication` block** — the canonical delivery shape from Principle 8 (`inputs` + `input_validators.<key>.formula.formula` + nested `variablesMap`), with the JS escaped as a single string. This is what actually ships — always include it unless the user asks only for the raw JS.
3. **Required variablesMap** — list of all `#key` references and what they map to
4. **Config contract** — the top-level config object the caller must supply
5. **Backward compatibility notes** — if modifying an existing formula, flag any breaking changes

### Step 4 — debugging mode
If the user pastes a formula and reports broken behavior:
1. Trace every `widgetId` + `path` in `widget_updates` — are they correct?
2. Check variablesMap key names — exact string match required
3. Check `is_valid` logic — is the condition inverted?
4. Check CTA structure — must match `{ primary: { type: "widgetUpdater", widget_updates: [...] } }`
5. Check for duplicate widget updates (same `widgetId` + `path` pushed twice)
6. Check array-index path segments — must be `###{N}###`, not bare `/N/` (a `/0/` segment silently fails to resolve)
7. Check the driving widget exposes the input — a `#key` reads `""` unless that widget has `selection.api_key: "key"`
8. **POST body missing** — if a `type: "api"` CTA sends an empty body, check whether `request` has a `body` field. Without it the app sends no payload. Fix: add `"body": { "checked": "#checked" }` (or the relevant api_key). The `#key` in `body` uses the same variablesMap convention as the formula.
9. **Formula returns `undefined` (whole formula, not one field)** — a spliced config value contains a straight single quote `'` that closed the `'{"key":#key}'` wrapper early → syntax error before the function runs. Search every config string (in `inputs`/`variablesMap`) for a `'`; replace with `’` (U+2019) or reword. Symptom: logic is provably correct but the engine yields `undefined`. (Principle 8, rule 6.)


---

## Formula generation rules

1. Always return complete production-ready formula — no stubs or pseudocode
2. Preserve existing contract unless explicitly changed
3. Prefer reusable helper functions over inline logic
4. Keep widget IDs and paths in a top-level `config` object
5. Support future extensibility — avoid assumptions about fixed field counts
6. Avoid duplicate widget updates — dedupe by `widgetId + path` if needed
7. Merge CTAs using `mergeCtas()` whenever multiple CTA sources exist
8. Always end with `return JSON.stringify(response);`
9. Follow widgetUpdater contract exactly
10. Include only the utility functions the formula actually uses
11. Array-element paths MUST use the `###{N}###` index token, never a bare `/N/` segment
12. Prefer externalized config (injected via `variablesMap`, Principle 6) over in-body `config` literals when values are page-data (widget IDs, paths, copy)
13. When a formula reads a `#key`, confirm or flag that the driving widget carries `selection.api_key: "key"` (Principle 7)
14. Normalize checkbox/toggle state with `isChecked()` rather than comparing to a single literal
15. For `type: "api"` CTAs, always include a `body` field in the `request` object mapping api_key inputs to POST payload keys — without it the POST body is empty regardless of what's selected
16. For multi-select array formulas, guard with `input instanceof Array` before accessing `.length`; each element is a JSON-encoded string requiring `JSON.parse()` per item
17. `total_items` in the formula config must exactly match `select_all.values.length` in the server `selection_data` — a mismatch means "all selected" is never detected even when all chips are checked
18. Ship the formula inside the canonical `universal_widget_communication` block (Principle 8): `inputs` (flat string map, config objects stringified) + `input_validators.<trigger_api_key>.formula.formula` (named function whose last line invokes itself with `'{"k":#k}'` wrappers) + `input_validators.<key>.formula.variablesMap` (nested, sibling of the JS string — never at the block root). Never invent a `validators`/`formula_string` key.
19. Every formula must compile on BOTH Rhino (Android) and JSC (iOS) — ES5-only, no reserved words as identifiers (never `var final` → use `var response`), no `.trim()` (use `trimStr()`), no `Array.isArray` (use `instanceof Array`), no `let`/`const`/arrow/template-literals/trailing-commas (Principle 9)
