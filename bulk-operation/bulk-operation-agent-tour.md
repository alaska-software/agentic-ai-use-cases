# Bulk Operation Agent — Annotated Code Tour

**Who this is for:** Any line-of-business developer who is comfortable reading Xbase++
code and knows how database operations work in a business context — regardless of domain.
If you want to understand how the `BulkOperationAgent` example works and adapt it to your
own system, this tour is for you.

**How to use this document:** Read it with the three source files open beside it.
The document always points at real, complete code. There is nothing to build.

**Files covered:**

| File | Role |
|---|---|
| `bulk-operation-common.prg` | Domain types, tool classes, schema contributor, personas |
| `bulk-operation-agent.prg` | The agent: flow declaration, all actions, all guards |
| `bulk-operation-main.prg` | Driver: connect to Northwind, run five tasks, report outcomes |

---

## Before You Read Anything: Run the Agent

Open a terminal in the `examples\` directory, set your Anthropic API key, then run:

```bat
call apikey.bat
bulk-operation.exe
```

This runs the five tasks from `bulk-operation-tasks-en.config` (the default). Pass
`bulk-operation-tasks-de.config` as the only argument to run the identical five tasks
in German instead — no other change needed, the agent already detects the request
language and replies in kind.

The agent connects to a PostgreSQL Northwind database and runs five tasks interactively.
For each task it shows a proposed change table, an optional analyst assessment, and a
Y / R / A prompt. Below is an abbreviated session — Task 1 approved on the first try,
Task 2 following without an assessment block:

```
Connected to Northwind Traders database.

========================================================================
Task 1 of 5
========================================================================
Increase the unit price of the top 5 best-selling products by revenue
in 2025 by 10%. Round each new price to the nearest $0.50.
------------------------------------------------------------------------
    [claude-haiku-4-5  in:387 out:42 tokens]
    [claude-sonnet-4-6  in:2846 out:631 tokens]
    [claude-sonnet-4-6  in:1924 out:398 tokens]

========================================================================
  PROPOSED BULK OPERATION
========================================================================
  Summary : 10% price increase on top 5 products by 2025 revenue, rounded to $0.50
  SQL file: price_increase_top5_revenue_2025.sql
------------------------------------------------------------------------
  #  Description                            Old Value    New Value
------------------------------------------------------------------------
   1. Atlantic Tuna Loin (productid=157)        98.14       108.00
   2. Thüringer Rostbratwurst (productid=29)   123.79       136.00
   3. Parma Bratwurst (productid=169)           74.89        82.50
   4. Mishi Kobe Niku (productid=9)             97.00       107.00
   5. Nutriva Turmeric Blend (productid=105)    40.22        44.00
------------------------------------------------------------------------
  5 change(s)
========================================================================
------------------------------------------------------------------------
  ANALYST ASSESSMENT  [+] POSITIVE
------------------------------------------------------------------------
  Impact  : +$14,200 projected annual revenue after ~8% demand suppression
  Pattern : Price elasticity (premium specialty products; >5% increase)
  These five products represent Northwind's highest-revenue earners. A 10%
  increase is within normal pricing-power range for specialty goods. Demand
  suppression of ~8% is estimated; net revenue gain remains strongly positive.
  Monitor Atlantic Tuna Loin: highest price point, highest elasticity risk.
------------------------------------------------------------------------

  Options:
    Y  -  approve and write SQL to disk
    R  -  reject and provide correction guidance (retry)
    A  -  abort and skip to the next task

  Your choice (Y / R / A): Y
  -> Approved.

------------------------------------------------------------------------
  SQL file written successfully
------------------------------------------------------------------------
  File      : price_increase_top5_revenue_2025.sql
  Statements: 5
  File 'price_increase_top5_revenue_2025.sql' written successfully
------------------------------------------------------------------------

========================================================================
Task 2 of 5
========================================================================
Mark as discontinued (set discontinued = 1) all products supplied by
supplier ID 3 that have never appeared in any order in the entire order history.
------------------------------------------------------------------------
    [claude-haiku-4-5  in:381 out:38 tokens]
    [claude-sonnet-4-6  in:2194 out:512 tokens]

========================================================================
  PROPOSED BULK OPERATION
========================================================================
  Summary : Discontinue supplier-3 products with no order history
  SQL file: discontinue_supplier3_unordered.sql
------------------------------------------------------------------------
  #  Description                            Old Value    New Value
------------------------------------------------------------------------
   1. Spegesild (productid=74)                       0            1
   2. Longlife Tofu (productid=74)                   0            1
------------------------------------------------------------------------
  2 change(s)
========================================================================

  Options:
    Y  -  approve and write SQL to disk
    ...
```

(Tasks 3–5 follow. Task 3 demonstrates the rejection-and-retry path. Task 4 shows the
stock critic block. Task 5 is another price change.)

> **No API key yet?** The agent will still run. Every task will fail inside `classify` and
> land at the `failed` terminal, printing `Error:` in `RunTask()`. That is the
> `RECOVER USING oErr` path working correctly — one failed task does not stop the
> remaining four. Get an Anthropic key from
> [console.anthropic.com](https://console.anthropic.com), put it in `apikey.bat`, and
> re-run. See also Part 7 — When Things Go Wrong.

---

## Part 1 — The Big Picture

### What This Agent Automates

A business user types a natural-language instruction such as
"Increase the unit price of the top 5 best-selling products by 10% and round to the
nearest $0.50" into a console. The `BulkOperationAgent` then:

1. Classifies the request type (price change, stock order, or other) and detects its
   natural language in a single cheap LLM call
2. Queries the live Northwind database autonomously to find the exact affected rows and
   their current values — the LLM drives these queries through the tool-calling loop
3. Computes the new values as specified (percentage, rounding rules, filters)
4. Proposes up to 10 SQL UPDATE statements as a reviewable change table
5. Optionally adds an advisory assessment — revenue impact for price changes, stock
   coverage for stock orders
6. Asks the user to approve, reject with feedback, or abort
7. On approval: writes a transaction-wrapped `.sql` file to disk, ready to execute
8. On rejection: merges the original request with the user's correction into one new,
   complete, standalone task description and re-analyzes from scratch

Steps 2, 3, and 5 involve the LLM calling `ExecuteQuery` against the live database.
Steps 6 and 7 involve no LLM at all.

### How the Agent Makes Decisions

**The happy path** — a price-change request, approved on the first try:

```
  classify ──► analyze ──► critic_price ──► review ──► write_sql ★
```

**The complete flow with all branches:**

```
  classify
     │ (LLM: Haiku, no tools — detect category + language)
     ▼ NIL guard
  analyze
     │ (LLM: Sonnet + NorthwindBulkQueryTool — query live DB, compute, propose)
     ├──[IsPriceChange]──────────────────────────────► critic_price
     │                                                      │ (LLM: Sonnet + tool)
     ├──[IsStockOrder]───────────────────────────────► critic_stock
     │                                                      │ (LLM: Sonnet + tool)
     └──[NIL]─────────────────────────────────────────┐     │
                                                      ▼     ▼
                                                   review (no LLM)
                                                      │
              ┌─────────────────────────────┬──────────┼──────────────────────────┐
              ▼                             ▼          ▼                          ▼
   [IsApproved]                   [IsAborted]  [IsExhausted]    [isRetryFor "approval"]
    write_sql ★                   aborted ★     failed ★            merge_request
                                                             (LLM: Haiku, no tools)
                                                                        │ NIL guard
                                                                        ▼
                                                                    analyze ◄──── (loop)

  ★ = terminal state (agent stops and returns the blackboard)
```

**Two things that make this flow different from a simple retry loop:**

1. `classify` runs **once**, before `analyze`. The category and language it places on
   the blackboard persist through every retry iteration. Guards `IsPriceChange` and
   `IsStockOrder` always read from that one persistent classification — never from a
   re-run of `classify`.

2. On rejection the agent does **not** re-run `analyze` with the original request plus
   an injected error message. Instead `merge_request` runs first. It takes the current
   effective task and the user's correction and produces a single, new, standalone task
   description. `analyze` then uses that clean merged request — it never sees the
   original and the correction at the same time.

### The Five Tasks

**Northwind database** (extended from the standard Northwind schema, PostgreSQL)

Key tables used: `products`, `categories`, `suppliers`, `orders`, `order_details`

Key columns that bulk operations target: `unitprice`, `unitsinstock`, `unitsonorder`, `discontinued`

**Agent settings**

| Setting | Value | Meaning |
|---|---|---|
| `maxAttempts` | 3 | Max times `analyze` may run before `failed` terminal |
| Default LLM | Sonnet 4.6, temp 0 | Used by `analyze`, `critic_price`, `critic_stock` |
| Classify / Merge LLM | Haiku 4.5, temp 0 | Fast and cheap; no database access needed |

**The five example tasks**

| # | Request | Category | Critic | What it exercises |
|---|---|---|---|---|
| T1 | 10% price increase, top 5 by 2025 revenue, round to $0.50 | price_change | PriceCritic | Tool calling, revenue-impact projection |
| T2 | Discontinue supplier-3 products with no order history | other | none | No critic block; direct path to review |
| T3 | 15% price reduction, Seafood category, 2 decimal places | price_change | PriceCritic | Price-decrease elasticity; rejection-and-retry |
| T4 | +100 stock for 5 lowest-stocked active products | stock_order | StockCritic | Coverage-months projection |
| T5 | Set price = 9.99 for supplier-1 products in $10–$12 band | price_change | PriceCritic | Flat override with price-band filter |

---

## Part 2 — Follow One Task Through the Code

> **Our task for Part 2:**
>
> `"Increase the unit price of the top 5 best-selling products by revenue in 2025 by 10%. Round each new price to the nearest $0.50."`
>
> This is T1 — price change, full pipeline with the price critic, approved on the first
> try, terminates at `write_sql`.

### The Blackboard

Every agent run has an `AgentContext`. Think of it as a named clipboard that travels
through all the states. Each state reads what it needs and writes its result back.

`oCtx:set( "key", value )` — write; `oCtx:get( "key" )` — read; `oCtx:has( "key" )` — test.

At the start, the blackboard has exactly one entry:

```
Blackboard
  request  →  "Increase the unit price of the top 5 best-selling products
               by revenue in 2025 by 10%. Round each new price to the nearest $0.50."
```

---

### Loading the Task — `bulk-operation-main.prg`

```xbase
PROCEDURE Main( cConfigFile )
   ...
   DEFAULT cConfigFile TO "bulk-operation-tasks-en.config"
   oAgent := BulkOperationAgent():New( oSession )
   ...
   aTasks := LoadBulkTasks( cConfigFile )
   FOR nI := 1 TO Len( aTasks )
      RunTask( oAgent, aTasks[nI]:text )
   NEXT
```

`BulkOperationAgent():New( oSession )` is called **once** before the loop. The same
agent instance handles all five tasks. Each task gets a **fresh** `AgentContext`, so the
blackboard resets completely between tasks even though the agent object — and its shared
`::oQueryTool` — is reused.

The five tasks are no longer a hardcoded array: `LoadBulkTasks()` (in
`bulk-operation-common.prg`) reads them from an external XML config file —
`bulk-operation-tasks-en.config` by default, or `bulk-operation-tasks-de.config`
for the identical five scenarios in German — using the same `MemoRead()` +
`XmlSimpleParser()` idiom as `ap-invoice`'s `LoadInvoiceSources()`. The loader
itself never branches on language; only the declared `<?xml encoding="..."?>`
prolog and the file's content differ between the two variants.

```xbase
PROCEDURE RunTask( oAgent, cTask )
   LOCAL oCtx := AgentContext():New()
   oCtx:set( "request", cTask )
   oMachine := AgentStateMachine():forAgent( oAgent )
   oMachine:run( oCtx )
   ...
```

The `BEGIN SEQUENCE … RECOVER USING oErr` in `RunTask()` catches any unhandled error
from any state — if the LLM call fails hard, the error is printed and the loop
advances to the next task.

---

### State 1: `classify` — Label the Request Cheaply

**What this step does:** A single Haiku call with no database access. Puts a persistent
`OperationClassification` on the blackboard. Runs exactly once — its result is never
re-examined or overwritten, even when `analyze` runs three times.

```xbase
METHOD BulkOperationAgent:classify( oCtx )
   LOCAL cRequest := oCtx:get( "request" )

   oRunner := oCtx:ai() ;
              :withLLM( LLMOptions():withModel( AnthropicModels():CLAUDE_HAIKU_4_5 ):withTemperature( 0 ) ) ;
              :withPromptContributor( BulkOperationPersonas():classifier() ) ;
              :withPromptContributor( Instruction():create( ;
                 "Classify the request into exactly one category:" + CRLF + ;
                 "  price_change : any modification to the unitprice column" + CRLF + ;
                 "  stock_order  : any modification to unitsinstock or unitsonorder" + CRLF + ;
                 "  other        : everything else ..." + CRLF + ;
                 "Also detect the natural language of the request text and " + CRLF + ;
                 "return it in the language field (e.g. 'English', 'German')." ) )

   oResult := oRunner:createObject( cRequest, "OperationClassification" )
```

**Why Haiku?** The only job here is column-type recognition from a text description.
No database access is needed, no arithmetic is performed. Haiku handles this in under
50 output tokens at a fraction of Sonnet's cost.

**`oCtx:ai()`** returns a `PromptRunner` pre-loaded with the agent's default LLM
(Sonnet 4.6, temp 0) and default persona (`Analyst`). `:withLLM()` overrides both
model and temperature to Haiku for this one call only — no other state is affected.

**Language detection.** The same `Instruction` contributor asks the LLM to detect the
natural language of the request and put it in the `language` field. This detection
feeds every subsequent LLM call: `critic_price` and `critic_stock` prepend
`"Respond in " + cLanguage + "."`, and `merge_request` does the same. One detection
in `classify` drives consistent language across the entire run — the agent works equally
well in English and German without any other code change.

**Blackboard after `classify`:**

```
Blackboard
  request        →  "Increase the unit price of the top 5..."
  classification →  OperationClassification
                      category : "price_change"
                      language : "English"
```

The NIL guard in `onRegister()` routes `classify` unconditionally to `analyze`:

```xbase
::addState( "classify", "Classify", "request", "classification" ) ;
   :onGuard( NIL, "analyze" )
```

---

### State 2: `analyze` — Query the Database and Compute the Changes

**What this step does:** The Sonnet model uses `ExecuteQuery` to interrogate the live
database, computes the new values as specified in the request, and returns a structured
`ProposedChangeSet`. This is the core of the agent — the LLM makes one or more tool
calls before returning its final structured answer.

```xbase
METHOD BulkOperationAgent:analyze( oCtx )
   LOCAL cRequest := If( oCtx:has( "activeRequest" ), ;
                        oCtx:get( "activeRequest" ), ;
                        oCtx:get( "request" ) )

   oRunner := oCtx:ai() ;
              :withPromptContributor( BulkSchemaContributor():New() ) ;
              :withPromptContributor( Instruction():create( ;
                 "You are PLANNING a bulk database update -- not executing it." + CRLF + ;
                 "Follow these steps exactly:" + CRLF + ;
                 "  1. Use ExecuteQuery one or more times to SELECT the affected records." + CRLF + ;
                 "  2. Compute the exact new values as the request specifies." + CRLF + ;
                 "  3. After all queries are complete, respond with a ProposedChangeSet." + CRLF + ;
                 ... ) ) ;
              :withTool( ::oQueryTool )

   oResult := oRunner:createObject( cRequest, "ProposedChangeSet" )
```

**First pass vs. retry.** On the first pass `oCtx:has( "activeRequest" )` is `.F.` —
the original request is used directly. On a retry, `activeRequest` holds the merged
task written by `merge_request` and is used instead. The `Analyze` method itself never
needs to know which pass it is on; the sentinel is the presence or absence of the key.

**The tool-calling loop.** `:withTool( ::oQueryTool )` is what makes `analyze` a
tool-aware call. `PromptRunner:getMessageSender()` returns a `ToolAwareSender` when
`toolObjects` is non-empty. The Sonnet model can call `ExecuteQuery` as many times as
it needs before committing to a `ProposedChangeSet` answer. For T1, one query is
sufficient:

```
LLM → ExecuteQuery
  "SELECT p.productid, p.productname, p.unitprice,
          SUM(od.unitprice * od.quantity * (1 - od.discount)) AS revenue
   FROM products p
   JOIN order_details od ON p.productid = od.productid
   JOIN orders o ON od.orderid = o.orderid
   WHERE EXTRACT(year FROM o.orderdate) = 2025
   GROUP BY p.productid, p.productname, p.unitprice
   ORDER BY revenue DESC LIMIT 5"

Tool result: { columns: ["productid","productname","unitprice","revenue"],
               rows: [[157,"Atlantic Tuna Loin",98.14,41280.00],
                      [29,"Thüringer Rostbratwurst",123.79,38940.00],
                      [169,"Parma Bratwurst",74.89,29410.00],
                      [9,"Mishi Kobe Niku",97.00,27650.00],
                      [105,"Nutriva Turmeric Blend",40.22,18920.00]],
               rowCount: 5 }

LLM computes new prices and returns ProposedChangeSet:
  98.14  * 1.10 = 107.954 → round to nearest 0.50 → 108.00
  123.79 * 1.10 = 136.169 → 136.00
  74.89  * 1.10 = 82.379  → 82.50
  97.00  * 1.10 = 106.70  → 107.00
  40.22  * 1.10 = 44.242  → 44.00
```

**The security gate in `NorthwindBulkQueryTool`.** The tool accepts only SQL that
starts with `SELECT` or `WITH`. Any attempt to run an `UPDATE`, `INSERT`, or `DELETE`
during the planning phase is rejected with an error string that is fed back to the LLM
as a tool result, prompting the model to rewrite the query:

```xbase
IF Upper( Left( cSql, 6 ) ) != "SELECT" .AND. Upper( Left( cSql, 4 ) ) != "WITH"
   RETURN "Error: Only SELECT statements and CTEs (WITH...SELECT) are allowed."
ENDIF
```

Results are also capped at 50 rows by appending `LIMIT 50` when the query contains
no `LIMIT` clause.

**`BulkSchemaContributor`** injects the full Northwind table structure into the system
prompt. The LLM learns which columns exist (`unitprice`, `unitsinstock`, …), how to
join `order_details` to `orders`, and that the PostgreSQL cast operator must be escaped
as `\\::`. Without this contributor the model would hallucinate column names or generate
syntactically invalid SQL.

**The shared `::oQueryTool`.** `NorthwindBulkQueryTool` is created once in
`BulkOperationAgent:init()` and stored as `::oQueryTool`. Both critic states reuse the
same instance. The `DacSession` inside the tool is safely shared across sequential
state calls because the states run one at a time — there is no concurrent access.

**Blackboard after `analyze`:**

```
Blackboard
  request        →  "Increase the unit price..."
  classification →  OperationClassification( category: "price_change", language: "English" )
  proposal       →  ProposedChangeSet
                      summary    : "10% price increase on top 5 products by 2025 revenue,
                                    rounded to nearest $0.50"
                      outputFile : "price_increase_top5_revenue_2025.sql"
                      changes    : [
                        { description: "Atlantic Tuna Loin (productid=157)",
                          oldValue: 98.14, newValue: 108.00,
                          updateSql: "UPDATE products SET unitprice = 108.00
                                      WHERE productid = 157;" },
                        ... (4 more)
                      ]
```

Guard `IsPriceChange` reads `classification:category == "price_change"` → `.T.` →
routes to `critic_price`.

---

### State 3: `critic_price` — An Independent Revenue Assessment

**What this step does:** A second Sonnet + tool call, completely independent of
`analyze`. The critic queries 12 months of sales history for the affected products,
projects the revenue impact, applies standard business patterns, and returns a
`CriticAssessment`. This output is advisory only — it does not gate the flow, it does
not modify the proposal. The NIL guard on `critic_price` routes unconditionally to
`review`.

```xbase
METHOD BulkOperationAgent:critiquePrice( oCtx )
   LOCAL oProposal := oCtx:get( "proposal" )
   LOCAL cLanguage := oCtx:get( "classification" ):language

   oRunner := oCtx:ai() ;
              :withPromptContributor( BulkOperationPersonas():priceCritic() ) ;
              :withPromptContributor( Instruction():create( ;
                 "Respond in " + cLanguage + "." + CRLF + ;
                 "STEP 1 — Query sales history for the last 12 months..." + CRLF + ;
                 "STEP 2 — Project direct revenue impact..." + CRLF + ;
                 "STEP 3 — Apply the dominant business pattern..." + CRLF + ;
                 "STEP 4 — Return CriticAssessment" ) ) ;
              :withTool( ::oQueryTool )

   oResult := oRunner:createObject( ;
                 "Assess this proposed price change:" + CRLF + Var2Json( oProposal ), ;
                 "CriticAssessment" )
```

`cLanguage` comes from the persistent `classification` on the blackboard — not from the
current request text. The classify step detected it once; every subsequent LLM call uses it.

**What the critic LLM does for T1:**

```
LLM → ExecuteQuery (12-month sales history for the five affected products)
  "SELECT p.productid, p.productname,
          SUM(od.quantity) AS units_sold,
          SUM(od.unitprice * od.quantity * (1 - od.discount)) AS revenue
   FROM products p
   JOIN order_details od ON p.productid = od.productid
   JOIN orders o ON od.orderid = o.orderid
   WHERE o.orderdate >= NOW() - INTERVAL '12 months'
     AND p.productid IN (157, 29, 169, 9, 105)
   GROUP BY p.productid, p.productname"

LLM applies pattern and returns CriticAssessment:
  direct_impact = (108.00 - 98.14) * 4,195 + ... ≈ $16,800
  adjusted for ~8% demand suppression (premium specialty goods, >5% increase)
  net projection ≈ +$14,200  →  outlook: "positive"
```

**Why is the critic a separate state and not part of `analyze`?** `analyze` is in the
retry loop — it can run up to `maxAttempts` times. The critic is not. Placing it between
`analyze` and `review` means it runs once per completed analysis, never redundantly on
every retry. The cost of a Sonnet + tool call is paid only when there is a fresh
proposal to review.

**Blackboard after `critic_price`:**

```
  assessment  →  CriticAssessment
                   outlook         : "positive"
                   projectedImpact : "+$14,200 projected annual revenue after ~8% demand suppression"
                   riskNote        : "Price elasticity (premium specialty products; >5% increase)"
                   summary         : "These five products represent Northwind's highest-revenue
                                      earners. A 10% increase is within normal pricing-power
                                      range for specialty goods..."
```

---

### State 4: `review` — Human Inspection

**What this step does:** No LLM call. `ApprovalTool` formats the `ProposedChangeSet` as
a numbered table, shows the `CriticAssessment` block when present, and reads one
character from the console.

```xbase
METHOD BulkOperationAgent:review( oCtx )
   LOCAL oProposal   := oCtx:get( "proposal" )
   LOCAL oAssessment := oCtx:get( "assessment" )   // NIL for "other" category
RETURN ApprovalTool():New():requestApproval( oProposal, oAssessment )
```

`oCtx:get( "assessment" )` for an "other" category task (Task 2) returns `NIL` because
neither `critic_price` nor `critic_stock` was entered — the NIL guard on `analyze` went
directly to `review`. `ApprovalTool:requestApproval()` accepts `NIL` and simply skips
the assessment block.

**The `assessment?` declaration.** In `onRegister()`:

```xbase
::addState( "review", "Review", "proposal, assessment?", "approval" ) ;
```

The trailing `?` marks `assessment` as an optional blackboard input. The framework does
not require the key to exist before entering this state. If the `?` were removed, the
agent would abort with a blackboard-slot-not-found error every time a task is classified
as "other". The `?` is load-bearing.

For our T1 run the user types `Y`. `RequestApproval()` returns `ReviewDecision():ok()`.

**Blackboard after `review`:**

```
  approval  →  ReviewDecision( valid: .T., aborted: .F., error: NIL )
```

Guard `IsApproved` reads `approval:Valid` → `.T.` → routes to `write_sql`.

---

### State 5 (terminal): `write_sql` — Build and Write the File

**What this step does:** No LLM call. Builds a transaction-wrapped `.sql` file with a
header comment block and one `UPDATE` statement per change record, then delegates to
`FileWriterTool`.

```xbase
METHOD BulkOperationAgent:writeSql( oCtx )
   LOCAL oProposal := oCtx:get( "proposal" )
   LOCAL cContent  := ""

   cContent += "-- ============================================================" + CRLF
   cContent += "-- Bulk operation: " + oProposal:summary                           + CRLF
   cContent += "-- Generated:      " + DToC( Date() ) + " " + Time()               + CRLF
   cContent += "-- Statements:     " + AllTrim( Str( Len( oProposal:changes ) ) )   + CRLF
   cContent += "-- ============================================================" + CRLF
   cContent += CRLF + "BEGIN;" + CRLF + CRLF

   FOR nI := 1 TO Len( oProposal:changes )
      oChange  := oProposal:changes[nI]
      cContent += "-- " + cDesc + CRLF
      cContent += cSql + CRLF + CRLF
   NEXT

   cContent += "COMMIT;" + CRLF
   oResult   := oWriter:writeFile( oProposal:outputFile, cContent )
```

`FileWriterTool:safeName()` strips all path separators and leading dots from the
filename the LLM proposed. `"price_increase_top5_revenue_2025.sql"` lands in the
current directory only — the LLM cannot write outside the working directory regardless
of what filename it constructs.

`WriteSql` also accepts the snake_case key `"update_sql"` as a fallback in case the LLM
uses that variant instead of `"updateSql"`:

```xbase
IF IsMemberVar( oChange, "updateSql" )
   cSql := AllTrim( oChange:GetNoIvar( "updateSql" ) )
ELSEIF IsMemberVar( oChange, "update_sql" )
   cSql := AllTrim( oChange:GetNoIvar( "update_sql" ) )
ENDIF
```

**Final blackboard:**

```
Blackboard
  request        →  "Increase the unit price..."
  classification →  OperationClassification( category: "price_change", language: "English" )
  proposal       →  ProposedChangeSet( 5 changes, outputFile: "price_increase_top5_revenue_2025.sql" )
  assessment     →  CriticAssessment( outlook: "positive", ... )
  approval       →  ReviewDecision( valid: .T. )
  result         →  WriteResult
                      filePath       : "price_increase_top5_revenue_2025.sql"
                      statementCount : 5
                      message        : "File 'price_increase_top5_revenue_2025.sql' written successfully"
```

`RunTask()` reads `oMachine:getTrace()` to find the terminal state name (`"write_sql"`),
then calls `DisplayWriteResult( oCtx:get("result") )` to print the summary.

---

## Part 3 — How Classes Describe Themselves

Three blackboard classes in this agent declare their own schema in `initClass()`. The
pattern is identical to the AP invoice agent's `InvoiceData`, but two of the three —
`ProposedChangeSet` and `CriticAssessment` — carry richer hint text because the LLM
needs more precise guidance to produce consistent structured output.

### `OperationClassification` — Simple Enum + Language

```xbase
CLASS OperationClassification FROM AbstractCard
   EXPORTED:
   VAR category    // "price_change" | "stock_order" | "other"
   VAR language    // "English" | "German" | ...
   CLASS METHOD initClass()
   METHOD init()
ENDCLASS

CLASS METHOD OperationClassification:initClass()
   ::addHint( "category", "C", ;
      "one of: price_change | stock_order | other. " + ;
      "Use price_change for any unitprice modification (increase, decrease, or flat override). " + ;
      "Use stock_order for any unitsinstock or unitsonorder modification. " + ;
      "Use other for everything else." )
   ::addHint( "language", "C", ;
      "the natural language of the request text, e.g. 'English' or 'German'." )
RETURN Self

METHOD OperationClassification:init()
   ::category := "other"
   ::language := "English"   // safe default; always overwritten by the LLM
RETURN Self
```

The hint for `category` contains the full enumeration and disambiguation rules. The LLM
sees this in the schema instruction and essentially never returns an off-list value.

The safe default in `Init()` is `"other"` — the broadest category, which routes to
`review` without entering any critic. A mis-classified request therefore has no chance
of wasting a Sonnet + tool call on the wrong critic.

### `ProposedChangeSet` — Array with Embedded Structure

```xbase
CLASS METHOD ProposedChangeSet:initClass()
   ::addHint( "summary",    "C", "Human-readable description of what will be changed and how" )
   ::addHint( "changes",    "A", "Array of up to 10 change objects. " + ;
                                 "Each object must have exactly four fields: " + ;
                                 "description (entity name and id only, e.g. 'Chai (productid=1)'), " + ;
                                 "oldValue (current value as a raw number, e.g. 18.00), " + ;
                                 "newValue (computed new value as a raw number, e.g. 19.80), " + ;
                                 "and updateSql (a complete PostgreSQL UPDATE statement)" )
   ::addHint( "outputFile", "C", "Suggested output filename ending in .sql" )
RETURN Self
```

The `changes` hint carries a per-element schema description inside the hint text. There
is no formal nested-schema support in `addHint()` — the LLM infers the per-element
structure from the free-text description. This works reliably in practice because the
`Instruction` contributor on the `analyze` state independently specifies the same four
fields with concrete examples, and the system prompt and schema instruction are seen by
the same model in the same call.

**`Bind()` and the `changes` array.** `Bind()` populates `::changes` from the JSON
array as-is — each element becomes a `DataObject` with dynamic members. `WriteSql`
reads them by name via `IsMemberVar( oChange, "updateSql" )` and
`oChange:GetNoIvar( "updateSql" )`. No typed binding or coercion is needed for array
elements — they are consumed directly.

### `CriticAssessment` — Structured Advisory Output

```xbase
CLASS METHOD CriticAssessment:initClass()
   ::addHint( "outlook",         "C", "one of: positive | neutral | caution | concern" )
   ::addHint( "projectedImpact", "C", "quantified one-sentence projection after applying " + ;
                                      "the dominant business pattern" )
   ::addHint( "riskNote",        "C", "one identified business pattern or risk; " + ;
                                      "empty string when none applies" )
   ::addHint( "summary",         "C", "2-3 sentence advisory for the human reviewer" )
RETURN Self

METHOD CriticAssessment:init()
   ::outlook         := "neutral"
   ::projectedImpact := ""
   ::riskNote        := ""
   ::summary         := ""
RETURN Self
```

`outlook` drives the visual marker in `ApprovalTool:displayAssessment()`:

```
positive → [+]    neutral → [ ]    caution → [~]    concern → [!]
```

The safe default in `Init()` is `"neutral"` and an empty assessment. If the LLM returns
a malformed response and `Bind()` leaves some fields empty, the reviewer sees a `[ ]`
marker and blank lines — not a crash.

The class hints are intentionally brief. The step-by-step reasoning process (what to
query, how to project, which patterns to apply) lives in the `Instruction` contributor
inside the critic action method. The hint shapes the JSON output format; the instruction
shapes the analytical reasoning. They are complementary, not redundant.

---

## Part 4 — The Other Four Tasks

Each task is described only by where it **diverges** from the T1 path in Part 2.

---

### Task 2 — Discontinue Supplier-3 Products (no critic)

**Request:** `"Mark as discontinued (set discontinued = 1) all products supplied by supplier ID 3 that have never appeared in any order in the entire order history."`

**`classify`** returns `{ category: "other", language: "English" }`.

**`analyze`** typically issues two queries: one to find all supplier-3 products, a
second to find which of those product IDs appear in `order_details`. The LLM generates
`UPDATE products SET discontinued = 1 WHERE productid = X;` for each product that has
zero orders.

After `analyze`, both `IsPriceChange` and `IsStockOrder` return `.F.`. The NIL guard
fires and the flow goes **directly to `review`** — neither critic state is entered.
`oCtx:get( "assessment" )` returns `NIL`. `ApprovalTool:requestApproval()` receives
`NIL` as the second argument and silently skips the assessment block. The reviewer sees
only the change table and the Y / R / A prompt.

---

### Task 3 — Seafood Category Price Reduction (rejection and retry)

**Request:** `"Reduce the unit price of every product in the Seafood category by 15%. Round each new price to exactly 2 decimal places."`

**`classify`:** `price_change`

**`analyze`** queries all Seafood products (categoryid = 8), computes 15% reductions,
proposes up to 10 changes. The `critic_price` runs and notes that a price decrease
typically produces demand uplift, partially offsetting the direct revenue loss.

**The user presses R** and types: `"Only reduce the top 3 most expensive Seafood products."`

`review` returns `ReviewDecision():fail( "Only reduce the top 3 most expensive Seafood products." )`.

Guard evaluation on `review`:
- `IsApproved` → `.F.`
- `IsAborted` → `.F.`
- `IsExhausted` → `analyze` has run once, `maxAttempts` is 3, so `.F.`
- `isRetryFor "approval"` → `.T.` → routes to `merge_request`

**`merge_request`:**

```xbase
METHOD BulkOperationAgent:mergeRequest( oCtx )
   LOCAL cBaseRequest := If( oCtx:has( "activeRequest" ), ;
                             oCtx:get( "activeRequest" ), ;
                             oCtx:get( "request" ) )
   LOCAL cFeedback    := oCtx:get( "approval" ):Error
   LOCAL cLanguage    := oCtx:get( "classification" ):language
```

On the first rejection `oCtx:has( "activeRequest" )` is `.F.` — the original request
is the baseline. The LLM (Haiku, no tools) receives:

```
Current task:      "Reduce the unit price of every product in the Seafood
                    category by 15%. Round each new price to exactly 2 decimal places."

User correction:   "Only reduce the top 3 most expensive Seafood products."
```

And produces a single, self-contained merged task:

```
"Reduce the unit price of the 3 most expensive Seafood category products
 by 15%. Round each new price to exactly 2 decimal places."
```

This string is returned and written to `activeRequest` on the blackboard. The NIL guard
routes back to `analyze`. On the second pass, `analyze` reads `activeRequest` and
queries only the top 3 Seafood products by `unitprice DESC LIMIT 3`.

**Why not inject the feedback as a `WithMessage()` call?** Two reasons:

1. On a *second* rejection the model would receive three separate messages — original,
   correction 1, correction 2 — and must reconcile all of them simultaneously. Accuracy
   degrades as corrections accumulate.

2. `analyze` already carries a large system prompt (schema + instruction). Adding
   conversational history grows the context further and increases cost per call.

`MergeRequest` compresses all corrections into one clean task description that `analyze`
treats as a first-call request. Each `analyze` run is exactly as clean and cheap as the
first one.

On the second retry the user approves. `write_sql` runs with a 3-item proposal.

---

### Task 4 — Stock Increase (stock critic)

**Request:** `"Add 100 units to the unitsinstock of the 5 products with the lowest current stock that are not discontinued."`

**`classify`:** `stock_order`

**`analyze`** queries:

```sql
SELECT productid, productname, unitsinstock
FROM products
WHERE discontinued = 0
ORDER BY unitsinstock ASC LIMIT 5
```

Adds 100 to each `unitsinstock` value and generates the UPDATE statements.

After `analyze`, `IsStockOrder` fires → `critic_stock`.

**`CritiqueStock`** queries 12-month units sold for the five products and computes:

```
monthly_rate    = total_units_sold / 12
months_coverage = 100 / monthly_rate
```

Coverage thresholds drive the overall outlook:

| Coverage | Outlook |
|---|---|
| < 1 month | caution (may be insufficient for demand) |
| 1–3 months | positive or neutral (reasonable replenishment) |
| 3–6 months | caution (possibly excessive; cash tied up) |
| > 6 months | concern (excess inventory; cash-flow risk) |

The critic reports the worst outlook across all five products. For a product with no
12-month sales history the critic assigns `caution` and notes the missing baseline
explicitly.

The assessment block shows the coverage projection at review. The user can then
judge whether a 4-month restock for a slow-moving product is worth the inventory cost.

---

### Task 5 — Flat Price Override by Price Band

**Request:** `"Set unitprice = 9.99 for all products from supplier ID 1 whose current unitprice is between 10.00 and 12.00 inclusive."`

**`classify`:** `price_change` — any `unitprice` modification is a price change,
even a flat override rather than a percentage.

**`analyze`** queries:

```sql
SELECT productid, productname, unitprice
FROM products
WHERE supplierid = 1
  AND unitprice BETWEEN 10.00 AND 12.00
```

For each matching product, `updateSql` is `UPDATE products SET unitprice = 9.99 WHERE productid = X;`. The arithmetic is trivial, but `analyze` still queries the database to
find the current prices — the LLM does not guess which products are in the band.

`critic_price` runs and notes that the price decrease from ~$11 to $9.99 is modest;
demand uplift is likely small.

**No new patterns here.** T5 shows that the `IsPriceChange` guard reads the
classification string, not the complexity of the arithmetic. A flat override is treated
identically to a percentage increase — same critic, same review, same write-to-disk path.

---

## Part 5 — The Three Files and When You Touch Each

### `bulk-operation-common.prg` — Domain Types and Infrastructure

**Open this file when** you are adding or changing a blackboard class, updating the
database schema description, adding a persona, or modifying the tool classes.

**Domain class pattern — always the same template:**

```xbase
CLASS MyOutput FROM AbstractCard
   EXPORTED:
   VAR field1
   VAR field2
   CLASS METHOD initClass()
   METHOD init()
ENDCLASS

CLASS METHOD MyOutput:initClass()
   ::addHint( "field1", "C", "what field1 means and the exact format the LLM should use" )
   ::addHint( "field2", "N", "field2 as a raw JSON number, e.g. 42.50" )
RETURN Self

METHOD MyOutput:init()
   ::field1 := ""
   ::field2 := 0
RETURN Self
```

For array fields with embedded structure, carry the per-element schema in the hint text:

```xbase
::addHint( "items", "A", "Array of objects. Each object must have: " + ;
                         "id (string), value (number as raw numeric literal)" )
```

**`NorthwindBulkQueryTool`** is the only `AbstractToolClass` in this example. It
exposes one tool — `ExecuteQuery` — shared by `analyze`, `critic_price`, and
`critic_stock` through the single `::oQueryTool` instance on the agent. All three states
call `:withTool( ::oQueryTool )`. The tool object is re-used safely because the states
run sequentially and `NorthwindBulkQueryTool` holds no per-call state.

**`BulkSchemaContributor`** is a `PromptContributor` subclass — not a tool, not a
persona. It injects a static schema description into the system prompt. Any time the
column structure changes, you edit `Contribution()` here and every state that uses
`BulkSchemaContributor():New()` picks up the change automatically.

**`ApprovalTool` and `FileWriterTool`** are plain Xbase++ classes, not
`AbstractToolClass` subclasses. They are called directly inside action methods
(`Review`, `WriteSql`) and are never exposed to the LLM. The word "tool" in their
names means "a utility helper used by an action method", not "a function the LLM can
invoke through the tool-calling loop".

### `bulk-operation-agent.prg` — The Flow and the Logic

**Open this file when** you are adding a state, changing a guard, adjusting LLM
parameters, or modifying the prompts.

`onRegister()` is the single source of truth for the flow. Read it first when navigating
the agent. Three design details are worth pointing out:

**Optional inputs (`?`).** The `?` suffix on a blackboard slot name marks it as
optional. `"activeRequest?"` on `analyze` is absent on the first pass. `"assessment?"`
on `review` is absent for "other" category tasks. Removing either `?` would cause
a blackboard-slot-not-found abort on those paths.

**Guard order on `review` matters.** `IsApproved` is checked first — a successful
result is always honoured before any limit logic runs. `IsAborted` is second — a user
abort is always honoured even if retries are exhausted. `IsExhausted` is third —
catches the retry limit before the generic retry guard. `isRetryFor "approval"` is
last — the reject path.

**`classify` is outside the retry loop.** The loop is `analyze → critic → review
→ merge_request → analyze`. `classify` feeds into the top of that chain once and never
re-runs, even when `analyze` is visited three times. The category and language detections
are stable for the lifetime of the task.

Action methods follow a consistent contract: receive `oCtx`, read declared inputs,
call `oCtx:ai()` for LLM states or the appropriate helper for non-LLM states, return
the result. The framework writes it to the declared output slot.

### `bulk-operation-main.prg` — Database Setup and Task Loop

**Open this file when** you are changing the connection string, adding or modifying task
descriptions, or changing how outcomes are reported.

`BulkOperationAgent():New( oSession )` is called once. The `DacSession` is passed into
`NorthwindBulkQueryTool` at construction and held there for the lifetime of all five
tasks.

`RunTask()` is the reporting boundary. It creates the fresh `AgentContext`, runs the
machine, and inspects `oMachine:getTrace()` to find the terminal state name. In a production
system this is where you replace the console-print calls with a database write, a queue
message, or an audit log entry.

The four terminal outcomes:

| Terminal | Condition | Reporting |
|---|---|---|
| `write_sql` | User approved | `DisplayWriteResult( oCtx:get("result") )` |
| `aborted` | User chose A | Print "Task aborted by user" |
| `failed` | Retries exhausted | Print attempt count + "no SQL written" |
| Error (RECOVER) | Unhandled exception from any state | Print `oErr:description` |

---

## Part 6 — Adaptation Recipes

### Recipe 1 — Connect a Different PostgreSQL Database

Replace the connection string in `Main()`:

```xbase
cConnect := "DBE=pgdbe;SERVER=myserver;DB=mydb;UID=myuser;PWD=mypwd"
oSession  := DacSession():New( cConnect )
```

Update `BulkSchemaContributor:contribution()` to describe your actual tables and
columns. The security gate in `NorthwindBulkQueryTool:executeQuery()` — the
`SELECT / WITH` check — works for any PostgreSQL schema.

### Recipe 2 — Add a Third Critic for Budget Impact

Add a new category and guard:

```xbase
// In onRegister():
::addState( "analyze", "Analyze", "request, activeRequest?", "proposal" ) ;
   :onGuard( "IsPriceChange",  "critic_price"  ) ;
   :onGuard( "IsStockOrder",   "critic_stock"  ) ;
   :onGuard( "IsBudgetChange", "critic_budget" ) ;   // ← new
   :onGuard( NIL,              "review"        )

::addState( "critic_budget", "CritiqueBudget", "proposal, classification", "assessment" ) ;
   :onGuard( NIL, "review" )

// New guard method:
METHOD BulkOperationAgent:IsBudgetChange( oCtx )
RETURN Lower( AllTrim( oCtx:get( "classification" ):category ) ) == "budget_change"
```

Add `budget_change` to the enum in the `Classify` instruction and to the
`OperationClassification:initClass()` hint. Implement `CritiqueBudget()` following the
same four-step pattern as `CritiquePrice()`. No other files are touched.

### Recipe 3 — Increase the Retry Limit

In `BulkOperationAgent:init()`:

```xbase
::MaxAttempts := 5   // up from 3
```

### Recipe 4 — Use a Different LLM for Analyze

```xbase
LOCAL oLLM   := LLMOptions():withModel( OpenAiModels():GPT_41 ):withTemperature( 0 )
LOCAL oAgent := BulkOperationAgent():New( oSession, oLLM )
```

`Classify` and `MergeRequest` always use Haiku regardless — they override the LLM
locally with `:withLLM()`. Only `Analyze`, `CritiquePrice`, and `CritiqueStock` use
the default LLM passed to `Init()`.

### Recipe 5 — Increase the Row Cap in ExecuteQuery

```xbase
// In NorthwindBulkQueryTool:executeQuery():
IF At( "LIMIT", Upper( cSql ) ) == 0
   cSql += " LIMIT 100"   // up from 50
ENDIF

// In RunQuery() — the guard that stops the DO WHILE:
DO WHILE !EOF() .AND. nRows < 100   // match the new cap
```

### Recipe 6 — Add a New LLM-Populated Class

1. Derive from `AbstractCard`
2. Declare `VAR` members, `CLASS METHOD initClass()`, and `METHOD init()`
3. In `initClass()`, call `addHint( cMember, cValType, cHint )` for every field.
   For array fields, describe the per-element structure inside the hint text
4. In `Init()`, set typed defaults matching the declared types
5. Pass the class name to `CreateObject()` — schema generation is automatic

```xbase
CLASS BudgetImpact FROM AbstractCard
   EXPORTED:
   VAR affectedBudget
   VAR deltaAmount
   VAR percentChange
   CLASS METHOD initClass()
   METHOD init()
ENDCLASS

CLASS METHOD BudgetImpact:initClass()
   ::addHint( "affectedBudget", "C", "name of the budget line being affected" )
   ::addHint( "deltaAmount",    "N", "projected change in budget spend as a raw JSON number" )
   ::addHint( "percentChange",  "N", "percent change as a raw JSON number, e.g. 4.5 for 4.5%%" )
RETURN Self

METHOD BudgetImpact:init()
   ::affectedBudget := ""
   ::deltaAmount    := 0
   ::percentChange  := 0
RETURN Self
```

---

## Part 7 — When Things Go Wrong

### Problem: Connection Failed at Startup

**Symptom:** `Connection failed: <message>` is printed and `Main()` returns immediately.

**Fix:** Check the connection string in `Main()`. Verify that the PostgreSQL server is
running, the `northwind` database exists, and the credentials are correct.

---

### Problem: No API Key

**Symptom:** Every task prints
`Error: API key not configured for provider Anthropic` from the `RECOVER USING oErr`
path in `RunTask()`. All five tasks fail; the program completes normally.

**Fix:** Set `ANTHROPIC_API_KEY` in the environment (or source `apikey.bat`) and
re-run.

---

### Problem: LLM Attempts an UPDATE During Analysis

**Symptom:** `NorthwindBulkQueryTool` returns `"Error: Only SELECT statements and CTEs
are allowed."`. The LLM receives this as a tool result and — if it follows instructions
correctly — rewrites the query as a SELECT.

**If the LLM repeatedly ignores the restriction:** Strengthen the `Instruction`
contributor in `Analyze()` by prepending:
`"CRITICAL: NEVER run UPDATE, INSERT, or DELETE. Only SELECT and WITH are allowed."`
as the very first line of the instruction.

---

### Problem: `analyze` Returns NIL

**Symptom:** `RunTask()` catches an error from `BulkOperationAgent:analyze` and prints
`"Error: BulkOperationAgent:analyze: <LLM error>"`. The task is skipped.

**Likely causes and fixes:**

1. **API rate limit (HTTP 429):** Wait briefly and re-run.
2. **Token limit exceeded:** The schema contributor + instruction + prior messages
   exceeded `max_tokens`. Reduce `BulkSchemaContributor:contribution()` to the tables
   and columns your tasks actually need.
3. **JSON parsing failure:** The model returned a response that could not be bound to
   `ProposedChangeSet` — the JSON was malformed or lacked required fields. The
   `Instruction` contributor's field descriptions and the class hints together should
   prevent this; switching from Haiku to Sonnet for the `analyze` call resolves most
   parsing failures.

---

### Problem: The SQL File Has a Generic Name

**Symptom:** The file is written as `bulk_update.sql` instead of the descriptive name
the proposal suggested.

**Why it happens:** The LLM left `outputFile` empty. `ProposedChangeSet:init()` sets
`::outputFile := "bulk_update.sql"` as the safe fallback, which `WriteSql` passes
unchanged to `FileWriterTool`.

**Fix:** Strengthen the `outputFile` hint in `ProposedChangeSet:initClass()` to include
a concrete example:
`"Suggested output filename ending in .sql, e.g. price_increase_top5_2025.sql — must end in .sql"`.

---

### Problem: The MergeRequest Output Is Vague

**Symptom:** After a rejection, `analyze` runs again but produces a proposal nearly
identical to the rejected one.

**Why it happens:** The user's correction was ambiguous (`"make it smaller"`), and
`MergeRequest` produced an equally ambiguous merged task. Haiku followed the text
faithfully.

**Fix:** Ask the user for a more specific correction at the `R` prompt — specific
numeric values and explicit filter conditions. You can also strengthen the `MergeRequest`
`Instruction` contributor by appending:
`"The output must include specific numeric values and explicit filter conditions."`

---

*End of Annotated Code Tour*

*Three files. Five tasks. The LLM queries the database and then steps aside while a human decides.*
