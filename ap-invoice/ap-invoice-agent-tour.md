# AP Invoice Agent — Annotated Code Tour

**Who this is for:** Any line-of-business developer who is comfortable reading Xbase++ 
code and familiar with how business processes work — regardless of domain.
If you want to understand how the `ApInvoiceAgent` example works and adapt it to your
own system, this tour is for you.

**How to use this document:** Read it with the three source files open beside it.
The document always points at real, complete code. There is nothing to build.

**Files covered:**

| File | Role |
|---|---|
| `ap-invoice-agent-common.prg` | Domain types, demo vendor/PO data, XML loader, personas |
| `ap-invoice-agent.prg` | The agent: flow declaration, all actions, all guards |
| `ap-invoice-main.prg` | Driver: load invoices from config, run agent, print results |

---

## Before You Read Anything: Run the Agent

Open a terminal in the `examples\` directory, set your Mistral API key, then run:

```bat
call apikey.bat
ap-invoice-agent.exe
```

You should see output like this — seven invoices, four different outcomes:

```
=== Invoice 1 (sample-autopost) ===
Source label:  sample-autopost
Vendor:        Northwind Traders
Invoice #:     INV-3003
PO #:          PO-1003
Amount:              275.00 EUR
AUTO-POSTED:   Posted 275.00 EUR to ledger

=== Invoice 2 (sample-approval) ===
Source label:  sample-approval
Vendor:        Contoso Ltd
Invoice #:     INV-2002
PO #:          PO-1002
Amount:             3400.00 EUR
APPROVAL:      ap-approval-manager (P3)
Reason:        amount over auto-post threshold
Message:       Please review and approve invoice INV-2002 from Contoso Ltd for EUR
               3,400.00 referencing PO-1002. The invoice matches the PO within
               tolerance but exceeds the auto-post threshold. Your approval is
               required before payment can be processed.

=== Invoice 3 (sample-duplicate) ===
Source label:  sample-duplicate
Vendor:        Acme Corp
Invoice #:     INV-DUP-42
PO #:          PO-1001
Amount:             1250.00 GBP
EXCEPTION:     duplicate
Reason:        Invoice already posted: INV-DUP-42

=== Invoice 4 (sample-hard-mismatch) ===
Source label:  sample-hard-mismatch
Vendor:        Northwind Traders
Invoice #:     INV-3999
PO #:          PO-1003
Amount:              999.99 EUR
EXCEPTION:     hard-mismatch
Reason:        amount differs from PO by 724.99

=== Invoice 5 (sample-unknown-vendor) ===
Source label:  sample-unknown-vendor
Vendor:        Widgets and Co
Invoice #:     INV-WC-001
PO #:
Amount:              500.00 USD
EXCEPTION:     unknown-vendor
Reason:        Vendor not in master: Widgets and Co

=== Invoice 6 (sample-acme-approval) ===
Source label:  sample-acme-approval
Vendor:        Acme Corp
Invoice #:     INV-1001
PO #:          PO-1001
Amount:             1250.00 GBP
APPROVAL:      ap-approval-manager (P3)
Reason:        amount over auto-post threshold
Message:       Please review and approve invoice INV-1001 from Acme Corp for GBP
               1,250.00 referencing PO-1001. The invoice matches the PO within
               tolerance but exceeds the auto-post threshold. Kindly approve or
               reject by end of business.

=== Invoice 7 (sample-fuzzy-vendor) ===
Source label:  sample-fuzzy-vendor
Vendor:        Acme Corporation
Invoice #:     INV-CORP-001
PO #:          PO-1001
Amount:              750.00 GBP
PENDING:       vendor match requires human approval
Invoice vendor:    Acme Corporation
Proposed match:    Acme Corp (V-100)
LLM reasoning:     "Acme Corporation" is the full legal name commonly abbreviated
                   as "Acme Corp" in the vendor master.
```

This is your working reference. At any point while reading the document you can re-run
the agent and compare against this output.

> **No API key yet?** The agent will still run. Each invoice will print
> `AP processing failed: <LLM error>` instead of a result. That is the
> `RECOVER USING oError` path in `ProcessOne()` working correctly —
> one failed invoice does not abort the rest. Get a Mistral key from
> [console.mistral.ai](https://console.mistral.ai), put it in `apikey.bat`,
> and re-run. See also Part 7 — When Things Go Wrong.

---

## Part 1 — The Big Picture

### What This Agent Automates

A supplier sends an invoice. Someone in accounts payable must:

1. Extract the invoice fields (vendor, invoice number, PO number, amount, currency, IBAN)
2. Check the vendor exists in the vendor master — with LLM-assisted fuzzy matching as a fallback
3. Confirm the invoice number has not already been paid
4. Match the invoice amount against the purchase order
5. Either post the invoice automatically (small amounts within tolerance), route it
   to the appropriate approval queue (larger amounts), route an unrecognised vendor
   for human review, or raise an exception (mismatch, duplicate, no vendor found)

The `ApInvoiceAgent` automates all five steps. The LLM is used for three tasks:
field extraction (step 1), fuzzy vendor name matching (step 2 fallback), and
drafting the approval request message (step 5). Everything else is pure Xbase++.

### How the Agent Makes Decisions

**The happy path** — the route every correctly-formed invoice with a known vendor takes:

```
  extract ──► validateExtract ──► lookupVendor ──► checkDuplicate ──► matchToPO
                                                                           │
                                                              ┌────────────┴────────────┐
                                                              ▼                         ▼
                                                          autoPost ★          routeForApproval ★
                                                    (below threshold)       (above threshold,
                                                                             LLM drafts message)
```

**The complete flow with all branches** — every guard and every terminal:

```
  extract ◄──────────────────────────────────────────── retry (error fed back)
     │ (LLM: field extraction)
     ▼
  validateExtract
     ├──[IsExtractOk]────────────────────────────────► lookupVendor
     ├──[IsExhausted]────────────────────────────────► raiseException ★
     └──[isRetryFor "extraction"]────────────────────► extract

  lookupVendor
     ├──[IsVendorUnknown]────────────────────────────► proposeVendorMatch (LLM: fuzzy match)
     └──[NIL]────────────────────────────────────────► checkDuplicate

  proposeVendorMatch
     ├──[HasVendorProposal]──────────────────────────► awaitVendorApproval ★
     └──[NIL]────────────────────────────────────────► raiseException ★

  checkDuplicate
     ├──[IsDuplicate]────────────────────────────────► raiseException ★
     └──[NIL]────────────────────────────────────────► matchToPO

  matchToPO
     ├──[IsHardMismatch]─────────────────────────────► raiseException ★
     ├──[NeedsApproval]──────────────────────────────► routeForApproval ★ (LLM: drafts message)
     └──[NIL]────────────────────────────────────────► autoPost ★

  ★ = terminal state (agent stops and returns the blackboard)
```

Every guard, every non-LLM action, and the `autoPost` and `raiseException` terminals
are deterministic Xbase++.

### The Seven Sample Invoices

**Vendor master (`DemoVendorMaster`)**

| ID | Name | IBAN |
|---|---|---|
| V-100 | Acme Corp | GB29NWBK60161331926819 |
| V-101 | Contoso Ltd | DE89370400440532013000 |
| V-102 | Northwind Traders | FR7630006000011234567890189 |
| V-999 | Fabrikam Inc | US00CITI0000000012345678 (inactive) |

**Purchase order book (`DemoPurchaseOrderBook`)**

| PO Number | Vendor | Amount | Currency |
|---|---|---|---|
| PO-1001 | V-100 (Acme) | 1,250.00 | GBP |
| PO-1002 | V-101 (Contoso) | 3,400.00 | EUR |
| PO-1003 | V-102 (Northwind) | 275.00 | EUR |

**Posted ledger (duplicate seed):** V-100 / INV-DUP-42

**Agent thresholds**

| Setting | Value | Meaning |
|---|---|---|
| `autoPostThreshold` | 500.00 | Amounts at or below this post automatically |
| `amountTolerance` | 0.50 | Invoice/PO delta allowed before hard mismatch |
| `maxAttempts` | 3 | LLM extraction retries before raising exception |

**The seven scenarios**

| # | Label | Vendor | Terminal | What it exercises |
|---|---|---|---|---|
| 1 | sample-autopost | Northwind | `autoPost` | Full pipeline, below threshold (image) |
| 2 | sample-approval | Contoso | `routeForApproval` | Full pipeline, above threshold + LLM message (image) |
| 3 | sample-duplicate | Acme | `raiseException` | Stops at `checkDuplicate` (image) |
| 4 | sample-hard-mismatch | Northwind | `raiseException` | Stops at `matchToPO` (image) |
| 5 | sample-unknown-vendor | Widgets and Co | `raiseException` | No LLM match found (text) |
| 6 | sample-acme-approval | Acme | `routeForApproval` | Full pipeline + LLM message (text) |
| 7 | sample-fuzzy-vendor | Acme Corporation | `awaitVendorApproval` | Fuzzy match → human review (text) |

---

## Part 2 — Follow One Invoice Through the Code

> **Our invoice for Part 2:**
>
> `Acme Corp · INV-1001 · PO-1001 · £1,250.00 GBP`
>
> This is `sample-acme-approval`, scenario 6 — plain text, full pipeline,
> terminates at `routeForApproval` with an LLM-drafted approval message.

### The Blackboard

Every agent run has an `AgentContext`. Think of it as a named clipboard that travels
through all the states. Each state reads what it needs and writes its own result back.

`oCtx:set( "key", value )` — write; `oCtx:get( "key" )` — read.

At the start, the blackboard has exactly one entry:

```
Blackboard
  source  →  InvoiceSource
               text:      "Invoice from Acme Corp, invoice number INV-1001..."
               imagePath: ""
               label:     "sample-acme-approval"
```

---

### Loading the Invoice — `ap-invoice-main.prg`

```xbase
PROCEDURE Main( cConfigFile )
   LOCAL oAgent := ApInvoiceAgent():New( DemoVendorMaster():New(), DemoPurchaseOrderBook():New() )
   LOCAL aSources
   LOCAL nI

   DEFAULT cConfigFile TO "ap-invoice-samples.config"
   aSources := LoadInvoiceSources( cConfigFile )

   FOR nI := 1 TO Len( aSources )
      ? "=== Invoice " + AllTrim( Str( nI ) ) + " (" + aSources[nI]:label + ") ==="
      ProcessOne( oAgent, aSources[nI] )
   NEXT
```

`LoadInvoiceSources()` uses `XmlSimpleParser()` to read the config file.
`NodeToInvoiceSource()` builds each `InvoiceSource` with direct member assignment —
no constructor parameters:

```xbase
FUNCTION NodeToInvoiceSource( oNode )
   LOCAL oSrc := InvoiceSource():New()
   oSrc:text      := IIF( ValType( oNode:text      ) == "C", AllTrim( oNode:text      ), "" )
   oSrc:imagePath := IIF( ValType( oNode:imagePath ) == "C", AllTrim( oNode:imagePath ), "" )
   oSrc:label     := AllTrim( oNode:label )
RETURN oSrc
```

`AgentStateMachine():forAgent( oAgent ):run( oCtx )` then drives the state machine.
`ProcessOne()` wraps each invoice in `BEGIN SEQUENCE … RECOVER` so one failed LLM call
does not abort the batch.

---

### State 1: `extract` — Ask the LLM to Read the Invoice

**What this step does:** Read all structured fields off the invoice. This is the first
of the three LLM calls in the agent.

```xbase
METHOD ApInvoiceAgent:extract( oCtx )
   LOCAL oSource
   LOCAL oPrevVal
   LOCAL oRunner
   LOCAL oGenerated
   LOCAL oErr

   oSource  := oCtx:get( "source" )
   oPrevVal := oCtx:get( "extraction" )    // NIL on first pass

   oRunner := oCtx:ai()

   IF ::isRetryFor( oCtx, "extraction" )
      oRunner := oRunner:withMessage( UserMessage():New( ;
                    "Your previous attempt failed validation: " + oPrevVal:Error ) )
   ENDIF

   IF oSource:hasText()
      oGenerated := oRunner:createObject( "Extract fields from this invoice:" + CRLF + oSource:text, "InvoiceData" )
   ELSEIF oSource:hasImage()
      oRunner    := oRunner:withImage( oSource:imagePath )
      oGenerated := oRunner:createObject( "Extract fields from the attached invoice image.", "InvoiceData" )
   ENDIF

   IF oGenerated == NIL
      oErr := ErrorNew()
      oErr:description := oRunner:getLastError()
      Break( oErr )
   ENDIF

RETURN oGenerated
```

**`oCtx:ai()`** returns a `PromptRunner` pre-loaded with the agent's default LLM
(Mistral Small, temperature 0) and default persona (the `Extractor` persona). There is
no `Instruction():create()` block anywhere in this method.

> **Where does the field list come from?** `InvoiceData:initClass()` registers a type
> and description for every field — `addHint( "amount", "N", "..." )` tells the
> framework `amount` is a number; `addHint( "date", "D", "..." )` tells it `date` is
> a Date. The `PromptRunner` reads those class-level hints and appends the typed
> field list to the user message automatically. `Bind()` then coerces any type
> mismatches in the JSON reply before the action method ever sees the result.
> **Part 3 — How Classes Describe Themselves** covers all of this in full.

**`isRetryFor( oCtx, "extraction" )`** — on a retry, the previous validation error is
injected as a `UserMessage` so the LLM knows exactly what it got wrong.

**Blackboard after `extract`:**

```
Blackboard
  source   →  InvoiceSource (text: "Invoice from Acme Corp...")
  invoice  →  InvoiceData
                vendor:        "Acme Corp"
                invoiceNumber: "INV-1001"
                poNumber:      "PO-1001"
                date:          20260305  ← real Xbase++ Date, not a string
                amount:        1250.00   ← real Numeric
                currency:      "GBP"
                bankAccount:   "GB29NWBK60161331926819"
                recipient:     ""
```

---

### State 2: `validateExtract` — Check the LLM's Work

Deterministic field validation. Uses `WasBound()` / `IsBound()` to distinguish a field
the LLM omitted entirely from one it sent as an empty string.

```xbase
METHOD ApInvoiceAgent:validateExtract( oCtx )
   LOCAL oInv := oCtx:get( "invoice" )
   IF oInv:wasBound() .AND. !oInv:isBound( "vendor" )
      RETURN ExtractionValidation():fail( "vendor not provided" )
   ELSEIF Empty( oInv:vendor )
      RETURN ExtractionValidation():fail( "missing vendor" )
   ENDIF
   IF Empty( oInv:invoiceNumber )
      RETURN ExtractionValidation():fail( "missing invoice number" )
   ENDIF
   IF Empty( oInv:date )
      RETURN ExtractionValidation():fail( "missing date" )
   ENDIF
   IF ValType( oInv:amount ) != "N"
      RETURN ExtractionValidation():fail( "amount must be a positive number" )
   ENDIF
   IF oInv:amount <= 0
      RETURN ExtractionValidation():fail( "amount must be a positive number" )
   ENDIF
   IF Empty( oInv:currency )
      RETURN ExtractionValidation():fail( "missing currency" )
   ENDIF
RETURN ExtractionValidation():ok()
```

`Empty( oInv:date )` on a Date returns `.T.` when the date is `CToD("")` — the same
empty-check idiom works for both strings and dates.

`ValType( oInv:amount ) != "N"` is now a true safety net: `Bind()` already coerced any
quoted number to `"N"`, so this check only fails if the LLM returned something
completely non-numeric.

**Blackboard after `validateExtract`:**
```
  extraction  →  ExtractionValidation( valid: .T., error: NIL )
```

---

### State 3: `lookupVendor` — Find the Vendor in the Master

Name lookup first; IBAN fallback second. Returns `NIL` when nothing matches, which
`IsVendorUnknown` detects — routing to `proposeVendorMatch`, not directly to
`raiseException`.

```xbase
METHOD ApInvoiceAgent:lookupVendor( oCtx )
   LOCAL oInv    := oCtx:get( "invoice" )
   LOCAL oVendor := ::vendorMaster:findByName( oInv:vendor )
   IF oVendor == NIL .AND. !Empty( oInv:bankAccount )
      oVendor := ::vendorMaster:findByBank( oInv:bankAccount )
   ENDIF
RETURN oVendor
```

For our Acme invoice, `FindByName("Acme Corp")` finds V-100 immediately.

**Blackboard after `lookupVendor`:**
```
  vendor  →  VendorRecord( id: "V-100", name: "Acme Corp", active: .T. )
```

---

### State 4: `checkDuplicate` — Check the Posted Ledger

```xbase
METHOD ApInvoiceAgent:checkDuplicate( oCtx )
   LOCAL oInv    := oCtx:get( "invoice" )
   LOCAL oVendor := oCtx:get( "vendor" )
   LOCAL oDup    := DuplicateCheck():New()
   IF ::poBook:isInvoiceRegistered( oVendor:id, oInv:invoiceNumber )
      oDup:duplicate     := .T.
      oDup:existingDocId := oInv:invoiceNumber
   ENDIF
RETURN oDup
```

`DuplicateCheck():New()` sets `::duplicate := .F.` and `::existingDocId := ""` by
default. Only the fields that differ from the safe default need to be set — no
constructor parameters, no NIL guards.

INV-1001 is not in the posted ledger. The guard `IsDuplicate` reads `.F.` and the flow
continues to `matchToPO`.

**Blackboard after `checkDuplicate`:**
```
  duplicate  →  DuplicateCheck( duplicate: .F., existingDocId: "" )
```

---

### State 5: `matchToPO` — Three-Way Match

```xbase
METHOD ApInvoiceAgent:matchToPO( oCtx )
   LOCAL oInv    := oCtx:get( "invoice" )
   LOCAL oVendor := oCtx:get( "vendor" )
   LOCAL oPo, nDelta, lWithin, oMatch
   ...
   nDelta  := oInv:amount - oPo:total    // 1250.00 - 1250.00 = 0.00
   lWithin := Abs( nDelta ) <= ::amountTolerance    // .T.

   // amount > autoPostThreshold → needsApproval
   oMatch                := ThreeWayMatch():New()
   oMatch:poFound         := .T.
   oMatch:amountDelta     := nDelta
   oMatch:tolerance       := ::amountTolerance
   oMatch:withinTolerance := .T.
   oMatch:needsApproval   := .T.
   oMatch:reason          := "matched, over auto-post threshold - requires approval"
RETURN oMatch
```

`ThreeWayMatch():New()` sets all booleans to `.F.` and numerics to `0` by default. Each
return path sets only the fields that differ from those safe defaults. Guards read the
pre-computed flags directly — no recomputation at guard evaluation time.

Guard `NeedsApproval` reads `oCtx:get("match"):needsApproval` → `.T.` → `routeForApproval`.

**Blackboard after `matchToPO`:**
```
  match  →  ThreeWayMatch( poFound: .T., withinTolerance: .T., needsApproval: .T.,
                            amountDelta: 0.00, tolerance: 0.50, hardMismatch: .F. )
```

---

### State 6: `routeForApproval` — Route and Draft the Message

The terminal that makes two decisions: the routing tier (pure Xbase++) and the
approval message (LLM).

```xbase
METHOD ApInvoiceAgent:routeForApproval( oCtx )
   LOCAL oInv    := oCtx:get( "invoice" )
   LOCAL oVendor := oCtx:get( "vendor" )
   LOCAL cQueue, cPri, cMessage, oReq

   DO CASE
   CASE oInv:amount <= 5000
      cQueue := "ap-approval-manager" ;  cPri := "P3"
   CASE oInv:amount <= 25000
      cQueue := "ap-approval-director" ; cPri := "P2"
   OTHERWISE
      cQueue := "ap-approval-cfo" ;      cPri := "P1"
   ENDCASE

   cMessage := oCtx:ai() ;
               :withPromptContributor( ApInvoicePersonas():approvalDrafter() ) ;
               :generateText( ;
                  "Draft a concise approval request (2-3 sentences) for:" + CRLF + ;
                  "  Vendor:   " + oVendor:Name + CRLF + ;
                  "  Invoice:  " + oInv:invoiceNumber + CRLF + ;
                  "  PO:       " + oInv:poNumber + CRLF + ;
                  "  Amount:   " + AllTrim( Str( oInv:amount, 12, 2 ) ) + " " + oInv:currency + CRLF + ;
                  "  Queue:    " + cQueue + CRLF + ;
                  "  Priority: " + cPri )

   IF cMessage == NIL
      cMessage := "Invoice requires approval - amount exceeds the auto-post threshold."
   ENDIF

   oReq          := ApprovalRequest():New()
   oReq:queue    := cQueue
   oReq:priority := cPri
   oReq:reason   := "amount over auto-post threshold"
   oReq:message  := cMessage
RETURN oReq
```

The tier logic runs first (no LLM). The `ApprovalDrafter` persona is added on top of
the inherited `Extractor` default — the combined system prompt steers the model toward
concise professional prose. `GenerateText()` is used (not `CreateObject()`) because the
output is a plain string, not a structured object.

If the LLM call fails, the fallback string ensures the terminal always produces a
usable result.

**Final blackboard:**
```
Blackboard
  source      →  InvoiceSource
  invoice     →  InvoiceData ( vendor: "Acme Corp", amount: 1250.00, date: 20260305 )
  extraction  →  ExtractionValidation ( valid: .T. )
  vendor      →  VendorRecord ( id: "V-100", name: "Acme Corp" )
  duplicate   →  DuplicateCheck ( duplicate: .F. )
  match       →  ThreeWayMatch ( needsApproval: .T. )
  approval    →  ApprovalRequest
                   queue:    "ap-approval-manager"
                   priority: "P3"
                   reason:   "amount over auto-post threshold"
                   message:  "Please review and approve invoice INV-1001..."
```

`ProcessOne()` reads `oResult:get("approval")` and prints all four fields.

---

## Part 3 — How Classes Describe Themselves

In Part 2 you saw `oRunner := oCtx:ai()` with no `Instruction():create()` block, and
the blackboard showing `date: 20260305` as a real Xbase++ Date rather than a string.
This part explains exactly how: the mechanism that connects `InvoiceData:initClass()`
to the LLM schema instruction and to `Bind()` type coercion.

### The Problem This Solves

When `PromptRunner:createObject()` asks the LLM to return a JSON object, it needs to
tell the model what fields to include, what types they should have, and what they mean.
Without guidance the LLM sometimes returns a number as a quoted string, omits a field
entirely, or returns a date in an unpredictable format.

The old approach was to write an `Instruction():create(...)` block in the action method:

```xbase
// Old approach — schema knowledge scattered into action code
oRunner := oCtx:ai() ;
           :withPromptContributor( Instruction():create( ;
              "Extract the following fields:" + CRLF + ;
              "  amount: the total invoice amount as a raw JSON number" + ... ) )
```

This scattered field knowledge across the calling code, repeated it for every class, and
still did nothing about type coercion when the LLM ignored the instruction.

### `initClass()` and `addHint()`

Every `AbstractCard` subclass that is passed to `CreateObject()` declares its own
schema in a `CLASS METHOD initClass()`. This runs **once per class**, never per instance:

```xbase
CLASS InvoiceData FROM AbstractCard
   EXPORTED:
   VAR vendor
   VAR invoiceNumber
   VAR poNumber
   VAR date
   VAR amount
   VAR currency
   VAR bankAccount
   VAR recipient
   CLASS METHOD initClass()
   METHOD init()
ENDCLASS

CLASS METHOD InvoiceData:initClass()
   ::addHint( "vendor",        "C", "the supplier or vendor name" )
   ::addHint( "invoiceNumber", "C", "the invoice identifier" )
   ::addHint( "poNumber",      "C", "the purchase order number, empty string if absent" )
   ::addHint( "date",          "D", "the invoice date as YYYYMMDD string, e.g. 20260115 — no separators" )
   ::addHint( "amount",        "N", "the total invoice amount as a raw JSON number, e.g. 1250.00" )
   ::addHint( "currency",      "C", "the ISO 4217 currency code, e.g. EUR, GBP" )
   ::addHint( "bankAccount",   "C", "the IBAN or account number for payment, empty string if absent" )
   ::addHint( "recipient",     "C", "the invoice recipient name, empty string if not stated" )
RETURN Self

METHOD InvoiceData:init()
   ::vendor        := ""
   ::invoiceNumber := ""
   ::poNumber      := ""
   ::date          := CToD( "" )
   ::amount        := 0
   ::currency      := ""
   ::bankAccount   := ""
   ::recipient     := ""
RETURN Self
```

`addHint( cMember, cValType, cHint )` takes three arguments:
- **`cMember`** — the field name (case-insensitive)
- **`cValType`** — a single `ValType()` character: `"C"`, `"N"`, `"L"`, `"D"`
- **`cHint`** — optional human-readable description; pass `""` when a type alone is sufficient

The hints are stored as a `CLASS VAR` — per subclass, not per instance. `initClass()`
is called once when the class is first used. `Init()` is now just safe defaults: no
hints, no NIL guards, no parameters.

### What the LLM Sees

When `CreateObject( cPrompt, "InvoiceData" )` is called, `SchemaInstruction()` reads
the class-level hints via `ClassObject("InvoiceData"):getHints()` — no instance
creation needed — and builds this field list automatically:

```
Respond ONLY with a single JSON object with these fields:
  vendor (string): the supplier or vendor name
  invoiceNumber (string): the invoice identifier
  poNumber (string): the purchase order number, empty string if absent
  date (string): the invoice date as YYYYMMDD string, e.g. 20260115 — no separators
  amount (number): the total invoice amount as a raw JSON number, e.g. 1250.00
  currency (string): the ISO 4217 currency code, e.g. EUR, GBP
  bankAccount (string): the IBAN or account number for payment, empty string if absent
  recipient (string): the invoice recipient name, empty string if not stated
No markdown, no explanation.
```

`date` appears as `(string)` because JSON has no native date type — but the description
carries the format contract. `amount` appears as `(number)`, enforcing that the LLM
must not quote it.

Classes without an `initClass()` fall back to member enumeration from a fresh instance,
preserving backward compatibility.

### Type Coercion in `Bind()`

When the JSON reply is bound onto the target instance, `Bind()` looks up each member's
declared hint type. If the incoming JSON value is a character string but the hint
declares a different type, it coerces automatically:

| Hint type | JSON value | Coercion |
|---|---|---|
| `"D"` | `"20260115"` | `SToD( value )` → Xbase++ Date |
| `"N"` | `"1250.00"` | `Val( value )` → Numeric |
| `"L"` | `"true"` / `"false"` | `Lower(...) == "true"` → Logical |

The `"D"` coercion always fires since JSON has no date type — the LLM always returns a
string. The `"N"` and `"L"` coercions are safety nets for the known failure mode where
a model ignores the `(number)` / `(boolean)` instruction and returns a quoted value.

The guard `ValType( xValue ) == "C"` means correctly-typed JSON values pass through
unchanged. Coercion only fires for the divergence cases.

After binding, `oInv:date` is a real Xbase++ Date, ready for `DToC()`, date arithmetic,
or DBF date field assignment — no manual parsing anywhere in the agent.

### `Init()` Defaults Match the Declared Type

`Init()` sets `::date := CToD("")` (an empty Date, not `""`). This keeps the member
type-consistent before binding: a `D` field is always a Date, whether it was just
constructed or has been bound from LLM output.

---

## Part 4 — The Other Six Scenarios

Each scenario is described only by where it **diverges** from the Acme path in Part 2.

---

### Scenario 1 — `sample-autopost`: Below the Threshold

**Invoice:** Northwind Traders · INV-3003 · PO-1003 · 275.00 EUR (image)

Full pipeline. In `matchToPO`, delta is 0.00 and `275.00 <= 500.00` → `autoPostable`.
Guards: `IsHardMismatch` → `.F.`; `NeedsApproval` → `.F.`; NIL fallthrough → `autoPost`.

```xbase
METHOD ApInvoiceAgent:autoPost( oCtx )
   LOCAL oInv   := oCtx:get( "invoice" )
   LOCAL oPost  := PostingResult():New()
   oPost:ledgerEntryId := "LED-" + oInv:invoiceNumber
   oPost:postedAt      := DToC( Date() ) + " " + Time()
   oPost:message       := "Posted " + AllTrim( Str( oInv:amount, 12, 2 ) ) + " " + oInv:currency + " to ledger"
RETURN oPost
```

---

### Scenario 2 — `sample-approval`: Above the Threshold

**Invoice:** Contoso Ltd · INV-2002 · PO-1002 · 3,400.00 EUR (image)

Full pipeline. Delta 0.00, within tolerance, `3400.00 > 500.00` → `needsApproval`.
`routeForApproval` routes to `ap-approval-manager` (P3) and drafts an LLM message.

---

### Scenario 3 — `sample-duplicate`: Stops at `checkDuplicate`

**Invoice:** Acme Corp · INV-DUP-42 · PO-1001 · 1,250.00 GBP (image)

`lookupVendor` finds V-100. `checkDuplicate` calls `IsInvoiceRegistered("V-100", "INV-DUP-42")`
→ `.T.`. `IsDuplicate` fires → `raiseException`.

In `RaiseException`, `oDup:duplicate` is `.T.`:
```
cCategory := "duplicate"
cSummary  := "Invoice already posted: INV-DUP-42"
```

`matchToPO` never runs.

---

### Scenario 4 — `sample-hard-mismatch`: Stops at `matchToPO`

**Invoice:** Northwind Traders · INV-3999 · PO-1003 · 999.99 EUR (image)

`matchToPO`: PO-1003 total is 275.00 EUR. `nDelta = 724.99`. `Abs(724.99) > 0.50` →
outside tolerance. `oMatch:hardMismatch := .T.`. Guard `IsHardMismatch` fires →
`raiseException`:

```
cCategory := "hard-mismatch"
cSummary  := "amount differs from PO by 724.99"
```

---

### Scenario 5 — `sample-unknown-vendor`: No LLM Match Found

**Invoice (text):** Widgets and Co · INV-WC-001 · 500.00 USD

`lookupVendor` returns `NIL` for both name and IBAN. `IsVendorUnknown` fires →
`proposeVendorMatch`.

The LLM sees the active vendor list (Acme Corp, Contoso Ltd, Northwind Traders) and
the name "Widgets and Co". There is no plausible match. It returns `vendorId: ""`.
`ProposeVendorMatch` returns `NIL`. NIL guard fires → `raiseException`:

```
cCategory := "unknown-vendor"
cSummary  := "Vendor not in master: Widgets and Co"
```

---

### Scenario 6 — `sample-acme-approval`: Text Invoice, Full Pipeline

**Invoice (text):** Acme Corp · INV-1001 · PO-1001 · 1,250.00 GBP

This is the scenario traced in detail in Part 2.

---

### Scenario 7 — `sample-fuzzy-vendor`: LLM Fuzzy Match → Human Review

**Invoice (text):** Acme Corporation · INV-CORP-001 · PO-1001 · 750.00 GBP

`lookupVendor`: `FindByName("Acme Corporation")` → `NIL` (exact match fails).
No bank account in text → IBAN fallback skipped. `IsVendorUnknown` fires →
`proposeVendorMatch`.

```xbase
METHOD ApInvoiceAgent:proposeVendorMatch( oCtx )
   LOCAL oInv        := oCtx:get( "invoice" )
   LOCAL aVendors    := ::vendorMaster:getActiveVendors()
   LOCAL cVendorList := ""
   LOCAL oSuggestion, oVendor, oProposal, nI

   FOR nI := 1 TO Len( aVendors )
      cVendorList += "  " + aVendors[nI]:id + ": " + aVendors[nI]:Name + CRLF
   NEXT

   oSuggestion := oCtx:ai() ;
                  :withPromptContributor( ApInvoicePersonas():vendorMatcher() ) ;
                  :createObject( ;
                     "The vendor name '" + oInv:vendor + "' was not found in the master." + CRLF + ;
                     "Known active vendors:" + CRLF + cVendorList + ;
                     "Return the ID of the best matching vendor if one clearly matches. " + ;
                     "Return empty vendorId if no confident match exists.", ;
                     "VendorMatchSuggestion" )

   IF oSuggestion == NIL .OR. Empty( oSuggestion:vendorId )
      RETURN NIL
   ENDIF

   oVendor := ::vendorMaster:findById( oSuggestion:vendorId )
   IF oVendor == NIL
      RETURN NIL
   ENDIF

   oProposal                := VendorProposal():New()
   oProposal:proposedVendor := oVendor
   oProposal:reason         := oSuggestion:reason
RETURN oProposal
```

`VendorMatchSuggestion` is an `AbstractCard` subclass with its own `initClass()`:

```xbase
CLASS METHOD VendorMatchSuggestion:initClass()
   ::addHint( "vendorId", "C", "ID of the best matching vendor, empty string if no confident match" )
   ::addHint( "reason",   "C", "brief explanation of the proposed match" )
RETURN Self
```

The LLM receives the active vendor list and returns `{ "vendorId": "V-100", "reason":
"Acme Corporation is the full legal name of Acme Corp." }`. `FindById("V-100")` resolves
the record. `HasVendorProposal` fires → `awaitVendorApproval`.

```xbase
METHOD ApInvoiceAgent:awaitVendorApproval( oCtx )
   LOCAL oProposal := oCtx:get( "vendorProposal" )
   LOCAL oInv      := oCtx:get( "invoice" )
   LOCAL oReq      := VendorApprovalRequest():New()
   oReq:proposedVendor := oProposal:proposedVendor
   oReq:reason         := oProposal:reason
   oReq:invoiceVendor  := oInv:vendor
RETURN oReq
```

This is a **terminal state** — the agent hands off to a human. The AP clerk reviews
the proposal out of band (approval workflow, email, ERP queue). If they accept, the
invoice is resubmitted with the corrected vendor name; if they reject, it is raised as
an exception through a separate process.

> **Why terminal and not a loop-back?** Looping back after human input requires
> pausing the agent mid-run, which breaks the stateless batch model. Every human
> decision point in this agent is a terminal — the agent stops and produces a record
> for whatever system manages the human workflow. The framework stays simple.

---

## Part 5 — The Three Files and When You Touch Each

### `ap-invoice-agent-common.prg` — Domain Types and Data Providers

**Open this file when** you are adding or changing what data lives on the blackboard,
changing the schema the LLM sees, or connecting real data sources.

**Class pattern — everything follows the same template:**

```xbase
CLASS MyResult FROM AbstractCard
   EXPORTED:
   VAR field1
   VAR field2
   METHOD init()      // safe defaults only — no parameters
ENDCLASS

METHOD MyResult:init()
   ::field1 := ""
   ::field2 := 0
RETURN Self
```

For LLM-populated classes, add `CLASS METHOD initClass()` with `addHint()` calls
(see Part 3 for the full explanation):

```xbase
CLASS METHOD MyExtraction:initClass()
   ::addHint( "name",   "C", "the entity name" )
   ::addHint( "amount", "N", "total as a raw JSON number" )
RETURN Self
```

Producers construct objects with direct assignment — no constructor parameters:

```xbase
LOCAL oResult := MyResult():New()
oResult:field1 := "value"
oResult:field2 := 42
```

**Data providers** (`VendorMaster` / `DemoVendorMaster`, `PurchaseOrderBook` /
`DemoPurchaseOrderBook`) are the most common adaptation point. The base classes define
the interface; Demo subclasses supply in-memory fixtures. A real implementation
subclasses the base without touching the agent flow.

### `ap-invoice-agent.prg` — The Flow and the Logic

**Open this file when** you are changing how the agent makes decisions, adding a new
state, or changing what the LLM is asked.

`onRegister()` is the single source of truth for the flow. Every state name, every
blackboard slot name, and every guard name is declared there. Read it first when
navigating the agent.

Action methods follow a consistent contract:
- Receive `oCtx`, read their declared inputs with `oCtx:get()`
- Build a result object with `ClassName():New()` and direct field assignment
- Return it — the framework writes it to the declared output slot

LLM-calling actions (`Extract`, `ProposeVendorMatch`, `RouteForApproval`) use
`oCtx:ai()` which inherits the agent's default LLM and persona. Per-call overrides
are chained: `:withPromptContributor()`, `:withImage()`, `:withMessage()`.

### `ap-invoice-main.prg` — Loading and Reporting

**Open this file when** you are changing how invoices are loaded or how results are
reported.

`ProcessOne()` checks which terminal blackboard key is populated and prints accordingly.
In a production system this is where you replace console output with ERP writes,
message queue posts, or audit log entries. The four terminal keys are:

| Key | Terminal state | Meaning |
|---|---|---|
| `posting` | `autoPost` | Invoice posted to ledger |
| `approval` | `routeForApproval` | Invoice routed for human approval |
| `vendorApproval` | `awaitVendorApproval` | Vendor match proposed, awaiting human confirmation |
| `exception` | `raiseException` | Processing failed, exception raised |

---

## Part 6 — Adaptation Recipes

### Recipe 1 — Connect Your Real Vendor Database

Subclass `VendorMaster` and override `FindByName()`, `FindByBank()`, `FindById()`, and
`GetActiveVendors()`. Swap the subclass in `Main()`:

```xbase
LOCAL oAgent := ApInvoiceAgent():New( LiveVendorMaster():New(), DemoPurchaseOrderBook():New() )
```

`GetActiveVendors()` is called by `ProposeVendorMatch` to build the vendor list for
the fuzzy-match LLM prompt. It must return an array of active `VendorRecord` objects.

### Recipe 2 — Add a Fourth Approval Tier

In `RouteForApproval()`, extend the `DO CASE`:

```xbase
CASE oInv:amount <= 100000
   cQueue := "ap-approval-cfo"    ; cPri := "P1"
OTHERWISE
   cQueue := "ap-approval-board"  ; cPri := "P0"
```

### Recipe 3 — Raise the Auto-Post Threshold

Pass it at construction:

```xbase
LOCAL oAgent := ApInvoiceAgent():New( ;
   DemoVendorMaster():New(),      ;   // vendor master
   DemoPurchaseOrderBook():New(), ;   // PO book
   NIL,                           ;   // LLM options (NIL = use default)
   3,                             ;   // maxAttempts
   2000.00,                       ;   // autoPostThreshold  ← your value
   0.50 )                             // amountTolerance
```

### Recipe 4 — Switch to a Different LLM

```xbase
LOCAL oLLM   := LLMOptions():withModel( AnthropicModels():CLAUDE_SONNET_4_6 ):withTemperature( 0 )
LOCAL oAgent := ApInvoiceAgent():New( DemoVendorMaster():New(), DemoPurchaseOrderBook():New(), oLLM )
```

All three LLM calls (`Extract`, `ProposeVendorMatch`, `RouteForApproval`) inherit the
agent default, so one change covers all three.

### Recipe 5 — Add a New LLM-Populated Class

1. Derive from `AbstractCard`
2. Declare `VAR` members, `CLASS METHOD initClass()`, and `METHOD init()`
3. In `initClass()`, call `addHint( cMember, cValType, cHint )` for every field
4. In `Init()`, set safe typed defaults matching the declared types
5. Pass the class name to `CreateObject()` — schema generation and type coercion are
   automatic

```xbase
CLASS LineItems FROM AbstractCard
   EXPORTED:
   VAR description
   VAR unitPrice
   VAR quantity
   VAR taxRate
   CLASS METHOD initClass()
   METHOD init()
ENDCLASS

CLASS METHOD LineItems:initClass()
   ::addHint( "description", "C", "line item description" )
   ::addHint( "unitPrice",   "N", "unit price as a raw JSON number" )
   ::addHint( "quantity",    "N", "quantity as a raw JSON number" )
   ::addHint( "taxRate",     "N", "VAT/tax rate as a percentage, e.g. 20.0" )
RETURN Self

METHOD LineItems:init()
   ::description := ""
   ::unitPrice   := 0
   ::quantity    := 0
   ::taxRate     := 0
RETURN Self
```

---

## Part 7 — When Things Go Wrong

### Problem: No API Key

**Symptom:** Every invoice prints `AP processing failed: Mistral API request failed: 401 Unauthorized`.

**Fix:** Add your Mistral key to `apikey.bat` and call it before running.

---

### Problem: LLM Returns Wrong Date Format

**Symptom:** `oInv:date` is an empty or wrong date. The LLM returned `"2026-03-05"` or
`"5 Mar 2026"` instead of `"20260115"`.

**Why it happens:** The schema instruction says `date (string): the invoice date as
YYYYMMDD string, e.g. 20260115 — no separators`. If the model ignores this, `SToD()`
receives a non-8-char string and returns an empty date. `ValidateExtract` then catches
`Empty( oInv:date )` and triggers a retry — the error message `"missing date"` is
injected back to the LLM, which usually fixes the format on the next attempt.

If retries fail after `maxAttempts`, the flow routes to `raiseException` with category
`"extraction"`.

---

### Problem: Fuzzy Match Routes Wrong Vendor

**Symptom:** `awaitVendorApproval` proposes an incorrect vendor.

**Why it happens:** The LLM matched on a superficial similarity. The `VendorMatcher`
persona instructs the model to be conservative ("only return an ID when clearly
matching"), but models vary. The human approval step exists precisely to catch this —
the AP clerk reviews the proposal before any processing continues.

**If false positives are frequent:** Add the exact vendor name variants to the master
data so `FindByName()` handles them without the LLM step.

---

### Problem: Vendor Is Not Found — But It Should Be

**Symptom:** `proposeVendorMatch` returns `NIL` and the flow routes to `raiseException`
as unknown-vendor, even though the vendor exists.

**Diagnosis path:**
1. The LLM returned a `vendorId` that `FindById()` could not resolve — check that the
   ID exists in `DemoVendorMaster:init()` (or your live data source)
2. The vendor is marked `active := .F.` — `GetActiveVendors()` excludes inactive records
3. The LLM returned `vendorId: ""` — the name on the invoice is too dissimilar. Add the
   trading name variant to the master or supply an IBAN so the name-fallback path in
   `LookupVendor` catches it first

---

*End of Annotated Code Tour*

*Three files. Three LLM calls. All guards are pure Xbase++.*
