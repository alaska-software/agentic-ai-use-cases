//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// BulkOperationAgent - natural-language bulk database update preparation agent.
/// </summary>
///
/// <remarks>
/// Accepts a natural-language bulk update request, queries the Northwind
/// PostgreSQL database to identify the exact affected rows, computes the
/// new values, and proposes up to 10 SQL UPDATE statements for human review.
///
/// The user reviews the proposed change table and chooses one of three actions:
///   Y - approve  : SQL is written to disk (write_sql terminal)
///   R - reject   : correction feedback is collected and the analysis retries
///   A - abort    : the task is abandoned without writing (aborted terminal)
///
/// FSM flow:
///
///   classify ------------------------------------------> analyze
///                                                           |
///                            IsPriceChange -----------------+--> critic_price --+
///                            IsStockOrder  -----------------+--> critic_stock --+
///                            NIL (other)   -----------------+                   |
///                                                                               v
///                                           <---------------------------- review
///      ^                                    |
///      |            IsApproved  --> write_sql (terminal)
///      |            IsAborted   --> aborted   (terminal)
///      |            IsExhausted --> failed    (terminal)
///      |            isRetryFor  --> merge_request
///      |                                    |
///      +------------ analyze <--------------+
///
/// classify     : LLM (Haiku, no tools) -- categorise into price_change / stock_order / other
/// analyze      : LLM + NorthwindBulkQueryTool -- produce ProposedChangeSet
/// critic_price : LLM + NorthwindBulkQueryTool -- advisory revenue/profit assessment
/// critic_stock : LLM + NorthwindBulkQueryTool -- advisory inventory/cash-flow assessment
/// review       : No LLM -- ApprovalTool displays table + assessment, reads Y/R/A
/// merge_request: LLM (Haiku, no tools) -- merge activeRequest + feedback -> activeRequest
/// write_sql    : No LLM -- FileWriterTool writes the SQL file to disk
/// aborted      : User chose A -- task skipped, loop continues
/// failed       : Retries exhausted without approval
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"

#define CRLF Chr(13)+Chr(10)

CLASS BulkOperationAgent FROM AbstractAgent

   EXPORTED:
   VAR oQueryTool       // NorthwindBulkQueryTool instance (shared by Analyze and critics)

   METHOD init( oSession, oLLMOptions )
   METHOD onRegister()

   // Action methods -- invoked by the state machine
   METHOD classify( oCtx )          // LLM (Haiku): classify request into price_change / stock_order / other
   METHOD analyze( oCtx )           // LLM + query tool: produce ProposedChangeSet from activeRequest
   METHOD critiquePrice( oCtx )     // LLM + query tool: advisory revenue/profit assessment
   METHOD critiqueStock( oCtx )     // LLM + query tool: advisory inventory/cash-flow assessment
   METHOD review( oCtx )            // ApprovalTool: display table + assessment, read user decision
   METHOD mergeRequest( oCtx )      // LLM (Haiku): merge activeRequest + feedback -> activeRequest
   METHOD writeSql( oCtx )          // FileWriterTool: write approved SQL to disk

   // Guard methods -- pure boolean, no LLM, no side effects
   METHOD isPriceChange( oCtx )     // .T. when classification is price_change
   METHOD isStockOrder( oCtx )      // .T. when classification is stock_order
   METHOD isApproved( oCtx )        // .T. when the user chose Y
   METHOD isAborted( oCtx )         // .T. when the user chose A
   METHOD isExhausted( oCtx )       // .T. when analyze attempts >= maxAttempts

ENDCLASS


/// <summary>
/// Init() - configure agent defaults and create the shared query tool.
/// </summary>
/// <param name="oSession">live DacSession to the Northwind PostgreSQL database</param>
/// <param name="oLLMOptions">LLMOptions for the Analyze state (default: Sonnet 4.6, temp 0)</param>
///
METHOD BulkOperationAgent:init( oSession, oLLMOptions )
   DEFAULT oLLMOptions TO ;
      LLMOptions():withModel( AnthropicModels():CLAUDE_SONNET_4_6 ):withTemperature( 0 )

   ::AbstractAgent:init()
   ::oQueryTool  := NorthwindBulkQueryTool():New( oSession )
   ::MaxAttempts := 3
   ::withDefaultLLM( oLLMOptions )
   ::withDefaultPersona( BulkOperationPersonas():analyst() )
RETURN Self


/// <summary>
/// onRegister() -- declare the FSM flow.
///
/// classify runs once (outside the retry loop) and puts a persistent
/// classification on the blackboard. On analyze transitions, IsPriceChange
/// and IsStockOrder read that persisted value to route to the appropriate
/// critic. Both critics flow unconditionally to review (advisory only).
///
/// The retry loop is: review (rejected) -> merge_request -> analyze.
/// merge_request merges the current effective task (activeRequest) with the
/// user's feedback into a new, complete, conflict-free activeRequest.
/// Analyze always uses activeRequest when present, so it never sees the
/// original request and the correction simultaneously.
///
/// Guard order on the review state:
///   1. IsApproved  -- takes priority when the user said Y
///   2. IsAborted   -- catches the A choice before exhaustion logic runs
///   3. IsExhausted -- catches retry limit before the generic retry guard
///   4. isRetryFor  -- the R (reject) path: goes to merge_request (not analyze)
/// </summary>
///
METHOD BulkOperationAgent:onRegister()

   ::addState( "classify", "Classify", "request", "classification" ) ;
      :onGuard( NIL, "analyze" )

   // "activeRequest?" is optional: absent on the first pass, present after
   // the first rejection (set by merge_request).
   ::addState( "analyze", "Analyze", "request, activeRequest?", "proposal" ) ;
      :onGuard( "IsPriceChange", "critic_price" ) ;
      :onGuard( "IsStockOrder",  "critic_stock"  ) ;
      :onGuard( NIL,             "review"        )

   ::addState( "critic_price", "CritiquePrice", "proposal, classification", "assessment" ) ;
      :onGuard( NIL, "review" )

   ::addState( "critic_stock", "CritiqueStock", "proposal, classification", "assessment" ) ;
      :onGuard( NIL, "review" )

   // "assessment?" is optional: absent for "other" category operations
   ::addState( "review", "Review", "proposal, assessment?", "approval" ) ;
      :onGuard( "IsApproved",                 "write_sql"     ) ;
      :onGuard( "IsAborted",                  "aborted"       ) ;
      :onGuard( "IsExhausted",                "failed"        ) ;
      :onGuard( { "isRetryFor", "approval" }, "merge_request" )

   // "activeRequest?" is optional on the first rejection (absent until
   // merge_request runs for the first time).
   ::addState( "merge_request", "MergeRequest", "approval, activeRequest?", "activeRequest" ) ;
      :onGuard( NIL, "analyze" )

   ::addState( "write_sql", "WriteSql", "proposal", "result" ) :terminal()
   ::addState( "aborted" ) :terminal()
   ::addState( "failed"  ) :terminal()

RETURN Self


// ---------------------------------------------------------------------------
// Action methods
// ---------------------------------------------------------------------------

/// <summary>
/// Classify -- lightweight intent classification (no tools).
///
/// Runs once, before the analyze/review retry loop. Puts an
/// OperationClassification on the blackboard whose category field
/// drives post-analyze routing to the appropriate critic:
///   price_change -> critic_price
///   stock_order  -> critic_stock
///   other        -> review (no critic)
///
/// Uses Haiku (fast, cheap) because this is a simple column-type
/// classification with no database access.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>OperationClassification</returns>
///
METHOD BulkOperationAgent:classify( oCtx )
   LOCAL cRequest := oCtx:get( "request" )
   LOCAL oRunner
   LOCAL oResult
   LOCAL oErr

   oRunner := oCtx:ai() ;
              :withLLM( LLMOptions():withModel( AnthropicModels():CLAUDE_HAIKU_4_5 ):withTemperature( 0 ) ) ;
              :withPromptContributor( BulkOperationPersonas():classifier() ) ;
              :withPromptContributor( Instruction():create( ;
                 "Classify the request into exactly one category:" + CRLF + ;
                 "  price_change : any modification to the unitprice column" + CRLF + ;
                 "                 (increase, decrease, or flat price override)" + CRLF + ;
                 "  stock_order  : any modification to unitsinstock or unitsonorder" + CRLF + ;
                 "  other        : everything else (e.g. setting discontinued," + CRLF + ;
                 "                 updating product names, changing supplier IDs)" + CRLF + ;
                 CRLF + ;
                 "Focus only on which column is being modified." + CRLF + ;
                 "Ignore all filter, selection, rounding, and sorting criteria." + CRLF + ;
                 CRLF + ;
                 "Also detect the natural language of the request text and " + CRLF + ;
                 "return it in the language field (e.g. 'English', 'German')." ) )

   oResult := oRunner:createObject( cRequest, "OperationClassification" )

   IF oResult == NIL
      oErr := ErrorNew()
      oErr:description := "BulkOperationAgent:classify: " + oRunner:getLastError()
      Break( oErr )
   ENDIF

RETURN oResult


/// <summary>
/// Analyze -- LLM call with NorthwindBulkQueryTool.
///
/// The LLM uses ExecuteQuery to inspect the live database, computes the
/// proposed new values as specified in the request, and returns a structured
/// ProposedChangeSet with up to 10 change records.
///
/// Each change record carries four fields:
///   description : entity name and identifier (e.g. "Chai (productid=1)")
///   oldValue    : current value as a raw number
///   newValue    : computed new value as a raw number
///   updateSql   : complete PostgreSQL UPDATE statement
///
/// On retry, activeRequest holds the merged task produced by MergeRequest --
/// a complete, conflict-free restatement of what the user currently wants.
/// On the first pass activeRequest is absent and the original request is used.
/// No WithMessage injection is needed: the correction is already baked in.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>ProposedChangeSet</returns>
///
METHOD BulkOperationAgent:analyze( oCtx )
   // First pass: activeRequest absent -> use original request.
   // Subsequent passes: activeRequest holds the merged task from MergeRequest.
   LOCAL cRequest := If( oCtx:has( "activeRequest" ), ;
                        oCtx:get( "activeRequest" ), ;
                        oCtx:get( "request" ) )
   LOCAL oRunner
   LOCAL oResult
   LOCAL oErr

   oRunner := oCtx:ai() ;
              :withPromptContributor( BulkSchemaContributor():New() ) ;
              :withPromptContributor( Instruction():create( ;
                 "You are PLANNING a bulk database update -- not executing it." + CRLF + ;
                 "Follow these steps exactly:" + CRLF + ;
                 "  1. Use ExecuteQuery one or more times to SELECT the affected records." + CRLF + ;
                 "  2. Compute the exact new values as the request specifies" + CRLF + ;
                 "     (e.g. +10%, rounded to nearest 0.50)." + CRLF + ;
                 "  3. After all queries are complete, respond with a ProposedChangeSet." + CRLF + ;
                 CRLF + ;
                 "Rules for the ProposedChangeSet:" + CRLF + ;
                 "  - Maximum 10 changes." + CRLF + ;
                 "  - Each change object must have exactly four fields:" + CRLF + ;
                 "      description : entity name and identifier only," + CRLF + ;
                 "                    e.g. 'Chai (productid=1)'" + CRLF + ;
                 "      oldValue    : the current value as a raw number, e.g. 18.00" + CRLF + ;
                 "      newValue    : the computed new value as a raw number, e.g. 19.80" + CRLF + ;
                 "      updateSql   : a complete, valid PostgreSQL UPDATE statement" + CRLF + ;
                 "                    targeting exactly one row by primary key," + CRLF + ;
                 "                    e.g. UPDATE products SET unitprice = 19.80" + CRLF + ;
                 "                         WHERE productid = 1;" + CRLF + ;
                 "  - outputFile: a short, descriptive filename ending in .sql." + CRLF + ;
                 "  - Do NOT include SELECT statements in updateSql." + CRLF + ;
                 "  - Use raw numeric literals in SQL (no markdown, no comments inside SQL)." + CRLF + ;
                 "  - Escape the PostgreSQL cast operator: write \\:: instead of ::" ) ) ;
              :withTool( ::oQueryTool )

   oResult := oRunner:createObject( cRequest, "ProposedChangeSet" )

   IF oResult == NIL
      oErr := ErrorNew()
      oErr:description := "BulkOperationAgent:analyze: " + oRunner:getLastError()
      Break( oErr )
   ENDIF

RETURN oResult


/// <summary>
/// MergeRequest -- produce a new, complete, conflict-free activeRequest.
///
/// Sits in the retry loop between review (rejected) and analyze. Its sole
/// job is to merge the current effective task with the user's correction
/// into a single, self-contained, unambiguous task description.
///
/// On the first rejection activeRequest is absent: the original request is
/// used as the baseline. On subsequent rejections the previous activeRequest
/// (already incorporating earlier corrections) is used, so refinements
/// accumulate cleanly. The output overwrites activeRequest on the blackboard.
///
/// Uses Haiku (no tools) because this is a pure text-merge task.
/// Language follows the classification already detected by Classify.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>the new activeRequest string</returns>
///
METHOD BulkOperationAgent:mergeRequest( oCtx )
   // Use the previous activeRequest as baseline when available; fall back to
   // the original request on the very first rejection.
   LOCAL cBaseRequest := If( oCtx:has( "activeRequest" ), ;
                             oCtx:get( "activeRequest" ), ;
                             oCtx:get( "request" ) )
   LOCAL cFeedback    := oCtx:get( "approval" ):Error
   LOCAL cLanguage    := oCtx:get( "classification" ):language
   LOCAL oRunner
   LOCAL cResult
   LOCAL oErr

   oRunner := oCtx:ai() ;
              :withLLM( LLMOptions():withModel( AnthropicModels():CLAUDE_HAIKU_4_5 ):withTemperature( 0 ) ) ;
              :withPromptContributor( Instruction():create( ;
                 "Respond in " + cLanguage + "." + CRLF + ;
                 CRLF + ;
                 "You are given a bulk database operation task and a user correction." + CRLF + ;
                 "Produce a single, complete, self-contained updated task description " + CRLF + ;
                 "that incorporates the correction and replaces the current task fully." + CRLF + ;
                 "The output must be unambiguous and contain all parameters needed: " + CRLF + ;
                 "what column to change, by how much or to what value, and which " + CRLF + ;
                 "products or records are affected." + CRLF + ;
                 "Output the updated task description only. No explanation, no preamble." ) )

   cResult := oRunner:generateText( ;
                 "Current task:" + CRLF + cBaseRequest + CRLF + CRLF + ;
                 "User correction:" + CRLF + cFeedback )

   IF cResult == NIL
      oErr := ErrorNew()
      oErr:description := "BulkOperationAgent.MergeRequest: " + oRunner:getLastError()
      Break( oErr )
   ENDIF

RETURN AllTrim( cResult )


/// <summary>
/// CritiquePrice -- advisory revenue and profit assessment for price changes.
///
/// Queries the last 12 months of sales history for the affected products,
/// projects the direct revenue impact, and applies standard business patterns
/// (price elasticity, demand uplift/suppression, margin analysis, commodity vs.
/// branded product behaviour). Returns a CriticAssessment that is displayed
/// to the human reviewer alongside the change table.
///
/// Reuses ::oQueryTool (SELECT-only, shared with Analyze).
/// Uses Sonnet because the revenue projection requires analytical reasoning.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>CriticAssessment</returns>
///
METHOD BulkOperationAgent:critiquePrice( oCtx )
   LOCAL oProposal := oCtx:get( "proposal" )
   LOCAL cLanguage := oCtx:get( "classification" ):language
   LOCAL oRunner
   LOCAL oResult
   LOCAL oErr

   // Language rule is an Instruction contributor, not part of the persona.
   // The persona describes WHO the model is (revenue analyst).
   // The language comes from the classification already on the blackboard --
   // a single detection in Classify drives all downstream LLM calls cleanly.
   oRunner := oCtx:ai() ;
              :withPromptContributor( BulkOperationPersonas():priceCritic() ) ;
              :withPromptContributor( Instruction():create( ;
                 "Respond in " + cLanguage + "." + CRLF + ;
                 CRLF + ;
                 "You are reviewing a proposed price change. Follow these steps:" + CRLF + ;
                 CRLF + ;
                 "STEP 1 — Query sales history" + CRLF + ;
                 "  For each product in the proposal, use ExecuteQuery to retrieve" + CRLF + ;
                 "  from the last 12 months (orderdate >= NOW() - INTERVAL '12 months'):" + CRLF + ;
                 "    - total units sold (SUM of quantity)" + CRLF + ;
                 "    - total revenue (SUM of unitprice * quantity * (1 - discount))" + CRLF + ;
                 "  Join order_details to orders on orderid to filter by date." + CRLF + ;
                 "  If a product has no sales history, note it and exclude it from projections." + CRLF + ;
                 CRLF + ;
                 "STEP 2 — Project direct revenue impact" + CRLF + ;
                 "  direct_impact = (newValue - oldValue) * annual_units_sold" + CRLF + ;
                 "  Sum across all products." + CRLF + ;
                 CRLF + ;
                 "STEP 3 — Apply the dominant business pattern" + CRLF + ;
                 "  Use your knowledge to identify and apply the most relevant pattern:" + CRLF + ;
                 "  - Price increases: typical demand suppression" + CRLF + ;
                 "    (5-15% for increases above 5%, 0-5% for smaller increases)" + CRLF + ;
                 "  - Price decreases: typical demand uplift" + CRLF + ;
                 "    (estimate based on product category and magnitude of change)" + CRLF + ;
                 "  - Consider: commodity vs. branded goods, competitive positioning," + CRLF + ;
                 "    margin impact, and any seasonality visible in the queried data." + CRLF + ;
                 "  State the adjusted net revenue projection after applying the pattern." + CRLF + ;
                 CRLF + ;
                 "STEP 4 — Return CriticAssessment" + CRLF + ;
                 "  outlook         : positive | neutral | caution | concern" + CRLF + ;
                 "  projectedImpact : adjusted net projection as a single sentence" + CRLF + ;
                 "  riskNote        : the one dominant pattern applied" + CRLF + ;
                 "  summary         : 2-3 sentence advisory for the human reviewer" ) ) ;
              :withTool( ::oQueryTool )

   oResult := oRunner:createObject( ;
                 "Assess this proposed price change:" + CRLF + Var2Json( oProposal ), ;
                 "CriticAssessment" )

   IF oResult == NIL
      oErr := ErrorNew()
      oErr:description := "BulkOperationAgent.CritiquePrice: " + oRunner:getLastError()
      Break( oErr )
   ENDIF

   RETURN oResult


/// <summary>
/// CritiqueStock -- advisory inventory and cash-flow assessment for stock increases.
///
/// Queries the last 12 months of units sold for each affected product and
/// expresses the proposed increase as months of additional stock coverage.
/// Coverage thresholds drive the outlook: < 1 month caution, 1-3 months
/// positive/neutral, 3-6 months caution, > 6 months concern.
///
/// Reuses ::oQueryTool (SELECT-only, shared with Analyze).
/// Uses Sonnet because the coverage projection requires analytical reasoning.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>CriticAssessment</returns>
///
METHOD BulkOperationAgent:critiqueStock( oCtx )
   LOCAL oProposal := oCtx:get( "proposal" )
   LOCAL cLanguage := oCtx:get( "classification" ):language
   LOCAL oRunner
   LOCAL oResult
   LOCAL oErr

   // Language rule is an Instruction contributor, not part of the persona.
   // The persona describes WHO the model is (inventory analyst).
   // The language comes from the classification already on the blackboard --
   // a single detection in Classify drives all downstream LLM calls cleanly.
   oRunner := oCtx:ai() ;
              :withPromptContributor( BulkOperationPersonas():stockCritic() ) ;
              :withPromptContributor( Instruction():create( ;
                 "Respond in " + cLanguage + "." + CRLF + ;
                 CRLF + ;
                 "You are reviewing a proposed stock increase. Follow these steps:" + CRLF + ;
                 CRLF + ;
                 "STEP 1 — Query sales history" + CRLF + ;
                 "  For each product in the proposal, use ExecuteQuery to retrieve" + CRLF + ;
                 "  from the last 12 months (orderdate >= NOW() - INTERVAL '12 months'):" + CRLF + ;
                 "    - total units sold (SUM of quantity)" + CRLF + ;
                 "  Join order_details to orders on orderid to filter by date." + CRLF + ;
                 "  If a product has no sales history, note it explicitly." + CRLF + ;
                 CRLF + ;
                 "STEP 2 — Derive monthly sales rate and coverage" + CRLF + ;
                 "  monthly_rate     = total_units_sold / 12" + CRLF + ;
                 "  months_coverage  = increase_units / monthly_rate" + CRLF + ;
                 "  (increase_units = newValue - oldValue from the proposal)" + CRLF + ;
                 CRLF + ;
                 "STEP 3 — Apply coverage thresholds" + CRLF + ;
                 "  < 1 month  : caution  (may be insufficient for demand)" + CRLF + ;
                 "  1-3 months : positive or neutral (reasonable replenishment)" + CRLF + ;
                 "  3-6 months : caution  (possibly excessive; cash tied up in inventory)" + CRLF + ;
                 "  > 6 months : concern  (excess inventory; significant cash-flow risk)" + CRLF + ;
                 "  When a product has no sales history, use 'caution' and note" + CRLF + ;
                 "  that no demand baseline is available for that product." + CRLF + ;
                 CRLF + ;
                 "STEP 4 — Return CriticAssessment" + CRLF + ;
                 "  outlook         : the worst outlook across all products" + CRLF + ;
                 "  projectedImpact : coverage summary as a single sentence" + CRLF + ;
                 "                    e.g. '3.2 months additional coverage for Chai'" + CRLF + ;
                 "  riskNote        : dominant risk (overstock, insufficient stock, etc.)" + CRLF + ;
                 "  summary         : 2-3 sentence advisory for the human reviewer" ) ) ;
              :withTool( ::oQueryTool )

   oResult := oRunner:createObject( ;
                 "Assess this proposed stock increase:" + CRLF + Var2Json( oProposal ), ;
                 "CriticAssessment" )

   IF oResult == NIL
      oErr := ErrorNew()
      oErr:description := "BulkOperationAgent:critiqueStock: " + oRunner:getLastError()
      Break( oErr )
   ENDIF

   RETURN oResult


/// <summary>
/// Review -- display the proposed changes table and read the user's decision.
///
/// No LLM call. ApprovalTool formats the change list as a console table,
/// shows the analyst assessment when present (price_change and stock_order
/// operations), prompts for Y / R / A, and returns a ReviewDecision.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>ReviewDecision</returns>
///
METHOD BulkOperationAgent:review( oCtx )
   LOCAL oProposal   := oCtx:get( "proposal" )
   LOCAL oAssessment := oCtx:get( "assessment" )   // NIL for "other" category
RETURN ApprovalTool():New():requestApproval( oProposal, oAssessment )


/// <summary>
/// WriteSql -- write the approved SQL statements to disk.
///
/// No LLM call. Builds a well-commented .sql file from the ProposedChangeSet
/// and hands it to FileWriterTool, which strips any path component and writes
/// only to the current directory.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>WriteResult with filePath and statementCount</returns>
///
METHOD BulkOperationAgent:writeSql( oCtx )
   LOCAL oProposal := oCtx:get( "proposal" )
   LOCAL oWriter   := FileWriterTool():New()
   LOCAL oResult
   LOCAL cContent  := ""
   LOCAL nI
   LOCAL oChange
   LOCAL cDesc
   LOCAL cSql

   // Header block
   cContent += "-- ============================================================" + CRLF
   cContent += "-- Bulk operation: " + oProposal:summary                           + CRLF
   cContent += "-- Generated:      " + DToC( Date() ) + " " + Time()               + CRLF
   cContent += "-- Statements:     " + ;
               AllTrim( Str( If( ValType( oProposal:changes ) == "A", ;
                                 Len( oProposal:changes ), 0 ) ) )                  + CRLF
   cContent += "-- ============================================================" + CRLF
   cContent += CRLF
   cContent += "BEGIN;" + CRLF
   cContent += CRLF

   IF ValType( oProposal:changes ) == "A"
      FOR nI := 1 TO Len( oProposal:changes )
         oChange := oProposal:changes[nI]

         cDesc := ""
         cSql  := ""

         IF IsMemberVar( oChange, "description" )
            cDesc := AllTrim( oChange:GetNoIvar( "description" ) )
         ENDIF

         IF IsMemberVar( oChange, "updateSql" )
            cSql := AllTrim( oChange:GetNoIvar( "updateSql" ) )
         ELSEIF IsMemberVar( oChange, "update_sql" )
            cSql := AllTrim( oChange:GetNoIvar( "update_sql" ) )
         ENDIF

         IF !Empty( cDesc )
            cContent += "-- " + cDesc + CRLF
         ENDIF

         IF !Empty( cSql )
            IF Right( cSql, 1 ) != ";"
               cSql += ";"
            ENDIF
            cContent += cSql + CRLF
         ENDIF

         cContent += CRLF
      NEXT
   ENDIF

   cContent += "COMMIT;" + CRLF

   oResult := oWriter:writeFile( oProposal:outputFile, cContent )

   // Statement count = number of change records (each has one UPDATE)
   IF !Empty( oResult:filePath )
      oResult:statementCount := If( ValType( oProposal:changes ) == "A", ;
                                    Len( oProposal:changes ), 0 )
   ENDIF

RETURN oResult


// ---------------------------------------------------------------------------
// Guard methods
// ---------------------------------------------------------------------------

/// <summary>
/// Return .T. when the request was classified as a price change
/// (unitprice increase, decrease, or flat override).
/// Reads the persistent classification placed by Classify().
/// </summary>
///
METHOD BulkOperationAgent:isPriceChange( oCtx )
RETURN Lower( AllTrim( oCtx:get( "classification" ):category ) ) == "price_change"


/// <summary>
/// Return .T. when the request was classified as a stock order
/// (unitsinstock or unitsonorder modification).
/// Reads the persistent classification placed by Classify().
/// </summary>
///
METHOD BulkOperationAgent:isStockOrder( oCtx )
RETURN Lower( AllTrim( oCtx:get( "classification" ):category ) ) == "stock_order"


/// <summary>
/// Return .T. when the user approved the proposal (chose Y).
/// </summary>
///
METHOD BulkOperationAgent:isApproved( oCtx )
RETURN oCtx:get( "approval" ):Valid


/// <summary>
/// Return .T. when the user aborted the task (chose A).
/// Checked before IsExhausted so an abort is always honoured
/// regardless of how many retries remain.
/// </summary>
///
METHOD BulkOperationAgent:isAborted( oCtx )
RETURN oCtx:get( "approval" ):aborted


/// <summary>
/// Return .T. when the analyze state has been visited >= maxAttempts times,
/// meaning no further retries are allowed.
/// </summary>
///
METHOD BulkOperationAgent:isExhausted( oCtx )
RETURN ::isExhaustedFor( oCtx, "analyze" )
