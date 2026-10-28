# Xbase++ V3 Agentic AI — Use Case Project

This project is a deep-dive **use case** companion to the Xbase++ V3 **Agentic AI
Core** framework's core examples. Instead of many small, isolated building blocks, it
ships two complete, realistic line-of-business agents built end-to-end on top of the
same framework — and nothing else:

- **`ap-invoice-agent.exe`** — Accounts Payable Invoice Automation. Extracts invoice
  fields from plain text *and* scanned invoice images, looks up the vendor, checks for
  duplicates, three-way-matches against a purchase order, and auto-posts, routes for
  human approval, or raises an exception ticket.
- **`bulk-operation.exe`** — Natural-Language Bulk Database Operation Preparation.
  Turns a free-text request into a reviewable, human-approved batch of SQL `UPDATE`
  statements against a live PostgreSQL Northwind database, with an advisory
  revenue/inventory critic in the loop before every approval.

Both agents are explicit `AbstractAgent` finite-state machines declared in
`onRegister()` — the framework builds and drives the flow; every routing decision
(guard) and deterministic business step is plain Xbase++, and only the states that
need judgement call the LLM.

> **No API key? No problem.** By default, every LLM call in this project is resolved
> through the **Alaska Software LLM Router**, which is free of charge for any active
> Xbase++ V3 license. That means **this project runs out of the box**.

## What's In

### Accounts Payable Invoice Automation (`ap-invoice-agent.exe`, folder `ap-invoice/`)

Reads an invoice from plain text or a scanned image and decides what to do with it.
An LLM call extracts the invoice fields (vendor, invoice number, PO number, amount,
currency, bank account); every following step is deterministic Xbase++: validate the
extraction, look up the vendor in the master (with an LLM-assisted fuzzy match and
human approval step when the name doesn't match exactly), check for a duplicate
posting, and three-way-match the amount against the referenced purchase order. The
agent terminates by auto-posting, routing to a human approval queue, or raising an
exception ticket. Sample invoices (4 generated images + 3 text) are loaded from
`ap-invoice-samples.config`, next to the sources in `ap-invoice/`.

### Natural-Language Bulk Database Operation Preparation (`bulk-operation.exe`, folder `bulk-operation/`)

Turns a free-text request (e.g. "increase the price of the top 5 best-selling
products by 10%") into a reviewable batch of SQL `UPDATE` statements against a live
PostgreSQL Northwind database. An LLM call classifies the request, then an LLM with
a SQL query tool inspects the actual data and computes the proposed changes. For
price and stock changes, a second advisory LLM call critiques the proposal (revenue/
margin impact or inventory/cash-flow risk) before a human reviews the change table and
approves, rejects with feedback (the agent retries), or aborts. Approved changes are
written to a transaction-wrapped `.sql` file. Sample tasks are loaded from
`bulk-operation-tasks-en.config` / `bulk-operation-tasks-de.config`, next to the
sources in `bulk-operation/`; a PostgreSQL seed script for the Northwind database is
provided in `bulk-operation/data/northwind.postgresql.sql`.

Both agents are explicit `AbstractAgent` finite-state machines declared in
`onRegister()`, ship with a fully annotated code tour (`ap-invoice-agent-tour.md` /
`bulk-operation-agent-tour.md`), and are built by `project.xpj` — each into its own
use-case folder.

## Build and Run

**1. Install assets and build**

```bat
xppam PROJECT -install
pbuild project.xpj
```

Each target in `project.xpj` builds its `.exe` into its own use-case folder
(`ap-invoice/` or `bulk-operation/`), next to that use case's `.prg` sources and
`.config` sample-data files — there is no separate output folder to hunt through.

**2. Run an example**

```bat
cd ap-invoice
ap-invoice-agent.exe
```

Processes all 7 invoice samples from `ap-invoice-samples.config` (image-based and
text-based) and prints the agent's decision for each one: auto-posted, routed for
approval, awaiting vendor-match approval, or an exception.

```bat
cd bulk-operation
bulk-operation.exe
```

Connects to a local PostgreSQL Northwind database (see `cConnect` in
`bulk-operation-main.prg`; seed it with `data/northwind.postgresql.sql`) and runs the
five English sample tasks from `bulk-operation-tasks-en.config` interactively,
prompting Y / R / A after every proposed change table. Pass
`bulk-operation-tasks-de.config` to run the identical five tasks in German instead —
no other change needed, the agent detects the request language and replies in kind:

```bat
bulk-operation.exe bulk-operation-tasks-de.config
```

> **`bulk-operation.exe` needs a database.** This example connects to a PostgreSQL
> server (`SERVER=localhost;DB=northwind;UID=postgres;PWD=postgres` - see `cConnect` at
> the top of `bulk-operation-main.prg` if your server uses different credentials) and
> expects the Northwind sample data to already be loaded there. Before running it, load
> `data\northwind.postgresql.sql` into a `northwind` database on your PostgreSQL server:
>
> ```bat
> createdb -U postgres northwind
> psql -U postgres -d northwind -f data\northwind.postgresql.sql
> ```
>
> Adjust `-U` (and add `-h`/`-p` as needed) to match your PostgreSQL setup.
>
> Prefer a GUI? In **pgAdmin**, create the `northwind` database (right-click
> **Databases → Create → Database…**), then select it, open
> **Tools → Query Tool**, use its **Open File** button to load
> `data\northwind.postgresql.sql`, and click **Execute/Run (F5)** to run the whole
> script against it.


**3. (Optional) Use your own API key**

By default every LLM call is resolved through the Alaska Software LLM Router, so no
key is needed. To use your own OpenAI, Anthropic, or Mistral account instead, set the
matching environment variable (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`MISTRAL_API_KEY`) before running an example, or create a `.env` file at the project
root with those variables — `project.xpj` loads it automatically via `RUNENV.FILE`,
and it is git-ignored so your keys stay local. You can also supply a key
programmatically on the LLM options for a single call or agent, e.g.
`LLMOptions():withModel( MistralModels():MISTRAL_LARGE ):withApiKey( cMyKey )`.

`ap-invoice-agent.exe` extracts invoice fields with **Mistral** (`MISTRAL_API_KEY`),
and `bulk-operation.exe` classifies, analyzes, and critiques with **Anthropic Claude**
(`ANTHROPIC_API_KEY`) — check the header comment of each `*-main.prg` for the exact
requirement. Whichever LLM call fails — wrong key, no network, rate limit — every
sample catches the error with `BEGIN SEQUENCE … RECOVER USING oError`, prints a clean
message, and continues with the next invoice or task instead of aborting the whole run.

A quick way to set the variable(s) for the current command window is a small batch
file, sourced with `call` before running an example — this is also what the code tours
assume when they say `call apikey.bat`:

```bat
@echo off
rem apikey.bat - put your own key(s) here, then run: call apikey.bat
set MISTRAL_API_KEY=<put-your-mistral-api-key-here>
set ANTHROPIC_API_KEY=<put-your-anthropic-api-key-here>
set OPENAI_API_KEY=<put-your-openai-api-key-here>
```

`apikey.bat` is git-ignored, so it is safe to keep your real keys in it locally.

## Code Tours

Both agents ship with a fully annotated, step-by-step code tour that walks through
every file, state, action, and guard alongside the blackboard contents after every
state:

- `ap-invoice-agent-tour.md` — read together with `ap-invoice-agent-common.prg`,
  `ap-invoice-agent.prg`, and `ap-invoice-main.prg`.
- `bulk-operation-agent-tour.md` — read together with `bulk-operation-common.prg`,
  `bulk-operation-tools.prg`, `bulk-operation-agent.prg`, and `bulk-operation-main.prg`.

They are the best starting point once you want to see every part of a larger agent
explained in depth, including a real sample run.
