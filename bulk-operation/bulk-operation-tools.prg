//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Tool classes for the Bulk Operation Preparation Agent example.
/// </summary>
///
/// <remarks>
/// Provides the building blocks shared with bulk-operation-common.prg,
/// bulk-operation-agent.prg, and bulk-operation-main.prg:
///
///   NorthwindBulkQueryTool - AbstractToolClass: SELECT-only query tool for the LLM,
///                            shared by Analyze, CritiquePrice, and CritiqueStock
///   ApprovalTool           - displays the change table + assessment, reads console approval
///   FileWriterTool         - writes the approved SQL to the current directory (path-stripped)
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
// NorthwindBulkQueryTool
//
// AbstractToolClass that exposes a single ExecuteQuery tool to the LLM.
// The LLM calls this during the Analyze state to gather the data it needs
// before computing the proposed changes.
//
// Design:
//   - Only SELECT statements and CTEs are accepted (security gate).
//   - Results are capped at 50 rows: LIMIT 50 appended when absent.
//   - abortOnError = .F.: SQL errors are fed back to the LLM as tool errors
//     so it can correct and retry the query.
// ---------------------------------------------------------------------------

CLASS NorthwindBulkQueryTool FROM AbstractToolClass

   EXPORTED:
   VAR oSession

   CLASS METHOD onRegister()
   METHOD init( oSession )
   METHOD executeQuery( oInput )    // { sql, title? } -> compact JSON or "Error: ..."

   PROTECTED:
   METHOD runQuery( cSql )

ENDCLASS


CLASS METHOD NorthwindBulkQueryTool:onRegister()

   ::addTool( "ExecuteQuery", ;
      "Execute a SQL SELECT statement against the Northwind PostgreSQL database. " + ;
      "Use this to inspect current data before computing the proposed changes. " + ;
      "You may call this tool multiple times. Results are capped at 50 rows. " + ;
      "Only SELECT statements and CTEs (WITH...SELECT) are accepted. " + ;
      "Never use this to run UPDATE, INSERT, or DELETE statements -- " + ;
      "those are generated as output, not executed here.", ;
      ToolParam() ;
         :addString( "sql",   .T., "A valid PostgreSQL SELECT (no UPDATE/INSERT/DELETE)" ) ;
         :addString( "title", .F., "Short description of what this query retrieves" ) )

RETURN Self


METHOD NorthwindBulkQueryTool:init( oSession )
   ::AbstractToolClass:init()        // abortOnError = .F.: SQL errors fed back to LLM
   ::oSession := oSession
RETURN Self


METHOD NorthwindBulkQueryTool:executeQuery( oInput )
   LOCAL cSql

   cSql := oInput:Sql

   // Strip leading and trailing whitespace including CR / LF embedded in JSON
   DO WHILE Len( cSql ) > 0 .AND. Asc( Left( cSql, 1 ) ) <= 32
      cSql := SubStr( cSql, 2 )
   ENDDO
   DO WHILE Len( cSql ) > 0 .AND. Asc( Right( cSql, 1 ) ) <= 32
      cSql := Left( cSql, Len( cSql ) - 1 )
   ENDDO

   // Security gate: only SELECT statements and CTEs
   IF Upper( Left( cSql, 6 ) ) != "SELECT" .AND. Upper( Left( cSql, 4 ) ) != "WITH"
      RETURN "Error: Only SELECT statements and CTEs (WITH...SELECT) are allowed. " + ;
             "Rewrite your query starting with SELECT or WITH."
   ENDIF

   // Enforce row cap
   IF At( "LIMIT", Upper( cSql ) ) == 0
      cSql += " LIMIT 50"
   ENDIF

RETURN ::runQuery( cSql )


METHOD NorthwindBulkQueryTool:runQuery( cSql )
   LOCAL aColumns := {}
   LOCAL aRows    := {}
   LOCAL nRows    := 0
   LOCAL nFields
   LOCAL nF
   LOCAL aRow
   LOCAL oOut
   LOCAL oStmt
   LOCAL aData := {}
   LOCAL oE
   LOCAL cbOld

   oE    := NIL
   cbOld := ErrorBlock( {|o| Break( o )} )

   BEGIN SEQUENCE

      oStmt := DacSqlStatement():fromChar( cSql )
      oStmt:build():query( USQL_RESULT_WORKAREA, @aData )

      nFields := fcount()
      FOR nF := 1 TO nFields
         AAdd( aColumns, fieldname( nF ) )
      NEXT

      DO WHILE !EOF() .AND. nRows < 50
         aRow := {}
         FOR nF := 1 TO nFields
            AAdd( aRow, BulkFormatFieldValue( fieldget( nF ) ) )
         NEXT
         AAdd( aRows, aRow )
         nRows++
         SKIP 1
      ENDDO

      CLOSE

   RECOVER USING oE
      ErrorBlock( cbOld )
      RETURN "Error: " + oE:description
   END SEQUENCE

   ErrorBlock( cbOld )

   oOut          := DataObject():New()
   oOut:columns  := aColumns
   oOut:rows     := aRows
   oOut:rowCount := nRows

RETURN Var2Json( oOut )


/// <summary>
/// Convert a database field value to a JSON-serialisable type.
/// Numbers, logicals, and dates pass through; memo types are parsed
/// as numbers when possible (PGDBE memo oddity).
/// </summary>
///
STATIC FUNCTION BulkFormatFieldValue( xVal )
   LOCAL cType
   LOCAL cMemo
   LOCAL nMemo

   IF xVal == NIL
      RETURN NIL
   ENDIF

   cType := ValType( xVal )

   DO CASE
   CASE cType == "C" ;  RETURN AllTrim( xVal )
   CASE cType == "N" ;  RETURN xVal
   CASE cType == "D" ;  RETURN DToC( xVal )
   CASE cType == "L" ;  RETURN xVal
   CASE cType == "M"
      cMemo := AllTrim( xVal )
      nMemo := Val( cMemo )
      IF nMemo != 0
         RETURN nMemo
      ENDIF
      RETURN cMemo
   ENDCASE

RETURN AllTrim( Str( xVal ) )


// ---------------------------------------------------------------------------
// ApprovalTool
//
// Displays the proposed changes as a formatted console table and reads the
// user's decision. Three outcomes are possible:
//   Y   approve  -> ReviewDecision():ok()
//   R   reject   -> ReviewDecision():fail(cFeedback)  (re-prompts for feedback)
//   A   abort    -> ReviewDecision():abort()           (skip to next task)
//
// The input loop repeats until a valid key is entered.
// Called directly by the agent's Review action method.
// ---------------------------------------------------------------------------

CLASS ApprovalTool

   EXPORTED:
   METHOD init()
   METHOD requestApproval( oProposal, oAssessment )   // returns ReviewDecision

   PROTECTED:
   METHOD displayChangesTable( oProposal )
   METHOD displayAssessment( oAssessment )

ENDCLASS


METHOD ApprovalTool:init()
RETURN Self


METHOD ApprovalTool:requestApproval( oProposal, oAssessment )
   LOCAL cInput
   LOCAL cFeedback

   ::displayChangesTable( oProposal )

   IF oAssessment != NIL
      ::displayAssessment( oAssessment )
   ENDIF

   ?
   ? Replicate( "-", 72 )
   ? "  Options:"
   ? "    Y  -  approve and write SQL to disk"
   ? "    R  -  reject and provide correction guidance (retry)"
   ? "    A  -  abort and skip to the next task"
   ?

   // Input loop: repeat until the user enters a recognised key
   DO WHILE .T.
      ACCEPT "  Your choice (Y / R / A): " TO cInput
      cInput := Upper( AllTrim( cInput ) )
      IF cInput == "Y" .OR. cInput == "R" .OR. cInput == "A"
         EXIT
      ENDIF
      ? "  Please enter Y, R, or A."
   ENDDO

   DO CASE

   CASE cInput == "Y"
      ? "  -> Approved."
      RETURN ReviewDecision():ok()

   CASE cInput == "A"
      ? "  -> Aborted. Moving to next task."
      RETURN ReviewDecision():abort()

   OTHERWISE  // R
      ?
      ACCEPT "  Describe the required correction: " TO cFeedback
      cFeedback := AllTrim( cFeedback )
      IF Empty( cFeedback )
         cFeedback := "User rejected the proposal without further details."
      ENDIF
      ? "  -> Rejected. Re-analyzing with your feedback..."
      RETURN ReviewDecision():fail( cFeedback )

      ENDCASE

RETURN NIL


      /// <summary>
      /// Display the analyst assessment block between the change table and the
/// Y / R / A prompt. The outlook marker gives an at-a-glance signal:
///   [+] positive   [ ] neutral   [~] caution   [!] concern
/// </summary>
///
METHOD ApprovalTool:displayAssessment( oAssessment )
   LOCAL cOutlook := Lower( AllTrim( If( oAssessment:outlook == NIL, "neutral", oAssessment:outlook ) ) )
   LOCAL cMarker
   LOCAL cImpact
   LOCAL cRisk
   LOCAL cSummary

   DO CASE
   CASE cOutlook == "positive" ; cMarker := "[+]"
   CASE cOutlook == "caution"  ; cMarker := "[~]"
   CASE cOutlook == "concern"  ; cMarker := "[!]"
   OTHERWISE                   ; cMarker := "[ ]"
   ENDCASE

   cImpact  := AllTrim( If( oAssessment:projectedImpact == NIL, "", oAssessment:projectedImpact ) )
   cRisk    := AllTrim( If( oAssessment:riskNote        == NIL, "", oAssessment:riskNote        ) )
   cSummary := AllTrim( If( oAssessment:summary         == NIL, "", oAssessment:summary         ) )

   ?
   ? Replicate( "-", 72 )
   ? "  ANALYST ASSESSMENT  " + cMarker + " " + Upper( cOutlook )
   ? Replicate( "-", 72 )
   IF !Empty( cImpact )
      ? "  Impact  : " + cImpact
   ENDIF
   IF !Empty( cRisk )
      ? "  Pattern : " + cRisk
   ENDIF
   IF !Empty( cSummary )
      ? "  " + cSummary
   ENDIF
   ? Replicate( "-", 72 )

RETURN Self


/// <summary>
/// Display the proposed changes as a numbered table with Old Value / New Value columns.
/// All output uses plain ASCII box characters to avoid UTF-8 encoding issues on the console.
/// </summary>
///
METHOD ApprovalTool:displayChangesTable( oProposal )
   LOCAL cSep
   LOCAL nI
   LOCAL oChange
   LOCAL cDesc
   LOCAL cOld
   LOCAL cNew
   LOCAL cNum
   LOCAL xVal

   cSep := Replicate( "=", 72 )

   ?
   ? cSep
   ? "  PROPOSED BULK OPERATION"
   ? cSep
   ? "  Summary : " + If( Empty( oProposal:summary ), "(no summary provided)", oProposal:summary )
   ? "  SQL file: " + If( Empty( oProposal:outputFile ), "bulk_update.sql", oProposal:outputFile )
   ? Replicate( "-", 72 )

   IF ValType( oProposal:changes ) != "A" .OR. Len( oProposal:changes ) == 0
      ? "  (no changes proposed)"
      ? cSep
      RETURN
   ENDIF

   ? "  " + PadR( "#",           3  ) + " " + ;
             PadR( "Description", 38 ) + " " + ;
             PadR( "Old Value",   12 ) + " " + ;
             "New Value"
   ? Replicate( "-", 72 )

   FOR nI := 1 TO Len( oProposal:changes )
      oChange := oProposal:changes[nI]

      cDesc := "(no description)"
      cOld  := ""
      cNew  := ""

      IF IsMemberVar( oChange, "description" )
         cDesc := AllTrim( oChange:GetNoIvar( "description" ) )
      ENDIF

      xVal := NIL
      IF IsMemberVar( oChange, "oldValue" )
         xVal := oChange:GetNoIvar( "oldValue" )
      ENDIF
      cOld := BulkFormatChangeValue( xVal )

      xVal := NIL
      IF IsMemberVar( oChange, "newValue" )
         xVal := oChange:GetNoIvar( "newValue" )
      ENDIF
      cNew := BulkFormatChangeValue( xVal )

      IF Len( cDesc ) > 38
         cDesc := Left( cDesc, 37 ) + ">"
      ENDIF

      cNum := PadL( AllTrim( Str( nI ) ), 2 ) + "."
      ? "  " + cNum + " " + PadR( cDesc, 38 ) + " " + PadR( cOld, 12 ) + " " + cNew
   NEXT

   ? Replicate( "-", 72 )
   ? "  " + AllTrim( Str( Len( oProposal:changes ) ) ) + " change(s)"
   ? cSep

RETURN Self


/// <summary>
/// Format a numeric or string change value for the review table.
/// Numbers are shown with 2 decimal places; strings are trimmed as-is.
/// </summary>
///
STATIC FUNCTION BulkFormatChangeValue( xVal )
   IF xVal == NIL
      RETURN ""
   ENDIF
   IF ValType( xVal ) == "N"
      RETURN AllTrim( Str( xVal, 15, 2 ) )
   ENDIF
RETURN AllTrim( xVal )


// ---------------------------------------------------------------------------
// FileWriterTool
//
// Writes the approved SQL content to a file in the current directory.
// Security: any path component in the filename is stripped so the tool
// cannot write outside the working directory.
// ---------------------------------------------------------------------------

CLASS FileWriterTool

   EXPORTED:
   METHOD init()
   METHOD writeFile( cFilename, cContent )   // returns WriteResult

   PROTECTED:
   METHOD safeName( cFilename )

ENDCLASS


METHOD FileWriterTool:init()
RETURN Self


METHOD FileWriterTool:writeFile( cFilename, cContent )
   LOCAL oResult  := WriteResult():New()
   LOCAL cSafe    := ::safeName( cFilename )
   LOCAL nHandle

   nHandle := FCreate( cSafe )
   IF nHandle < 0
      oResult:message := "Error: could not create file '" + cSafe + "'"
      RETURN oResult
   ENDIF

   FWrite( nHandle, cContent )
   FClose( nHandle )

   oResult:filePath := cSafe
   oResult:message  := "File '" + cSafe + "' written successfully"

RETURN oResult


METHOD FileWriterTool:safeName( cFilename )
   LOCAL cSafe := AllTrim( cFilename )
   LOCAL nPos

   // Strip forward slashes
   DO WHILE ( nPos := At( "/", cSafe ) ) > 0
      cSafe := SubStr( cSafe, nPos + 1 )
   ENDDO

   // Strip backslashes
   DO WHILE ( nPos := At( "\", cSafe ) ) > 0
      cSafe := SubStr( cSafe, nPos + 1 )
   ENDDO

   // Strip leading dots (prevent hidden files / parent traversal remnants)
   DO WHILE Left( cSafe, 1 ) == "."
      cSafe := SubStr( cSafe, 2 )
   ENDDO

   IF Empty( cSafe )
      cSafe := "bulk_update.sql"
   ENDIF

RETURN cSafe

