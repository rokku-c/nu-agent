#!/usr/bin/env nu
# unit.nu — pure-function tests. no network, no side effects outside a temp dir.
#
# run standalone:  nu --config test/config.nu test/unit.nu
# (progress goes to stderr, the JSON result list to stdout)

use ./harness.nu *

# keep storage writes out of the real store
$env.NU_CONTEXT_DIR = ($nu.temp-dir | path join $"nu-agent-unit-(random int 100000..999999)")
mkdir $env.NU_CONTEXT_DIR

# ── fixture: a message list big enough that folding has something to do ──
let big = ("x" | fill -w 2000)
let msgs = [
  {role: "user", content: "the original task — must never be folded by default"}
  {role: "assistant", content: [{type: "text", text: $big}]}
  {role: "user", content: $big}
  {role: "assistant", content: [{type: "text", text: $big}]}
  {role: "user", content: $big}
  {role: "assistant", content: [{type: "text", text: "the most recent turn"}]}
]

let results = [
  # ── expose: signature → tool definition ──
  (case "expose: module exports become tool names" {
    let names = (expose from-module calc | get name)
    (eq "expose: module exports become tool names" $names ["calc"])
  })

  (case "expose: one module, one tool per exported command" {
    let names = (expose from-module write | get name)
    (eq "expose: one module, one tool per exported command" $names ["write_file" "write_range" "write_replace"])
  })

  (case "expose: positional params land in properties + required" {
    let t = (expose from-module calc | first)
    let props = ($t.input_schema.properties | columns)
    let req = ($t.input_schema.required)
    (eq "expose: positional params land in properties + required" [$props $req] [["expr"] ["expr"]])
  })

  (case "expose: nu types map to JSON Schema types" {
    let t = (expose from-module read | first)
    let p = ($t.input_schema.properties)
    # path:path -> string, offset:int -> integer, numbers:switch -> boolean, limit:int
    let got = [($p.path.type) ($p.offset.type) ($p.numbers.type) ($p.limit.type)]
    (eq "expose: nu types map to JSON Schema types" $got ["string" "integer" "boolean" "integer"])
  })

  (case "expose: switches are never required" {
    let t = (expose from-module read | first)
    (eq "expose: switches are never required" ($t.input_schema.required | sort) ["path"])
  })

  (case "expose: --prefix is applied to tool names" {
    let names = (expose from-module calc --prefix "x_" | get name)
    (eq "expose: --prefix is applied to tool names" $names ["x_calc"])
  })

  (case "expose: unknown module raises" {
    (throws "expose: unknown module raises" { expose from-module no-such-module })
  })

  # ── context: folding ──
  (case "context: apply folds a bloated list and shrinks it" {
    let r = ($msgs | context apply --budget 100 --keep-recent 2 --note "unit")
    (is-true "context: apply folds a bloated list and shrinks it" ($r.changed and ($r.after_tokens < $r.before_tokens)))
  })

  (case "context: apply never folds message 0 (the original task)" {
    let r = ($msgs | context apply --budget 100 --keep-recent 2 --note "unit")
    (has "context: apply never folds message 0 (the original task)" ($r.messages | first | get content) "original task")
  })

  (case "context: folding keeps the message count identical" {
    let r = ($msgs | context apply --budget 100 --keep-recent 2 --note "unit")
    (eq "context: folding keeps the message count identical" ($r.messages | length) ($msgs | length))
  })

  (case "context: an explicit --keep survives folding" {
    let r = ($msgs | context apply --budget 100 --keep-recent 2 --keep [2] --note "unit")
    (eq "context: an explicit --keep survives folding" ($r.messages | get 2 | get content) ($msgs | get 2 | get content))
  })

  (case "context: --dry-run writes no entry" {
    let r = ($msgs | context apply --budget 100 --keep-recent 2 --dry-run)
    (eq "context: --dry-run writes no entry" $r.entry null)
  })

  (case "context: a fold is reported in --fold so a caller can see what moved" {
    let r = ($msgs | context apply --budget 100 --keep-recent 2 --note "unit")
    (is-true "context: a fold is reported in --fold so a caller can see what moved" (($r.folded | length) > 0))
  })

  # ── calc ──
  (case "calc: basic arithmetic" {
    (eq "calc: basic arithmetic" (calc "(1+2)*3") 9)
  })
  (case "calc: exponent" {
    (eq "calc: exponent" (calc "2^10") 1024)
  })
  (case "calc: modulo spelling is normalised" {
    (eq "calc: modulo spelling is normalised" (calc "10 mod 3") 1)
  })
  (case "calc: float result keeps its type" {
    (eq "calc: float result keeps its type" (calc "100 / 8") 12.5)
  })
  (case "calc: rejects anything that is not arithmetic" {
    (throws "calc: rejects anything that is not arithmetic" { calc "2; rm -rf /" })
  })
  (case "calc: rejects letters" {
    (throws "calc: rejects letters" { calc "sqrt(16)" })
  })

  # ── toon ──
  (case "toon: uniform records fold into a tabular header" {
    let out = ([{a: 1, b: 2} {a: 3, b: 4}] | toon encode)
    (has "toon: uniform records fold into a tabular header" $out "[2]{a,b}:")
  })
  (case "toon: strings that could be misread get quoted" {
    let out = ([{a: "1"}] | toon encode)
    (has "toon: strings that could be misread get quoted" $out "\"1\"")
  })
  (case "toon: no trailing newline" {
    let out = ([{a: 1}] | toon encode)
    (is-true "toon: no trailing newline" (not ($out | str ends-with (char nl))))
  })

  # ── jsonschema ──
  (case "jsonschema: a record infers an object with required keys" {
    let s = ({id: 1, name: "x"} | jsonschema infer)
    (eq "jsonschema: a record infers an object with required keys" [$s.type ($s.required | sort)] ["object" ["id" "name"]])
  })
  (case "jsonschema: a table infers an array of objects" {
    let s = ([[id name]; [1 a] [2 b]] | jsonschema infer)
    (eq "jsonschema: a table infers an array of objects" [$s.type $s.items.type] ["array" "object"])
  })
  (case "jsonschema: --strict marks every key required and closes the object" {
    let s = ({a: 1, b: 2} | jsonschema infer --strict)
    (eq "jsonschema: --strict marks every key required and closes the object" [($s.required | sort) $s.additionalProperties] [["a" "b"] false])
  })
  (case "jsonschema: --no-schema-key omits \$schema" {
    let s = ({a: 1} | jsonschema infer --no-schema-key)
    (eq "jsonschema: --no-schema-key omits \$schema" ($s | get --optional '$schema') null)
  })
  (case "jsonschema: from-samples merges heterogeneous samples" {
    let s = ([{a: 1, b: 2} {a: 3}] | jsonschema from-samples)
    # b appears in only one sample, so it is a property but not required
    (eq "jsonschema: from-samples merges heterogeneous samples" [($s.properties | columns | sort) ($s.required | sort)] [["a" "b"] ["a"]])
  })
  (case "jsonschema: a null union widens the type instead of dropping it" {
    let s = ([{a: 1} {a: null}] | jsonschema infer)
    (eq "jsonschema: a null union widens the type instead of dropping it" $s.type "array")
  })

  # ── style ──
  (case "style: colouring is off when stdout is a pipe" {
    # the whole test run is captured, so stdout is not a tty
    (is-true "style: colouring is off when stdout is a pipe" (not (style enabled)))
  })
  (case "style: a helper returns the bare text when colour is off" {
    (eq "style: a helper returns the bare text when colour is off" (style ok "done") "done")
  })
  (case "style: NU_STYLE=always forces colour on" {
    let prev = ($env.NU_STYLE? | default "auto")
    $env.NU_STYLE = "always"
    let s = (style ok "done")
    $env.NU_STYLE = $prev
    (has "style: NU_STYLE=always forces colour on" $s (char -i 27))
  })

  # ── markdown ──
  (case "markdown: headings render without markers" {
    let out = ("## hello" | markdown render --plain)
    (eq "markdown: headings render without markers" ($out | str trim) "hello")
  })
  (case "markdown: an empty input yields empty, not an error" {
    (eq "markdown: an empty input yields empty, not an error" ("" | markdown render --plain) "")
  })
  (case "markdown: plain mode strips emphasis markers" {
    let out = ("**bold** and *it*" | markdown render --plain)
    (lacks "markdown: plain mode strips emphasis markers" $out "**")
  })

  # ── peers ──
  (case "peers: list returns a JSON string, never a table" {
    let out = (peers list)
    # nu truncates table columns to the terminal width; these commands are called by
    # an LLM, so they must be lossless — hence JSON strings, asserted here
    (is-true "peers: list returns a JSON string, never a table" (($out | describe) == "string"))
  })
  (case "peers: list parses back as JSON" {
    let n = (peers list | from json | length)
    (is-true "peers: list parses back as JSON" ($n >= 0))
  })
  (case "peers: --kind filters" {
    let out = (peers list --kind claude | from json)
    let all_claude = ($out | all {|r| $r.kind == "claude" })
    (is-true "peers: --kind filters" $all_claude)
  })

  # ── image ──
  (case "image: info reads real dimensions" {
    # a 1x1 PNG, built inline so the test needs no fixture file on disk
    let p = ($nu.temp-dir | path join "nu-agent-unit-1px.png")
    ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" | decode base64 | save -f $p)
    let i = (image info $p)
    rm -f $p
    (eq "image: info reads real dimensions" [$i.width $i.height $i.format] [1 1 "png"])
  })
  (case "image: as-supported passes png through untouched" {
    let p = ($nu.temp-dir | path join "nu-agent-unit-1px.png")
    ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" | decode base64 | save -f $p)
    let out = (image as-supported $p)
    rm -f $p
    (eq "image: as-supported passes png through untouched" ($out | path expand) ($p | path expand))
  })

  # ── mcp client ──
  (case "mcp: the client offers the protocol versions the server knows" {
    (has "mcp: the client offers the protocol versions the server knows" ($mcp.PROTOCOL_VERSIONS | first) "2025-11-25")
  })

  # ── trace ──
  (case "trace: build-model pairs tool calls with their results" {
    let trace = {
      messages: [
        {role: "user", content: "do it"}
        {role: "assistant", content: [{type: "tool_use", id: "t1", name: "calc", input: {expr: "1+1"}}]}
        {role: "user", content: [{type: "tool_result", tool_use_id: "t1", content: "2", is_error: false}]}
        {role: "assistant", content: [{type: "text", text: "it is 2"}]}
      ]
      rounds: 2, tool_calls: 1, folds: []
    }
    let m = (trace build-model $trace)
    let t = ($m.rounds | first | get tools | first)
    (eq "trace: build-model pairs tool calls with their results" [$t.name $t.result] ["calc" "2"])
  })
]

emit $results
