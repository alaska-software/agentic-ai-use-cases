//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Shared domain layer for the Bulk Operation Preparation Agent example.
/// </summary>
///
/// <remarks>
/// Provides the building blocks shared with bulk-operation-agent.prg,
/// bulk-operation-tools.prg, and bulk-operation-main.prg:
///
///   ProposedChangeSet        - LLM output: the list of proposed DB changes
///   ReviewDecision           - user approval / rejection / abort result
///   WriteResult              - outcome of writing the SQL file to disk
///   OperationClassification  - classifier output: price_change / stock_order / other
///   CriticAssessment         - advisory critic output shown before human review
///   BulkTaskSource           - one task request loaded from the XML task config file
///   BulkSchemaContributor    - PromptContributor: Northwind schema for the system prompt
///   BulkOperationPersonas    - persona factories (Analyst, Classifier, PriceCritic, StockCritic)
///
/// NorthwindBulkQueryTool, ApprovalTool, and FileWriterTool live in
/// bulk-operation-tools.prg.
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "..\agentic-ai-core.ch"
#include "common.ch"
#include "dac.ch"


// ---------------------------------------------------------------------------
// Domain types
// ---------------------------------------------------------------------------

/// <summary>
/// ProposedChangeSet - the structured output of the Analyze state.
///
/// The LLM fills this via CreateObject() after querying the database:
///   summary    : human-readable description of the whole bulk operation
///   changes    : array of DataObjects, each with { description, oldValue, newValue, updateSql }
///   outputFile : suggested .sql filename written to disk on approval
///
/// Hints registered in InitClass() drive the SchemaInstruction so the LLM
/// receives typed field guidance without needing a hand-written prompt fragment.
/// </summary>
///
CLASS ProposedChangeSet FROM AbstractCard

   EXPORTED:
   VAR summary
   VAR changes
   VAR outputFile

   CLASS METHOD initClass()
   METHOD init()

   ENDCLASS


   CLASS METHOD ProposedChangeSet:initClass()
   ::addHint( "summary",    "C", "Human-readable description of what will be changed and how" )
   ::addHint( "changes",    "A", "Array of up to 10 change objects. " + ;
                                 "Each object must have exactly four fields: " + ;
                                 "description (entity name and id only, e.g. 'Chai (productid=1)'), " + ;
                                 "oldValue (current value as a raw number, e.g. 18.00), " + ;
                                 "newValue (computed new value as a raw number, e.g. 19.80), " + ;
                                 "and updateSql (a complete PostgreSQL UPDATE statement)" )
   ::addHint( "outputFile", "C", "Suggested output filename ending in .sql, " + ;
                                 "e.g. price_increase_top5_2025.sql" )
RETURN Self


METHOD ProposedChangeSet:init()
   ::summary    := ""
   ::changes    := {}
   ::outputFile := "bulk_update.sql"
RETURN Self


/// <summary>
/// ReviewDecision - the outcome of the user review step.
///
/// Three outcomes are possible:
///   Ok()         - approved  (valid=.T., aborted=.F.) -> FSM goes to write_sql
///   Fail(text)   - rejected  (valid=.F., aborted=.F.) -> FSM retries analyze
///   Abort()      - aborted   (valid=.F., aborted=.T.) -> FSM goes to aborted terminal
///
/// Extends AbstractValidationResult (valid + error) and adds an aborted flag.
/// The inherited Ok() and Fail() class methods dispatch polymorphically to
/// ReviewDecision:init(), so the aborted flag defaults to .F. for those two paths
/// without requiring overrides.
/// </summary>
///
CLASS ReviewDecision FROM AbstractValidationResult

   EXPORTED:
   VAR aborted

   METHOD init( lValid, cError, lAborted )
   CLASS METHOD abort()

ENDCLASS


METHOD ReviewDecision:init( lValid, cError, lAborted )
   DEFAULT lAborted TO .F.
   ::AbstractValidationResult:init( lValid, cError )
   ::aborted := lAborted
RETURN Self


CLASS METHOD ReviewDecision:abort()
RETURN ::New( .F., NIL, .T. )


/// <summary>
/// WriteResult - the result of writing the approved SQL file to disk.
/// </summary>
///
CLASS WriteResult FROM AbstractCard

   EXPORTED:
   VAR filePath
   VAR statementCount
   VAR message

   METHOD init()

ENDCLASS


METHOD WriteResult:init()
   ::filePath       := ""
   ::statementCount := 0
   ::message        := ""
RETURN Self


/// <summary>
/// OperationClassification - the structured output of the Classify state.
///
/// Three categories drive post-analysis routing:
///   price_change : any unitprice modification (increase, decrease, flat override)
///   stock_order  : any unitsinstock or unitsonorder modification
///   other        : everything else (e.g. marking products discontinued)
///
/// Hints registered in InitClass() drive SchemaInstruction so the LLM
/// receives typed field guidance without a hand-written prompt fragment.
/// </summary>
///
CLASS OperationClassification FROM AbstractCard

   EXPORTED:
   VAR category    // "price_change" | "stock_order" | "other"
   VAR language    // natural language of the request, e.g. "English" | "German"

   CLASS METHOD initClass()
   METHOD init()

   ENDCLASS


   CLASS METHOD OperationClassification:initClass()
   ::addHint( "category", "C", ;
      "one of: price_change | stock_order | other. " + ;
      "Use price_change for any unitprice modification " + ;
      "(increase, decrease, or flat price override). " + ;
      "Use stock_order for any unitsinstock or unitsonorder modification. " + ;
      "Use other for everything else (e.g. marking products discontinued, " + ;
      "updating product names, changing suppliers)." )
   ::addHint( "language", "C", ;
      "the natural language of the request text, e.g. 'English' or 'German'. " + ;
      "Detect it from the phrasing and vocabulary of the request." )
RETURN Self


METHOD OperationClassification:init()
   ::category := "other"
   ::language := "English"   // safe default; overwritten by the LLM on every real call
RETURN Self


/// <summary>
/// CriticAssessment - the advisory output of a critic state.
///
/// Displayed to the human reviewer between the change table and the
/// Y / R / A prompt. outlook drives the visual marker shown by ApprovalTool:
///   positive -> [+]   neutral -> [ ]   caution -> [~]   concern -> [!]
///
/// projectedImpact is a quantified one-sentence projection that includes
/// any business-pattern adjustment (demand elasticity, uplift, etc.).
/// riskNote names the dominant pattern applied; empty when none applies.
/// </summary>
///
CLASS CriticAssessment FROM AbstractCard

   EXPORTED:
   VAR outlook           // "positive" | "neutral" | "caution" | "concern"
   VAR projectedImpact   // quantified one-sentence projection
   VAR riskNote          // business pattern or risk identified, or ""
   VAR summary           // 2-3 sentence advisory for the human reviewer

   CLASS METHOD initClass()
   METHOD init()

   ENDCLASS


   CLASS METHOD CriticAssessment:initClass()
   ::addHint( "outlook", "C", ;
      "one of: positive | neutral | caution | concern" )
   ::addHint( "projectedImpact", "C", ;
      "quantified one-sentence projection after applying the dominant " + ;
      "business pattern, e.g. '+$12,400 projected annual revenue' or " + ;
      "'-$9,400 direct revenue, offset by estimated +12% demand uplift => net -$2,600' or " + ;
      "'3.2 months additional stock coverage added'" )
   ::addHint( "riskNote", "C", ;
      "one identified business pattern or risk (price elasticity, " + ;
      "demand suppression, demand uplift, margin squeeze, " + ;
      "overstock cash-flow risk, competitive positioning, etc.); " + ;
      "empty string when none applies" )
   ::addHint( "summary", "C", ;
      "2-3 sentence advisory for the human reviewer covering " + ;
      "direction, magnitude, and the dominant risk or opportunity" )
RETURN Self


METHOD CriticAssessment:init()
   ::outlook         := "neutral"
   ::projectedImpact := ""
   ::riskNote        := ""
   ::summary         := ""
RETURN Self


/// <summary>
/// BulkTaskSource - one natural-language bulk-operation request loaded from
/// the task config file, handed to the driver's RunTask() loop.
/// </summary>
///
CLASS BulkTaskSource FROM AbstractCard

   EXPORTED:
   VAR text
   VAR label

   METHOD init()

ENDCLASS


METHOD BulkTaskSource:init()
   ::text  := ""
   ::label := ""
RETURN Self


// ---------------------------------------------------------------------------
// Config loading
//
// Loads the natural-language task descriptions from an external XML config
// file instead of a compile-time #if EN/DE switch. Same language-agnostic
// loader idiom used by ap-invoice (LoadInvoiceSources) and support-triage
// (LoadInboundMessages): MemoRead() + XmlSimpleParser() honor the file's
// declared <?xml encoding="..."?> prolog, so this code is identical for the
// -en and -de task config variants -- only the data file changes.
// ---------------------------------------------------------------------------

/// <summary>
/// Read the XML task config and turn each <task> element into a BulkTaskSource.
/// </summary>
/// <remarks>
/// Returns an empty array (and prints why) when the file is missing/empty or
/// the XML is malformed.
/// </remarks>
/// <param name="cConfigFile">path to the XML config file</param>
/// <returns>array of BulkTaskSource</returns>
///
FUNCTION LoadBulkTasks( cConfigFile )
   LOCAL cXml := MemoRead( cConfigFile )
   LOCAL oXml
   LOCAL aNodes
   LOCAL aOut := {}
   LOCAL nI
   LOCAL oError

   IF Empty( cXml )
      ? "Config file not found or empty:", cConfigFile
      RETURN aOut
   ENDIF

   BEGIN SEQUENCE
      oXml   := XmlSimpleParser( cXml )
      aNodes := oXml:tasks:task

      IF ValType( aNodes ) == "O"
         aNodes := { aNodes }
      ENDIF

      FOR nI := 1 TO Len( aNodes )
         AAdd( aOut, NodeToBulkTask( aNodes[nI] ) )
      NEXT
   RECOVER USING oError
      ? "Failed to parse " + cConfigFile + ":", oError:description
      aOut := {}
   END SEQUENCE

RETURN aOut


/// <summary>
/// Build a BulkTaskSource from an XML task node.
/// </summary>
/// <remarks>
/// <internal> is documentation only (which scenario/branch the task
/// exercises) and is deliberately not read here, matching the convention
/// used by the other config-driven samples.
/// </remarks>
/// <param name="oNode">parsed XML task node</param>
/// <returns>BulkTaskSource</returns>
///
FUNCTION NodeToBulkTask( oNode )
   LOCAL oTask := BulkTaskSource():New()
   oTask:text  := AllTrim( oNode:text )
   oTask:label := AllTrim( oNode:label )
RETURN oTask


// ---------------------------------------------------------------------------
// BulkSchemaContributor
//
// Injects the Northwind schema into the system prompt so the LLM knows
// which tables and columns exist before it writes its queries and UPDATE
// statements. Emphasises the columns that bulk operations typically target.
// ---------------------------------------------------------------------------

CLASS BulkSchemaContributor FROM PromptContributor

   EXPORTED:
   METHOD init()
   METHOD contribution()

ENDCLASS


METHOD BulkSchemaContributor:init()
   ::PromptContributor:init()
   ::Role := "NorthwindBulkSchema"
RETURN Self


METHOD BulkSchemaContributor:contribution()
   LOCAL cSchema

   cSchema  := "=== Northwind PostgreSQL Schema ===" + CRLF
   cSchema  += "IMPORTANT: all column names are lowercase with NO underscores." + CRLF
   cSchema  += "TABLE products    (productid INT PK, productname VARCHAR(40), " + ;
               "supplierid INT, categoryid INT, " + ;
               "unitprice DECIMAL, unitsinstock SMALLINT, unitsonorder SMALLINT, " + ;
               "reorderlevel SMALLINT, discontinued INT)" + CRLF
   cSchema  += "TABLE categories  (categoryid INT PK, categoryname VARCHAR(15), description TEXT)" + CRLF
   cSchema  += "TABLE suppliers   (supplierid INT PK, companyname VARCHAR(40), country VARCHAR(15))" + CRLF
   cSchema  += "TABLE customers   (customerid VARCHAR(5) PK, companyname VARCHAR(40), " + ;
               "contactname VARCHAR(30), city VARCHAR(15), country VARCHAR(15))" + CRLF
   cSchema  += "TABLE orders      (orderid INT PK, customerid VARCHAR(5), employeeid INT, " + ;
               "orderdate DATE, shippeddate DATE)" + CRLF
   cSchema  += "TABLE order_details (orderid INT, productid INT, " + ;
               "unitprice DECIMAL, quantity SMALLINT, discount REAL)" + CRLF
   cSchema  += "-- Revenue formula: od.unitprice * od.quantity * (1 - od.discount)" + CRLF
   cSchema  += CRLF
   cSchema  += "=== Columns that bulk operations typically UPDATE ===" + CRLF
   cSchema  += "products: unitprice, unitsinstock, unitsonorder, reorderlevel, discontinued" + CRLF
   cSchema  += CRLF
   cSchema  += "=== PostgreSQL notes ===" + CRLF
   cSchema  += "Escape the cast operator: write \\:: instead of :: " + ;
               "(e.g. SUM(...)\\::NUMERIC). " + CRLF
   cSchema  += "CAST(expr AS type) is an alternative that needs no escaping." + CRLF
   cSchema  += "CTEs are fully supported: WITH name AS (SELECT ...) SELECT ..."

RETURN cSchema


// ---------------------------------------------------------------------------
// BulkOperationPersonas
// ---------------------------------------------------------------------------

CLASS BulkOperationPersonas

   EXPORTED:
   CLASS METHOD analyst()
   CLASS METHOD classifier()
   CLASS METHOD priceCritic()
   CLASS METHOD stockCritic()

ENDCLASS


CLASS METHOD BulkOperationPersonas:analyst()
RETURN RoleGoalBackstory():create( ;
   "Database bulk-operations specialist for Northwind Traders", ;
   "Translate natural-language bulk update requests into a precise, " + ;
   "reviewable set of SQL UPDATE statements by querying the live database " + ;
   "to find the exact affected rows and computing the new values as specified", ;
   "Meticulous SQL expert who always queries first and never guesses data values; " + ;
   "strict about rounding rules, primary-key targeting, and generating clean " + ;
   "PostgreSQL UPDATE statements with no markdown fences" )


   /// <summary>
   /// Persona for the classify step: a lightweight intent classifier that
   /// focuses solely on which column is being modified.
   /// </summary>
   ///
   CLASS METHOD BulkOperationPersonas:classifier()
   RETURN RoleGoalBackstory():create( ;
      "Bulk database operation classifier",                                        ;
      "Identify the primary type of bulk change in a natural-language request",    ;
      "Focuses solely on which column is being modified and ignores all " +         ;
      "filter, selection, rounding, and sorting criteria" )


   /// <summary>
   /// Persona for the price-change critic: a revenue analyst who applies
   /// standard business patterns to the historical data it queries.
   /// </summary>
   ///
   CLASS METHOD BulkOperationPersonas:priceCritic()
   RETURN RoleGoalBackstory():create( ;
      "Revenue and profit analyst",                                                 ;
      "Project the revenue, margin, and demand impact of any proposed price " +     ;
      "change and flag the dominant business risk or opportunity",                  ;
      "Applies standard business patterns -- price elasticity, margin analysis, " + ;
      "demand uplift and suppression, competitive positioning, commodity vs. " +    ;
      "branded product behaviour -- grounded in actual 12-month sales data " +      ;
      "queried live from the database" )


   /// <summary>
   /// Persona for the stock critic: an inventory analyst who expresses every
   /// recommendation in months of coverage and flags excess stock as a cash-flow risk.
   /// </summary>
   ///
   CLASS METHOD BulkOperationPersonas:stockCritic()
   RETURN RoleGoalBackstory():create( ;
      "Inventory and cash flow analyst",                                            ;
      "Assess whether a proposed stock increase is justified by actual product " +   ;
      "demand and flag any overstock cash-flow risk",                               ;
      "Grounds every recommendation in 12-month units-sold history; " +             ;
      "expresses increases as months of additional coverage and flags " +           ;
      "excess inventory as a cash flow risk" )
