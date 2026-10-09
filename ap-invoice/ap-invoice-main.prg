//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Driver for the ApInvoiceAgent example (LOB use case - Accounts Payable
/// Invoice Automation).
///
/// Loads invoice sources from an XML config file (ap-invoice-samples.config)
/// with the Xbase++ XmlSimpleParser(), then runs the agent for each invoice
/// and reports the outcome: auto-posted, routed for approval, or an exception.
/// </summary>
///
/// <remarks>
/// Usage:  ap-invoice-agent.exe [config-file]
///         (config-file defaults to ap-invoice-samples.config in the cwd)
///
/// Requires MISTRAL_API_KEY set in the environment. If not provided falls
/// back to Alaska Software free of charge LLM-Router (requires valid
/// Xbase++ V3 License). Without a working LLM connection each invoice
/// reports the failure cleanly through its RECOVER path.
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "..\agentic-ai-core.ch"
#include "common.ch"

PROCEDURE Main( cConfigFile )
   LOCAL oAgent := ApInvoiceAgent():New( DemoVendorMaster():New(), DemoPurchaseOrderBook():New() )
   LOCAL aSources
   LOCAL nI

   DEFAULT cConfigFile TO "ap-invoice-samples.config"
   SET CHARSET TO ANSI

   aSources := LoadInvoiceSources( cConfigFile )

   IF Empty( aSources )
      ? "No invoice sources loaded from", cConfigFile
      RETURN
   ENDIF

   FOR nI := 1 TO Len( aSources )
      ? ""
      ? "=== Invoice " + AllTrim( Str( nI ) ) + " (" + aSources[nI]:label + ") ==="
      ProcessOne( oAgent, aSources[nI] )
   NEXT

RETURN


/// <summary>
/// Runs the agent for a single invoice and reports the outcome. Each invoice
/// is isolated in its own BEGIN SEQUENCE so one failed LLM call (e.g. no API
/// key) does not abort the rest of the batch. The agent is reused across
/// invoices - ForAgent()/Run() rebuilds the flow per run (idempotent) and each
/// invoice gets a fresh context.
/// </summary>
/// <param name="oAgent">the AP invoice agent</param>
/// <param name="oSource">the invoice source to process</param>
///
STATIC FUNCTION ProcessOne( oAgent, oSource )
   LOCAL oCtx := AgentContext():New()
   LOCAL oResult
   LOCAL oInv
   LOCAL oError
   LOCAL oVA

   oCtx:set( "source", oSource )

   BEGIN SEQUENCE
      oResult := AgentStateMachine():forAgent( oAgent ):run( oCtx )

      ? "Source label:", oSource:label

      oInv := oResult:get( "invoice" )
      IF oInv != NIL
         ? "Vendor:      ", oInv:vendor
         ? "Invoice #:   ", oInv:invoiceNumber
         ? "Date:        ", oInv:date
         ? "PO #:        ", oInv:poNumber
         ? "Amount:      ", AllTrim( Str( oInv:amount, 12, 2 ) ), oInv:currency
      ENDIF

      DO CASE
      CASE oResult:get( "posting" ) != NIL
         ? "AUTO-POSTED: ", oResult:get( "posting" ):message

      CASE oResult:get( "approval" ) != NIL
         ? "APPROVAL:    ", oResult:get( "approval" ):queue, ;
           "(" + oResult:get( "approval" ):priority + ")"
         ? "Reason:      ", oResult:get( "approval" ):reason
         IF !Empty( oResult:get( "approval" ):message )
            ? "Message:     ", oResult:get( "approval" ):message
         ENDIF

      CASE oResult:get( "vendorApproval" ) != NIL
         oVA := oResult:get( "vendorApproval" )
         ? "PENDING:      vendor match requires human approval"
         ? "Invoice vendor:  ", oVA:invoiceVendor
         ? "Proposed match:  ", oVA:proposedVendor:Name, "(" + oVA:proposedVendor:id + ")"
         ? "LLM reasoning:   ", oVA:reason

      CASE oResult:get( "exception" ) != NIL
         ? "EXCEPTION:   ", oResult:get( "exception" ):category
         ? "Reason:      ", oResult:get( "exception" ):summary

      OTHERWISE
         ? "No terminal output - check the trace."
      END

   RECOVER USING oError
      ? "AP processing failed:", oError:description
   END SEQUENCE

RETURN NIL
