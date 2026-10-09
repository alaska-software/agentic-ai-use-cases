//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// ApInvoiceAgent - accounts-payable invoice automation agent.
/// The flow is declared in onRegister(); the framework builds and drives
/// the state machine.
/// </summary>
///
/// <remarks>
/// This file supplies the agent class.
///
/// Flow:
///      extract --> validateExtract --[IsExtractOk]----> lookupVendor
///         ^              |                                    |
///         |              +--[IsExhausted]--> raiseException(T)
///         |              +--[isRetryFor "extraction"]--> extract (retry, error fed back)
///
///      lookupVendor --[IsVendorUnknown]--> proposeVendorMatch (LLM)
///         |  (otherwise)                         |
///         v                     [HasVendorProposal]--> awaitVendorApproval(T)
///                                                    --> raiseException(T)
///
///      checkDuplicate (reached after lookupVendor NIL guard)
///         |  (otherwise)
///         v
///      checkDuplicate --[IsDuplicate]--> raiseException(T)
///         |  (otherwise)
///         v
///      matchToPO --[IsHardMismatch]--> raiseException(T)
///                --[NeedsApproval]---> routeForApproval(T)
///                --[otherwise]-------> autoPost(T)
///
/// Only Extract calls the LLM. Every routing decision (guards) and every
/// business step (ValidateExtract, LookupVendor, CheckDuplicate, MatchToPO,
/// AutoPost, RouteForApproval, RaiseException) is pure Xbase++.
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "..\agentic-ai-core.ch"
#include "common.ch"

CLASS ApInvoiceAgent FROM AbstractAgent
   EXPORTED:
   VAR vendorMaster
   VAR poBook
   VAR autoPostThreshold
   VAR amountTolerance

   METHOD init( oVendorMaster, oPoBook, oLLMOptions, nMaxAttempts, nAutoPost, nTolerance )
   METHOD onRegister()

   // Action methods - take the context, read/write the blackboard
   METHOD extract( oCtx )
   METHOD validateExtract( oCtx )
   METHOD lookupVendor( oCtx )
   METHOD proposeVendorMatch( oCtx )
   METHOD awaitVendorApproval( oCtx )
   METHOD checkDuplicate( oCtx )
   METHOD matchToPO( oCtx )
   METHOD autoPost( oCtx )
   METHOD routeForApproval( oCtx )
   METHOD raiseException( oCtx )

   // Guard methods - pure boolean, no LLM, no side effects
   METHOD isExtractOk( oCtx )
   METHOD isExhausted( oCtx )
   METHOD isVendorUnknown( oCtx )
   METHOD hasVendorProposal( oCtx )
   METHOD isDuplicate( oCtx )
   METHOD isHardMismatch( oCtx )
   METHOD needsApproval( oCtx )

ENDCLASS


METHOD ApInvoiceAgent:init( oVendorMaster, oPoBook, oLLMOptions, nMaxAttempts, nAutoPost, nTolerance )
   DEFAULT nMaxAttempts TO 3
   DEFAULT nAutoPost    TO 500.00
   DEFAULT nTolerance   TO 0.50
   DEFAULT oLLMOptions  TO LLMOptions():withModel( MistralModels():MISTRAL_SMALL ):withTemperature( 0 )
   ::AbstractAgent:init()
   ::vendorMaster      := oVendorMaster
   ::poBook            := oPoBook
   ::autoPostThreshold := nAutoPost
   ::amountTolerance   := nTolerance
   ::MaxAttempts       := nMaxAttempts
   ::withDefaultLLM( oLLMOptions )
   ::withDefaultPersona( ApInvoicePersonas():extractor() )
RETURN Self


/// <summary>
/// onRegister() - the single place that owns the flow definition.
/// </summary>
/// <remarks>
/// The retry guard uses a parameterised tuple { "isRetryFor", "extraction" }
/// so the guard calls oAgent:isRetryFor(oCtx, "extraction") without needing
/// a wrapper method. Specific guards are registered before the fallthrough.
/// </remarks>
///
METHOD ApInvoiceAgent:onRegister()

   // "extraction?" is optional: absent on the first pass (no prior validation),
   // present on every retry so the previous error can be fed back to the LLM.
   ::addState( "extract", "Extract", "source, extraction?", "invoice" ) ;
      :onGuard( NIL, "validateExtract" )

   ::addState( "validateExtract", "ValidateExtract", "invoice", "extraction" ) ;
      :onGuard( "IsExtractOk",                         "lookupVendor"   ) ;
      :onGuard( "IsExhausted",                         "raiseException" ) ;
      :onGuard( { "isRetryFor", "extraction" },        "extract"        )

   ::addState( "lookupVendor", "LookupVendor", "invoice", "vendor" ) ;
      :onGuard( "IsVendorUnknown", "proposeVendorMatch" ) ;
      :onGuard( NIL,               "checkDuplicate"     )

   ::addState( "proposeVendorMatch", "ProposeVendorMatch", "invoice", "vendorProposal" ) ;
      :onGuard( "HasVendorProposal", "awaitVendorApproval" ) ;
      :onGuard( NIL,                 "raiseException"       )

   ::addState( "checkDuplicate", "CheckDuplicate", "invoice, vendor", "duplicate" ) ;
      :onGuard( "IsDuplicate", "raiseException" ) ;
      :onGuard( NIL,           "matchToPO"      )

   ::addState( "matchToPO", "MatchToPO", "invoice, vendor", "match" ) ;
      :onGuard( "IsHardMismatch", "raiseException"   ) ;
      :onGuard( "NeedsApproval",  "routeForApproval" ) ;
      :onGuard( NIL,              "autoPost"         )

   ::addState( "autoPost",            "AutoPost",            "invoice, vendor, match",                                                    "posting"       ) :terminal()
   ::addState( "routeForApproval",    "RouteForApproval",    "invoice, vendor, match",                                                    "approval"      ) :terminal()
   ::addState( "awaitVendorApproval", "AwaitVendorApproval", "invoice, vendorProposal",                                                   "vendorApproval") :terminal()
   ::addState( "raiseException",      "RaiseException",      "source, invoice?, vendor?, vendorProposal?, duplicate?, match?, extraction?", "exception"     ) :terminal()

RETURN Self


// ---------------------------------------------------------------------------
// Action methods
// ---------------------------------------------------------------------------

/// <summary>
/// The only state that calls the LLM. On a retry, the previous validation
/// error is injected as a UserMessage so the model knows what to fix.
/// The default LLM and extractor persona come from agent-level defaults set
/// in Init(). Field-level type and description guidance is derived automatically
/// from the InvoiceData class hints registered in its Init().
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>InvoiceData</returns>
///
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


/// <summary>
/// Checks that the extracted InvoiceData contains the minimum fields needed
/// to proceed. Uses IsBound() to distinguish a field the LLM omitted from
/// one it sent as an empty string.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>ExtractionValidation</returns>
///
METHOD ApInvoiceAgent:validateExtract( oCtx )
   LOCAL oInv          := oCtx:get( "invoice" )
   // When the invoice was populated via Bind() (real LLM output), IsBound()
   // distinguishes a field the model omitted from one it sent as empty.
   // When the invoice was constructed directly (unit tests, deterministic
   // fakes), WasBound() returns .F. and we fall back to Empty().
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


/// <summary>
/// Tries name lookup first; falls back to bank account lookup when the
/// extracted vendor name does not match exactly. Returns NIL when nothing
/// matches, which IsVendorUnknown() detects to route to proposeVendorMatch.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>VendorRecord, or NIL when not found</returns>
///
METHOD ApInvoiceAgent:lookupVendor( oCtx )
   LOCAL oInv
   LOCAL oVendor

   oInv    := oCtx:get( "invoice" )
   oVendor := ::vendorMaster:findByName( oInv:vendor )

   IF oVendor == NIL .AND. !Empty( oInv:bankAccount )
      oVendor := ::vendorMaster:findByBank( oInv:bankAccount )
   ENDIF

RETURN oVendor


/// <summary>
/// Checks the posted-invoice ledger.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>DuplicateCheck</returns>
///
METHOD ApInvoiceAgent:checkDuplicate( oCtx )
   LOCAL oInv
   LOCAL oVendor
   LOCAL oDup

   oInv    := oCtx:get( "invoice" )
   oVendor := oCtx:get( "vendor" )
   oDup    := DuplicateCheck():New()

   IF ::poBook:isInvoiceRegistered( oVendor:id, oInv:invoiceNumber )
      oDup:duplicate     := .T.
      oDup:existingDocId := oInv:invoiceNumber
   ENDIF

RETURN oDup


/// <summary>
/// Performs the three-way PO/GR match.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>ThreeWayMatch</returns>
///
METHOD ApInvoiceAgent:matchToPO( oCtx )
   LOCAL oInv
   LOCAL oVendor
   LOCAL oPo
   LOCAL nDelta
   LOCAL lWithin
   LOCAL oMatch

   oInv    := oCtx:get( "invoice" )
   oVendor := oCtx:get( "vendor" )

   IF Empty( oInv:poNumber )
      oPo := NIL
   ELSE
      oPo := ::poBook:findByNumber( oInv:poNumber )
   ENDIF

   IF oPo == NIL
      oMatch             := ThreeWayMatch():New()
      oMatch:tolerance   := ::amountTolerance
      oMatch:hardMismatch := .T.
      oMatch:reason      := "PO not found"
      RETURN oMatch
   ENDIF

   IF oPo:vendorId != oVendor:id
      oMatch             := ThreeWayMatch():New()
      oMatch:poFound     := .T.
      oMatch:tolerance   := ::amountTolerance
      oMatch:hardMismatch := .T.
      oMatch:reason      := "PO belongs to a different vendor"
      RETURN oMatch
   ENDIF

   nDelta  := oInv:amount - oPo:total
   lWithin := Abs( nDelta ) <= ::amountTolerance

   IF !lWithin
      oMatch              := ThreeWayMatch():New()
      oMatch:poFound      := .T.
      oMatch:amountDelta  := nDelta
      oMatch:tolerance    := ::amountTolerance
      oMatch:hardMismatch := .T.
      oMatch:reason       := "amount differs from PO by " + AllTrim( Str( nDelta, 12, 2 ) )
      RETURN oMatch
   ENDIF

   IF oInv:amount <= ::autoPostThreshold
      oMatch                := ThreeWayMatch():New()
      oMatch:poFound         := .T.
      oMatch:amountDelta     := nDelta
      oMatch:tolerance       := ::amountTolerance
      oMatch:withinTolerance := .T.
      oMatch:autoPostable    := .T.
      oMatch:reason          := "matched, under auto-post threshold"
      RETURN oMatch
   ENDIF

   oMatch                := ThreeWayMatch():New()
   oMatch:poFound         := .T.
   oMatch:amountDelta     := nDelta
   oMatch:tolerance       := ::amountTolerance
   oMatch:withinTolerance := .T.
   oMatch:needsApproval   := .T.
   oMatch:reason          := "matched, over auto-post threshold - requires approval"
RETURN oMatch


/// <summary>
/// Terminal action: posts the invoice to the ledger (stub).
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>PostingResult</returns>
///
METHOD ApInvoiceAgent:autoPost( oCtx )
   LOCAL oInv
   LOCAL oPost

   oInv              := oCtx:get( "invoice" )
   oPost             := PostingResult():New()
   oPost:ledgerEntryId := "LED-" + oInv:invoiceNumber
   oPost:postedAt    := DToC( Date() ) + " " + Time()
   oPost:message     := "Posted " + AllTrim( Str( oInv:amount, 12, 2 ) ) + " " + oInv:currency + " to ledger"
RETURN oPost


/// <summary>
/// Terminal action: selects the approval queue and priority tier, then calls
/// the LLM to draft a concise approval request message for the approver.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>ApprovalRequest</returns>
///
METHOD ApInvoiceAgent:routeForApproval( oCtx )
   LOCAL oInv
   LOCAL oVendor
   LOCAL cQueue
   LOCAL cPri
   LOCAL cMessage
   LOCAL oReq

   oInv    := oCtx:get( "invoice" )
   oVendor := oCtx:get( "vendor" )

   DO CASE
   CASE oInv:amount <= 5000
      cQueue := "ap-approval-manager"
      cPri   := "P3"
   CASE oInv:amount <= 25000
      cQueue := "ap-approval-director"
      cPri   := "P2"
   OTHERWISE
      cQueue := "ap-approval-cfo"
      cPri   := "P1"
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


/// <summary>
/// Action: asks the LLM to identify the closest vendor master record for an
/// unmatched invoice vendor name. Returns a VendorProposal when the LLM finds
/// a confident match and the suggested ID resolves to an active record, or NIL
/// when no confident match exists (routes to raiseException).
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>VendorProposal, or NIL when no confident match found</returns>
///
METHOD ApInvoiceAgent:proposeVendorMatch( oCtx )
   LOCAL oInv
   LOCAL aVendors
   LOCAL cVendorList
   LOCAL oSuggestion
   LOCAL oVendor
   LOCAL oProposal
   LOCAL nI

   oInv        := oCtx:get( "invoice" )
   aVendors    := ::vendorMaster:getActiveVendors()
   cVendorList := ""

   FOR nI := 1 TO Len( aVendors )
      cVendorList += "  " + aVendors[nI]:id + ": " + aVendors[nI]:Name + CRLF
   NEXT

   oSuggestion := oCtx:ai() ;
                  :withPromptContributor( ApInvoicePersonas():vendorMatcher() ) ;
                  :createObject( ;
                     "The vendor name '" + oInv:vendor + "' was not found in the master." + CRLF + ;
                     "Known active vendors:" + CRLF + cVendorList + ;
                     "Return the ID of the best matching vendor if one clearly matches " + ;
                     "(abbreviation, trading name, spelling variant). " + ;
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


/// <summary>
/// Terminal action: packages the LLM vendor match proposal into a
/// VendorApprovalRequest for a human to review and act on out of band.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>VendorApprovalRequest</returns>
///
METHOD ApInvoiceAgent:awaitVendorApproval( oCtx )
   LOCAL oProposal := oCtx:get( "vendorProposal" )
   LOCAL oInv      := oCtx:get( "invoice" )
   LOCAL oReq      := VendorApprovalRequest():New()
   oReq:proposedVendor := oProposal:proposedVendor
   oReq:reason         := oProposal:reason
   oReq:invoiceVendor  := oInv:vendor
RETURN oReq


/// <summary>
/// Terminal action: classifies the exception by inspecting which blackboard
/// slots are populated.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>ExceptionTicket</returns>
///
METHOD ApInvoiceAgent:raiseException( oCtx )
   LOCAL oExtraction
   LOCAL oVendor
   LOCAL oDup
   LOCAL oMatch
   LOCAL oInv
   LOCAL oSrc
   LOCAL cSource
   LOCAL cCategory
   LOCAL cSummary
   LOCAL oTicket

   oExtraction := oCtx:get( "extraction" )
   oVendor     := oCtx:get( "vendor" )
   oDup        := oCtx:get( "duplicate" )
   oMatch      := oCtx:get( "match" )
   oInv        := oCtx:get( "invoice" )
   oSrc        := oCtx:get( "source" )

   cSource := If( oSrc == NIL, "?", oSrc:label )

   DO CASE
   CASE oExtraction != NIL .AND. !oExtraction:Valid
      cCategory := "extraction"
      cSummary  := "Failed to extract invoice fields after " + ;
                   AllTrim( Str( ::MaxAttempts ) ) + " attempts: " + oExtraction:Error
   CASE oVendor == NIL
      cCategory := "unknown-vendor"
      cSummary  := "Vendor not in master: " + If( oInv == NIL, "?", oInv:vendor )
   CASE oDup != NIL .AND. oDup:duplicate
      cCategory := "duplicate"
      cSummary  := "Invoice already posted: " + oDup:existingDocId
   CASE oMatch != NIL .AND. oMatch:hardMismatch
      cCategory := "hard-mismatch"
      cSummary  := oMatch:reason
   OTHERWISE
      cCategory := "unknown"
      cSummary  := "Exception raised without a specific reason"
   ENDCASE

oTicket             := ExceptionTicket():New()
oTicket:category    := cCategory
oTicket:summary     := cSummary
oTicket:sourceLabel := cSource
RETURN oTicket


// ---------------------------------------------------------------------------
// Guard methods
// ---------------------------------------------------------------------------

/// <summary>
/// Return .T. when the latest extraction validation passed.
/// </summary>
METHOD ApInvoiceAgent:isExtractOk( oCtx )
RETURN oCtx:get( "extraction" ):Valid

/// <summary>
/// Return .T. when the extract state has been visited >= maxAttempts times.
/// </summary>
METHOD ApInvoiceAgent:isExhausted( oCtx )
RETURN ::isExhaustedFor( oCtx, "extract" )

/// <summary>
/// Return .T. when LookupVendor could not match the invoice to a master record.
/// </summary>
METHOD ApInvoiceAgent:isVendorUnknown( oCtx )
RETURN oCtx:get( "vendor" ) == NIL

/// <summary>
/// Return .T. when ProposeVendorMatch produced a confident LLM candidate.
/// </summary>
METHOD ApInvoiceAgent:hasVendorProposal( oCtx )
RETURN oCtx:get( "vendorProposal" ) != NIL

/// <summary>
/// Return .T. when the (vendorId, invoiceNumber) pair is already in the posted ledger.
/// </summary>
METHOD ApInvoiceAgent:isDuplicate( oCtx )
RETURN oCtx:get( "duplicate" ):duplicate

/// <summary>
/// Return .T. when the PO was not found, the vendor is wrong, or the amount is
/// outside tolerance.
/// </summary>
METHOD ApInvoiceAgent:isHardMismatch( oCtx )
RETURN oCtx:get( "match" ):hardMismatch

/// <summary>
/// Return .T. when the invoice matches the PO but the amount is above the
/// auto-post threshold.
/// </summary>
METHOD ApInvoiceAgent:needsApproval( oCtx )
RETURN oCtx:get( "match" ):needsApproval
