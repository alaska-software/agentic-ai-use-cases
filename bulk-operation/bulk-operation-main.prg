//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Bulk Operation Preparation Agent -- driver program.
///
/// Demonstrates natural-language bulk database update preparation over
/// the Northwind PostgreSQL database using an FSM agent.
///
/// For each task the agent:
///   1. Queries the live database to identify the affected rows (LLM + tool)
///   2. Computes the exact new values as specified
///   3. Shows a reviewable change table (up to 10 rows) via ApprovalTool
///   4. Waits for the user to choose:
///        Y  approve  -> writes a transaction-wrapped .sql file to disk
///        R  reject   -> re-analyzes with the correction feedback (up to 3 retries)
///        A  abort    -> skips this task and continues with the next one
///
/// Five example tasks, loaded from an external XML config file, exercise
/// different kinds of bulk operations:
///
///   T1 -- price increase, top-N by sales, percentage + rounding
///   T2 -- discontinue products with no order history, supplier filter
///   T3 -- price reduction by category, percentage + rounding
///   T4 -- stock increase for low-inventory products
///   T5 -- flat price override by current price range and supplier
///
/// Flow per task:
///   RunTask() creates a fresh AgentContext, places the request on the
///   blackboard, fires AgentStateMachine:run(), and reports the outcome.
///   The loop in Main() always advances to the next task regardless of
///   whether the previous one was approved, aborted, or exhausted.
///
/// Usage:  bulk-operation.exe [config-file]
///         (config-file defaults to bulk-operation-tasks-en.config in the
///         cwd; pass bulk-operation-tasks-de.config to run the identical
///         five tasks in German instead)
///
/// Requires:
///   ANTHROPIC_API_KEY set in the environment (or apikey.bat sourced). If
///   not provided falls back to Alaska Software free of charge LLM-Router
///   (requires valid Xbase++ V3 License).
///   PostgreSQL Northwind database on localhost (configure cConnect below)
/// </summary>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "..\agentic-ai-core.ch"
#include "common.ch"
#include "dac.ch"
#include "pgdbe.ch"

PROCEDURE Main( cConfigFile )
   LOCAL cConnect
   LOCAL oSession
   LOCAL oAgent
   LOCAL aTasks
   LOCAL cSep
   LOCAL nI

   DEFAULT cConfigFile TO "bulk-operation-tasks-en.config"
   SET CHARSET TO ANSI

   cSep := Replicate( "=", 72 )

   // -----------------------------------------------------------------------
   // PostgreSQL connection
   // -----------------------------------------------------------------------
   DbeLoad( "PGDBE" )
   DbeSetDefault( "PGDBE" )

   cConnect := "DBE=pgdbe;SERVER=localhost;DB=northwind;UID=postgres;PWD=postgres"
   oSession  := DacSession():New( cConnect )

   IF !oSession:isConnected()
      ? "Connection failed:", oSession:getLastMessage()
      RETURN
   ENDIF
   ? "Connected to Northwind Traders database."
   ?

   // -----------------------------------------------------------------------
   // Token usage observer -- prints LLM cost per analyze call.
   // ToolAwareSender accumulates tokens across all tool-calling rounds so
   // the count shown reflects the full multi-round cost per state execution.
   // -----------------------------------------------------------------------
   LLMService():onUsage( ;
      {|oAgt, cModel, nIn, nOut, cTS, nElapsedInMS| ;
         Qout( "    [" + cModel + ;
               "  in:"  + AllTrim( Str( nIn  ) ) + ;
               " out:"  + AllTrim( Str( nOut ) ) + " tokens" + ;
               "  " + AllTrim( Str( nElapsedInMS ) ) + " ms]" ) } )

   // -----------------------------------------------------------------------
   // Build the agent once -- it is reused for all tasks.
   // The NorthwindBulkQueryTool inside holds only the DacSession reference,
   // which is safely shared across sequential runs.
   // -----------------------------------------------------------------------
   oAgent := BulkOperationAgent():New( oSession )

   // -----------------------------------------------------------------------
   // Five bulk operation tasks, loaded from the XML task config file.
   // LoadBulkTasks()/NodeToBulkTask() live in bulk-operation-common.prg and
   // never change between languages -- MemoRead() + XmlSimpleParser() honor
   // the file's declared encoding, so swapping cConfigFile for the German
   // variant is the only thing required to run the German task set.
   // -----------------------------------------------------------------------
   aTasks := LoadBulkTasks( cConfigFile )

   IF Empty( aTasks )
      ? "No bulk tasks loaded from", cConfigFile
      oSession:disconnect()
      RETURN
   ENDIF

   // -----------------------------------------------------------------------
   // Run each task interactively.
   // The loop always advances -- aborted and failed tasks are reported but
   // do not stop the remaining tasks from running.
   // -----------------------------------------------------------------------
   FOR nI := 1 TO Len( aTasks )
      ?
      ? cSep
      ? "Task " + AllTrim( Str( nI ) ) + " of " + AllTrim( Str( Len( aTasks ) ) ) + ;
        If( !Empty( aTasks[nI]:label ), " (" + aTasks[nI]:label + ")", "" )
      ? cSep
      ? aTasks[nI]:text
      ? Replicate( "-", 72 )

      RunTask( oAgent, aTasks[nI]:text )
   NEXT

   ?
   ? cSep
   ? "All tasks processed."

   oSession:disconnect()

RETURN


// ---------------------------------------------------------------------------
// RunTask
//
// Executes one bulk operation request through the BulkOperationAgent FSM.
// Creates a fresh AgentContext so each task starts with an empty blackboard
// and clean visit counts. Reports the outcome and returns so the caller
// can continue with the next task regardless of the terminal state.
// ---------------------------------------------------------------------------

PROCEDURE RunTask( oAgent, cTask )
   LOCAL oCtx      := AgentContext():New()
   LOCAL oMachine
   LOCAL oLastEntry
   LOCAL cTerminal
   LOCAL oErr

   oCtx:set( "request", cTask )

   BEGIN SEQUENCE

      oMachine := AgentStateMachine():forAgent( oAgent )
      oMachine:run( oCtx )

      oLastEntry := oMachine:getTrace()[ Len( oMachine:getTrace() ) ]
      cTerminal  := oLastEntry:getName()

      DO CASE
      CASE cTerminal == "write_sql"
         DisplayWriteResult( oCtx:get( "result" ) )

      CASE cTerminal == "aborted"
         ?
         ? "  Task aborted by user."

      OTHERWISE
         ?
         ? "  Task ended at '" + cTerminal + "' -- no SQL written " + ;
           "after " + AllTrim( Str( oAgent:getMaxAttempts() ) ) + " attempt(s)."
      ENDCASE

   RECOVER USING oErr
      ?
      ? "  Error: " + oErr:description
   END SEQUENCE

RETURN


// ---------------------------------------------------------------------------
// DisplayWriteResult
//
// Prints a short success summary after the SQL file has been written.
// ---------------------------------------------------------------------------

PROCEDURE DisplayWriteResult( oResult )
   LOCAL cSep

   cSep := Replicate( "-", 72 )

   ?
   ? cSep
   ? "  SQL file written successfully"
   ? cSep
   ? "  File      : " + oResult:filePath
   ? "  Statements: " + AllTrim( Str( oResult:statementCount ) )
   ? "  " + oResult:message
   ? cSep

RETURN
